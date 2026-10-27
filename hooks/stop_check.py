#!/usr/bin/env python3
"""stop_check.py — the ritual is not optional. Two checks at the end of a turn:

WRITE CHECK  substantive work (>= CTXSTORE_WORK_THRESHOLD tool calls, default 5)
             with zero memory writes (store_fact / store_facts /
             store_session_summary) -> block once: store what you did and learned.
READ CHECK   the reply claims to be blocked ("only you can", "I can't", "I don't
             have access", "needs your login", ...) with zero memory reads this
             turn -> block once: search your standing grants first.

Evidence, in order of preference:
  1. the harness transcript (Claude Code JSONL; Codex when it matches) — the
     turn is everything after the last real user message;
  2. the per-turn tally written by tool_tally.py (Gemini CLI, Cursor, or when
     the transcript is missing/unparseable).

Escape hatches: stop_hook_active (never double-block), the literal marker
CTXSTORE-DOWN in the final text, and --client cursor emits a followup_message
instead of a block because Cursor's stop hook cannot block.
Fail-open: any parse error exits 0 with no output.
"""
from __future__ import annotations

import json
import os
import re
import sys

WRITE_TOOLS = ("store_fact", "store_facts", "store_session_summary")
READ_TOOLS = ("search_facts", "get_fact", "list_facts_by_key_prefix", "load_context",
              "search_context", "index_search", "get_fact_history", "wake_status")
MEMORY_MARKERS = ("ctxstore",)
BLOCKED_PHRASES = re.compile(
    r"\b(only you can|i can'?t\b|i cannot\b|i can not\b|i don'?t have access|i do not have access|"
    r"needs? your (login|password|credentials|approval)|you'?ll need to|you will need to|"
    r"i'?m not able to|i am not able to|i have no way to)",
    re.IGNORECASE,
)

WRITE_REASON = (
    "RITUAL INCOMPLETE: this turn ran {tools} tool calls with zero memory writes. Before "
    "ending the turn: store_fact what you did and learned (progress, decisions, state), "
    "and update your closing self-note if this closes a chapter. If the memory server is "
    "genuinely unreachable, say so with the literal marker CTXSTORE-DOWN. Then stop."
)
READ_REASON = (
    "CHECK YOUR GRANTS FIRST: this reply says you are blocked or lack access, but you made no "
    "memory read this turn. The person may already have given you that capability or the "
    "credential's location. Run search_facts on the capability (and get_fact on any "
    "conventions/* or grants key it returns) before claiming you cannot. If it is truly "
    "not there, say so and stop."
)


def _text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
    return ""


def from_transcript(path: str) -> dict | None:
    """Claude Code JSONL: {type: user|assistant, message: {content: [...]}}."""
    if not path or not os.path.isfile(path):
        return None
    entries = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except Exception:
        return None
    if not entries or not any(e.get("type") in ("user", "assistant") for e in entries):
        return None

    last_user = -1
    for i, e in enumerate(entries):
        if e.get("type") != "user":
            continue
        content = e.get("message", {}).get("content")
        if isinstance(content, str) and content.strip():
            last_user = i
        elif isinstance(content, list):
            kinds = {c.get("type") for c in content if isinstance(c, dict)}
            if "text" in kinds and "tool_result" not in kinds:
                last_user = i
    if last_user < 0:
        return None

    tools = writes = reads = 0
    last_text = ""
    for e in entries[last_user + 1:]:
        if e.get("type") != "assistant":
            continue
        content = e.get("message", {}).get("content")
        if not isinstance(content, list):
            continue
        for c in content:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use":
                tools += 1
                name = (c.get("name") or "").lower()
                memory = any(m in name for m in MEMORY_MARKERS) or any(t in name for t in WRITE_TOOLS + READ_TOOLS)
                if memory and any(w in name for w in WRITE_TOOLS):
                    writes += 1
                if memory and any(r in name for r in READ_TOOLS):
                    reads += 1
            elif c.get("type") == "text":
                last_text = c.get("text") or last_text
    return {"tools": tools, "writes": writes, "reads": reads, "last_text": last_text}


def from_tally(session: str) -> dict | None:
    d = os.environ.get("CTXSTORE_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".ctxstore", "turns")
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in (session or "nosession"))[:120]
    try:
        with open(os.path.join(d, safe + ".json")) as fh:
            s = json.load(fh)
            return s if isinstance(s, dict) else None
    except Exception:
        return None


def decide(ev: dict, threshold: int) -> str | None:
    """Return a block reason or None. Write check first: it is the cheaper habit."""
    text = ev.get("last_text") or ""
    if "CTXSTORE-DOWN" in text:
        return None
    tools = int(ev.get("tools", 0))
    if tools >= threshold and int(ev.get("writes", 0)) == 0:
        return WRITE_REASON.format(tools=tools)
    if BLOCKED_PHRASES.search(text) and int(ev.get("reads", 0)) == 0:
        return READ_REASON
    return None


def main(argv: list[str]) -> int:
    client = "claude-code"
    if "--client" in argv:
        i = argv.index("--client")
        if i + 1 < len(argv):
            client = argv[i + 1]
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    if payload.get("stop_hook_active"):
        return 0
    try:
        threshold = int(os.environ.get("CTXSTORE_WORK_THRESHOLD", "5"))
    except ValueError:
        threshold = 5

    session = str(payload.get("session_id") or payload.get("conversation_id") or "nosession")
    ev = from_transcript(payload.get("transcript_path", "")) if client in ("claude-code", "codex") else None
    if ev is None:
        ev = from_tally(session)
    if ev is None:
        return 0
    # Gemini's AfterAgent hands us the final text directly; prefer it.
    if payload.get("prompt_response"):
        ev = dict(ev, last_text=str(payload["prompt_response"]))

    reason = decide(ev, threshold)
    if not reason:
        return 0
    if client == "cursor":
        # Cursor's stop hook cannot block; it can queue one follow-up (loop_limit applies).
        print(json.dumps({"followup_message": reason}))
    else:
        print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
