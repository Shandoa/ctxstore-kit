#!/usr/bin/env bash
# secret_guard.sh — refuse store_fact / store_facts calls whose text carries a
# token-shaped value. The store holds POINTERS to secrets, never values.
# Events: Claude Code / Codex PreToolUse (matcher mcp__ctxstore__store_fact*),
# Gemini CLI BeforeTool, Cursor beforeMCPExecution. Fail-open on internal error.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/emit.sh"

IN=$(cat 2>/dev/null || echo '{}')
NAME=$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null)
case "$NAME" in *store_fact*|"") ;; *) exit 0 ;; esac
TEXT=$(printf '%s' "$IN" | jq -r '.tool_input | (.text // "") + " " + ((.facts // []) | map(.text // "") | join(" "))' 2>/dev/null)
[ -n "${TEXT// /}" ] || exit 0

PATTERN='emk_[A-Za-z0-9]{20,}|0\.[0-9a-f]{8}-[0-9a-f-]{27}\.[A-Za-z0-9+/=:._-]{20,}|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY'
if printf '%s' "$TEXT" | grep -qE "$PATTERN" 2>/dev/null; then
  emit_deny "PreToolUse" "SECRET-GUARD: the fact text contains a token-shaped value (emk_/sk-/ghp_/AKIA/xox/AIza/private-key). Secret values never enter the store. Store a POINTER instead: what it is, where it lives (keychain service or vault item name), when it rotates. If this is a false positive, rewrite the text so it no longer matches a token pattern." 2>/dev/null
fi
exit 0
