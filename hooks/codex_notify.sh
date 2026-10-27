#!/usr/bin/env bash
# codex_notify.sh — fallback for Codex CLIs without lifecycle hooks. Codex calls
# `notify` with one JSON argument per turn (type agent-turn-complete, thread-id,
# last-assistant-message, ...). It cannot block or inject; it can OBSERVE: when
# the turn's last message claims to be blocked, log it and, if a key resolves,
# store a nudge fact the next wake will surface. Never fails: exits 0.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ctxstore_key.sh"
PAYLOAD="${1:-}"
[ -n "$PAYLOAD" ] || exit 0
TYPE=$(printf '%s' "$PAYLOAD" | jq -r '.type // ""' 2>/dev/null)
MSG=$(printf '%s' "$PAYLOAD" | jq -r '.["last-assistant-message"] // .last_assistant_message // ""' 2>/dev/null | head -c 2000)
THREAD=$(printf '%s' "$PAYLOAD" | jq -r '.["thread-id"] // .thread_id // "nothread"' 2>/dev/null)
LOG="${CTXSTORE_LEDGER:-$HOME/.ctxstore/compaction-ledger.jsonl}"; LOG="$(dirname "$LOG")/codex-notify.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
printf '%s %s thread=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TYPE" "$THREAD" >> "$LOG" 2>/dev/null
if printf '%s' "$MSG" | grep -qiE "only you can|i can'?t\b|i cannot\b|don'?t have access|needs? your (login|password|credentials)"; then
  if ctxstore_resolve_key; then
    BODY=$(jq -n --arg key "agent-ops:codex:$THREAD:blocked-claim" \
      --arg text "Codex turn ended claiming to be blocked without hook enforcement (thread $THREAD). Next wake: search_facts for the standing grant before repeating the claim. Tail: $(printf '%s' "$MSG" | tail -c 300)" \
      '{key:$key, text:$text, category:"technical", namespace:"agent-ops", layer:3}')
    curl -sS -m 5 -X POST "$CTXSTORE_URL/api/v1/facts" -H "Authorization: Bearer $CTXSTORE_API_KEY" \
      -H 'Content-Type: application/json' -H 'User-Agent: ctxstore-kit/1' -d "$BODY" >/dev/null 2>&1 &
  fi
fi
exit 0
