#!/usr/bin/env bash
# recall_on_error.sh — when a shell command fails, ask the store whether this
# failure is already known before the model re-derives it or asks the person.
# Events: Claude Code / Codex PostToolUseFailure (matcher Bash), Gemini CLI
# AfterTool (run_shell_command; fires only when the response looks like an
# error), Cursor afterShellExecution (observational: logs only, cannot inject).
# Never fails: exits 0.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ctxstore_key.sh"
. "$here/emit.sh"

IN=$(cat 2>/dev/null || echo '{}')
CMD=$(printf '%s' "$IN" | jq -r '.tool_input.command // .command // empty' 2>/dev/null | head -c 200)
ERR=$(printf '%s' "$IN" | jq -r '(.error // .error_message // .tool_response.stderr // .tool_response.error // .tool_response.output // .output // empty) | tostring' 2>/dev/null | head -c 300)
[ -n "$CMD" ] || exit 0
# Gemini AfterTool fires on success too; only recall when something went wrong.
if [ "${CTXSTORE_CLIENT:-}" = "gemini-cli" ] && ! printf '%s' "$ERR" | grep -qiE 'error|fail|not found|denied|exit(ed)? [1-9]'; then
  exit 0
fi

Q=$(printf '%s %s' "${CMD%% *}" "$ERR" | head -c 250)
RES=$(ctxstore_search "$Q" 3) || exit 0
LINES=$(printf '%s' "$RES" | ctxstore_pointers)
[ -n "$LINES" ] || exit 0

[ "${CTXSTORE_CLIENT:-}" = "cursor" ] && exit 0   # nowhere to put it in Cursor
emit_context "PostToolUseFailure" "RECALL-ON-ERROR (the store may already know this failure — read before re-deriving or asking the person):
Failed command: $CMD
$LINES" 2>/dev/null
exit 0
