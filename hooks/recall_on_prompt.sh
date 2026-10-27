#!/usr/bin/env bash
# recall_on_prompt.sh — cued recall: search the store with the person's prompt
# and hand the model the top three pointers before it starts reasoning.
# Events: Claude Code / Codex UserPromptSubmit, Gemini CLI BeforeAgent.
# (Cursor's beforeSubmitPrompt cannot inject context; see kit/README.md.)
# Also resets the per-turn tally used by the Stop checks. Never fails: exits 0.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ctxstore_key.sh"
. "$here/emit.sh"

IN=$(cat 2>/dev/null || echo '{}')
PROMPT=$(printf '%s' "$IN" | jq -r '.prompt // .user_prompt // empty' 2>/dev/null | head -c 400)
SESSION=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"' 2>/dev/null)

# New turn: reset the tally the tool hooks accumulate.
python3 "$here/tool_tally.py" --reset --session "$SESSION" >/dev/null 2>&1 || true

# Very short prompts ("ok", "go", "yes") carry no cue worth a round trip.
[ "${#PROMPT}" -ge "${CTXSTORE_RECALL_MIN_CHARS:-12}" ] || exit 0
# Scheduled routine prompts wake from the index already; a search on their
# boilerplate returns the routine's own past receipts.
case "$PROMPT" in
  "MORNING BRIEF"*|"LAUNCH WORK CYCLE"*|"NIGHT CHECK"*|"SMOKE ("*) exit 0 ;;
esac

# Ask for 12 and let ctxstore_pointers trim and rerank: telemetry and sub-floor
# hits are removed after the search and prompt keywords boost the specific
# fact over generic high-cosine ones, so 3 raw results often left 0-1 real
# pointers and the wrong ones.
RES=$(ctxstore_search "$PROMPT" 12) || exit 0
LINES=$(printf '%s' "$RES" | ctxstore_pointers "$PROMPT")
[ -n "$LINES" ] || exit 0

# Keep the pointers so post_tool.py can replay them on harnesses that discard
# UserPromptSubmit context (Grok CLI).
printf '%s' "$LINES" | python3 "$here/tool_tally.py" --set-pointers --session "$SESSION" >/dev/null 2>&1 || true

emit_context "UserPromptSubmit" "RECALL (top memory matches for this prompt; get_fact(key=...) for the body, search_facts for more):
$LINES" 2>/dev/null
exit 0
