#!/usr/bin/env bash
# emit.sh — one place that knows each harness's hook output dialect.
# Sourced by the shell hooks. $CTXSTORE_CLIENT is one of
# claude-code | codex | gemini-cli | cursor (the installer sets it per hook entry).
#
#   emit_context "<event>" "<text>"   inject text into the conversation
#   emit_deny    "<event>" "<reason>" refuse the tool call
#
# Codex loads Claude-shaped hooks.json and speaks the same JSON, so it shares the
# claude-code branch.

emit_context() {
  local event="$1" text="$2"
  case "${CTXSTORE_CLIENT:-claude-code}" in
    cursor)
      # sessionStart is the only Cursor event that takes additional_context.
      jq -cn --arg t "$text" '{additional_context: $t}' ;;
    gemini-cli)
      jq -cn --arg t "$text" '{hookSpecificOutput: {additionalContext: $t}}' ;;
    *)
      jq -cn --arg e "$event" --arg t "$text" \
        '{hookSpecificOutput: {hookEventName: $e, additionalContext: $t}}' ;;
  esac
}

emit_deny() {
  local event="$1" reason="$2"
  case "${CTXSTORE_CLIENT:-claude-code}" in
    cursor)
      jq -cn --arg r "$reason" '{permission: "deny", user_message: $r, agent_message: $r}' ;;
    gemini-cli)
      jq -cn --arg r "$reason" '{decision: "deny", reason: $r}' ;;
    *)
      jq -cn --arg e "$event" --arg r "$reason" \
        '{hookSpecificOutput: {hookEventName: $e, permissionDecision: "deny", permissionDecisionReason: $r}}' ;;
  esac
}
