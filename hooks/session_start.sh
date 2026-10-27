#!/usr/bin/env bash
# session_start.sh — inject the memory ritual at session start, and a reload
# directive when the session is resuming from a compaction.
# Events: Claude Code / Codex SessionStart (matcher "compact" for the reload),
# Gemini CLI SessionStart, Cursor sessionStart. Never fails: exits 0 always.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/emit.sh"

IN=$(cat 2>/dev/null || echo '{}')
SOURCE=$(printf '%s' "$IN" | jq -r '.source // .trigger // ""' 2>/dev/null || echo "")

RITUAL='MEMORY RITUAL (ctxstore, enforced by hooks): 1) READ first — your memory arrived with the first tool result; before answering anything about the person or the work, search_facts or get_fact. If a message from another agent may be waiting, list_facts_by_key_prefix on your comms prefix. 2) WRITE AS YOU GO — store_fact in the same turn a decision, learning, or state change happens; short, searchable, stable key when it will change later. The Stop hook blocks a turn that did real work and stored nothing. 3) NEVER CLAIM YOU ARE BLOCKED WITHOUT LOOKING — before saying "only you can", "I cannot", or "I do not have access", search_facts for a standing grant; the person may already have given you the capability. 4) CLOSE — store_session_summary, then agent:<id>:self-note:closing (what shipped, what is open) so the next session starts where this one stopped. 5) SECRETS never enter the store; keep pointers, values stay in the keychain or vault.'

COMPACT='COMPACTION JUST FLATTENED THIS SESSION. The summary you were handed is lossy. Before asserting any status: wake_status(), then get_fact your closing and opening self-notes and any *:status:current keys; treat the summary as a lead and the store as the truth; tell the person a compaction occurred.'

case "$SOURCE" in
  compact|resume) TEXT="$COMPACT

$RITUAL" ;;
  *) TEXT="$RITUAL" ;;
esac

emit_context "SessionStart" "$TEXT" 2>/dev/null
exit 0
