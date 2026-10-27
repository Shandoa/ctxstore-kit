#!/usr/bin/env bash
# recall_before_build.sh — prior art, before the hands move.
# Events: Claude Code / Codex PreToolUse for Write|Edit|MultiEdit|NotebookEdit|Bash.
#
# recall_on_prompt.sh fires on what the person says. This one fires on what the
# agent is ABOUT TO DO: the first time in a session it writes or edits a file,
# cuts a branch or opens a PR, the store and the repository are searched with
# the nouns of that action and the result lands in context before the tool
# runs. The agent cannot skip it, because it is not the agent's to skip.
#
# Why: an agent can design something that already exists. The first Write to a
# file is the cheapest moment to put the stored map of what is already built in
# front of it, before the request is assembled.
#
# Output: hookSpecificOutput.additionalContext (never a deny). Fires once per
# (session, subject); silent on scratch paths. Fail-open, budget ~5 s.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ctxstore_key.sh"
. "$here/emit.sh"

IN=$(cat 2>/dev/null || echo '{}')
SESSION=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"' 2>/dev/null)
TOOL=$(printf '%s' "$IN" | jq -r '.tool_name // ""' 2>/dev/null)
STATE_DIR="${TMPDIR:-/tmp}/ctxstore-kit/recall-before-build/${SESSION}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

SUBJECT=""; QUERY=""; REPO=""
case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit)
    FP=$(printf '%s' "$IN" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
    [ -n "$FP" ] || exit 0
    case "$FP" in */scratchpad/*|*/.claude/*|/tmp/*|/private/tmp/*|*/node_modules/*) exit 0;; esac
    SUBJECT="file:$FP"
    BASE=$(basename "$FP"); STEM="${BASE%.*}"; DIR=$(basename "$(dirname "$FP")")
    QUERY=$(printf '%s %s' "$STEM" "$DIR" | sed -E 's/([a-z])([A-Z])/\1 \2/g; s/[_.-]+/ /g' | tr '[:upper:]' '[:lower:]')
    REPO=$(cd "$(dirname "$FP")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    ;;
  Bash)
    CMD=$(printf '%s' "$IN" | jq -r '.tool_input.command // ""' 2>/dev/null)
    SLUG=$(printf '%s' "$CMD" | grep -oE '(worktree add[^-]*-b|checkout -b|switch -c|--head)[[:space:]]+[A-Za-z0-9_./-]+' | head -1 | awk '{print $NF}')
    [ -n "$SLUG" ] || exit 0
    SUBJECT="branch:$SLUG"
    QUERY=$(printf '%s' "$SLUG" | sed -E 's#^[a-z]+/##; s/[_.-]+/ /g' | tr '[:upper:]' '[:lower:]')
    REPO=$(git rev-parse --show-toplevel 2>/dev/null)
    ;;
  *) exit 0;;
esac
[ -n "$QUERY" ] || exit 0

MARK="$STATE_DIR/$(printf '%s' "$SUBJECT" | cksum | awk '{print $1}')"
[ -e "$MARK" ] && exit 0
: > "$MARK"

# nouns only: drop path boilerplate and short tokens; keep up to 6
WORDS=$(printf '%s' "$QUERY" | tr ' ' '\n' \
  | grep -v -x -E 'the|and|for|with|from|into|index|main|test|tests|src|lib|app|new|old|current|html|py|js|sh|md|static|landing|server|config|util|utils|common|base|core|scripts|fix|feat|chore|hooks|kit' \
  | awk 'length($0) >= 3' | awk '!seen[$0]++' | head -6 | tr '\n' ' ' | sed 's/ $//')
[ -n "$WORDS" ] || exit 0

# Plain nouns rank the product-map facts first; a project-name suffix drags
# identity facts up (measured 2026-10-09). Map and PR-digest facts get a boost
# on top of the keyword rerank, because "do we already have X" is their job.
LINES=""
RES=$(ctxstore_search "$WORDS" 12) || RES=""
if [ -n "$RES" ]; then
  LINES=$(printf '%s' "$RES" | CTXSTORE_RECALL_FLOOR="${CTXSTORE_PRIOR_ART_FLOOR:-0.60}" ctxstore_pointers "$WORDS map pr" 2>/dev/null | head -4)
fi

FILES=""
if [ -n "$REPO" ] && command -v rg >/dev/null 2>&1; then
  PAT=$(printf '%s' "$WORDS" | tr ' ' '\n' | awk 'length($0) >= 5' | head -3 | paste -sd'|' -)
  if [ -n "$PAT" ]; then
    FILES=$(cd "$REPO" && rg -il --glob '!*.lock' --glob '!node_modules' --glob '!.venv*' --glob '!*.min.*' -e "$PAT" . 2>/dev/null | grep -vE '^\./(tests?/|\.git/)' | head -8 | sed 's#^\./#  · #')
  fi
fi

[ -z "$LINES" ] && [ -z "$FILES" ] && exit 0
TEXT="PRIOR ART for '$WORDS' (the store and the repo already hold these; read before building, say 'prior art: ...' in the PR):"
[ -n "$LINES" ] && TEXT="$TEXT
$LINES"
[ -n "$FILES" ] && TEXT="$TEXT
  repo files mentioning it:
$FILES"
emit_context "PreToolUse" "$TEXT" 2>/dev/null
exit 0
