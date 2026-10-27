#!/usr/bin/env python3
"""tool_tally.py — per-turn tally of tool calls, memory writes, memory reads and
the last assistant text, kept in a small state file so the Stop checks work on
harnesses whose transcript we cannot parse (Gemini CLI, Cursor, Codex).

Usage (all read the hook payload from stdin unless --reset):
  tool_tally.py --record            after a tool ran (PostToolUse / AfterTool /
                                    afterMCPExecution / postToolUse)
  tool_tally.py --text              after an assistant response (afterAgentResponse)
  tool_tally.py --reset --session S at the start of a turn (keeps session-level
                                    flags such as ritual_delivered)
  tool_tally.py --set-pointers      stdin = the recall pointer lines to replay
                                    later in the turn (args: --session S)

State: $CTXSTORE_STATE_DIR (default ~/.ctxstore/turns)/<session_id>.json
Never raises: any failure exits 0 with no output.
"""
from __future__ import annotations

import json
import os
import sys

WRITE_TOOLS = ("store_fact", "store_facts", "store_session_summary")
READ_TOOLS = ("search_facts", "get_fact", "list_facts_by_key_prefix", "load_context",
              "search_context", "index_search", "get_fact_history", "wake_status")
MEMORY_MARKERS = ("ctxstore", "store_fact", "search_facts", "get_fact", "load_context",
                  "list_facts_by_key_prefix", "store_session_summary", "wake_status",
                  "search_context", "index_search")


def state_dir() -> str:
    return os.environ.get("CTXSTORE_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".ctxstore", "turns")


def path_for(session: str) -> str:
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in (session or "nosession"))[:120]
    return os.path.join(state_dir(), safe + ".json")


def load(session: str) -> dict:
    try:
        with open(path_for(session)) as fh:
            d = json.load(fh)
            if isinstance(d, dict):
                return d
    except Exception:
        pass
    return {"tools": 0, "writes": 0, "reads": 0, "last_text": ""}


def save(session: str, d: dict) -> None:
    os.makedirs(state_dir(), exist_ok=True)
    tmp = path_for(session) + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(d, fh)
    os.replace(tmp, path_for(session))


def classify(tool_name: str, server: str = "") -> tuple[bool, bool]:
    """(is_write, is_read) for a tool name as any harness spells it."""
    n = (tool_name or "").lower()
    s = (server or "").lower()
    memory = "ctxstore" in n or "ctxstore" in s or any(m in n for m in MEMORY_MARKERS)
    if not memory:
        return False, False
    return any(w in n for w in WRITE_TOOLS), any(r in n for r in READ_TOOLS)


def main(argv: list[str]) -> int:
    try:
        if "--reset" in argv or "--set-pointers" in argv:
            i = argv.index("--session") if "--session" in argv else -1
            session = argv[i + 1] if i >= 0 and i + 1 < len(argv) else "nosession"
            prev = load(session)
            if "--reset" in argv:
                save(session, {"tools": 0, "writes": 0, "reads": 0, "last_text": "",
                               "ritual_delivered": bool(prev.get("ritual_delivered")),
                               "recall_pointers": "", "recall_replayed": False})
            else:
                prev["recall_pointers"] = sys.stdin.read()[:1500]
                prev["recall_replayed"] = False
                save(session, prev)
            return 0
        payload = json.load(sys.stdin)
        session = str(payload.get("session_id") or payload.get("conversation_id") or "nosession")
        d = load(session)
        if "--text" in argv:
            d["last_text"] = str(payload.get("text") or payload.get("prompt_response") or "")[-4000:]
        else:
            name = payload.get("tool_name") or ""
            server = payload.get("mcp_server_name") or ""
            d["tools"] = int(d.get("tools", 0)) + 1
            w, r = classify(name, server)
            if w:
                d["writes"] = int(d.get("writes", 0)) + 1
            if r:
                d["reads"] = int(d.get("reads", 0)) + 1
        save(session, d)
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
