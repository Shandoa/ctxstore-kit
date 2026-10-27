#!/usr/bin/env python3
"""post_tool.py — the after-every-tool hook. Three jobs:

1. record the call in the per-turn tally (tools / memory writes / memory reads);
2. on the FIRST tool call of a session, inject the memory ritual — for harnesses
   that drop SessionStart's additionalContext (Grok CLI does; see kit/README.md)
   this is the only reliable seam, and on harnesses that honoured SessionStart it
   costs one repeated paragraph per session;
3. on the first tool call of a turn, replay the recall pointers that
   recall_on_prompt.sh saved, when the harness is one known to discard
   UserPromptSubmit context (Grok CLI, recognised by its tool names) or when
   CTXSTORE_REPLAY_RECALL=1.

Events: Claude Code / Codex / Grok CLI PostToolUse, Gemini CLI AfterTool.
(Cursor's postToolUse is observational; the installer wires tool_tally.py there.)
Never raises: any failure exits 0 with no output.
"""
from __future__ import annotations

import json
import os
import sys

sys.dont_write_bytecode = True  # keep the kit directory copyable (no __pycache__)
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tool_tally  # noqa: E402

RITUAL = (
    "MEMORY RITUAL (ctxstore, enforced by hooks): 1) READ first — your memory arrived with "
    "the first tool result; before answering anything about the person or the work, "
    "search_facts or get_fact. 2) WRITE AS YOU GO — store_fact in the same turn a decision, "
    "learning, or state change happens; the Stop hook blocks a turn that did real work and "
    "stored nothing. 3) NEVER CLAIM YOU ARE BLOCKED WITHOUT LOOKING — before saying \"only you "
    "can\" or \"I do not have access\", search_facts for a standing grant. 4) CLOSE — "
    "store_session_summary, then agent:<id>:self-note:closing. 5) SECRETS never enter the store."
)
GROK_TOOL_HINTS = ("run_terminal_command", "ctxstore__", "use_tool")


def emit(text: str) -> None:
    client = os.environ.get("CTXSTORE_CLIENT", "claude-code")
    if client == "cursor":
        return
    out = {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}
    if client == "gemini-cli":
        out = {"hookSpecificOutput": {"additionalContext": text}}
    print(json.dumps(out))


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    try:
        session = str(payload.get("session_id") or payload.get("conversation_id") or "nosession")
        name = str(payload.get("tool_name") or "")
        d = tool_tally.load(session)
        d["tools"] = int(d.get("tools", 0)) + 1
        w, r = tool_tally.classify(name, payload.get("mcp_server_name") or "")
        if w:
            d["writes"] = int(d.get("writes", 0)) + 1
        if r:
            d["reads"] = int(d.get("reads", 0)) + 1

        parts = []
        if not d.get("ritual_delivered"):
            d["ritual_delivered"] = True
            parts.append(RITUAL)
        replay = os.environ.get("CTXSTORE_REPLAY_RECALL") == "1" or any(h in name for h in GROK_TOOL_HINTS)
        pointers = d.get("recall_pointers") or ""
        if replay and pointers and not d.get("recall_replayed"):
            d["recall_replayed"] = True
            parts.append("RECALL (top memory matches for this prompt; get_fact(key=...) for the body):\n" + pointers)
        tool_tally.save(session, d)
        if parts:
            emit("\n\n".join(parts))
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
