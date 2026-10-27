#!/usr/bin/env bash
# compaction_ledger.sh — make every context compaction an observed event:
# append to ~/.ctxstore/compaction-ledger.jsonl and, when a key resolves,
# fire-and-forget a fact (key compaction:<session>:<epoch>) so a later session
# can count and locate the flattening. Events: Claude Code / Codex PreCompact,
# Gemini CLI PreCompress, Cursor preCompact. Never blocks: exits 0.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ctxstore_key.sh"

IN=$(cat 2>/dev/null || echo '{}')
SESSION=$(printf '%s' "$IN" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
TRANSCRIPT=$(printf '%s' "$IN" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
TRIGGER=$(printf '%s' "$IN" | jq -r '.trigger // "auto"' 2>/dev/null || echo auto)
EPOCH=$(date +%s); ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LEDGER="${CTXSTORE_LEDGER:-$HOME/.ctxstore/compaction-ledger.jsonl}"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null

LINES=0; BYTES=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  LINES=$(wc -l < "$TRANSCRIPT" | tr -d ' '); BYTES=$(wc -c < "$TRANSCRIPT" | tr -d ' ')
fi
printf '{"ts":"%s","session_id":"%s","client":"%s","trigger":"%s","transcript":"%s","lines":%s,"bytes":%s}\n' \
  "$ISO" "$SESSION" "${CTXSTORE_CLIENT:-claude-code}" "$TRIGGER" "$TRANSCRIPT" "$LINES" "$BYTES" >> "$LEDGER" 2>/dev/null

if ctxstore_resolve_key; then
  N=$(grep -c "\"session_id\":\"$SESSION\"" "$LEDGER" 2>/dev/null || echo 1)
  BODY=$(jq -n --arg key "compaction:$SESSION:$EPOCH" \
    --arg text "COMPACTION #$N for session $SESSION at $ISO (${CTXSTORE_CLIENT:-claude-code}, trigger $TRIGGER). Transcript at that moment: ${TRANSCRIPT:-n/a} ($LINES lines, $BYTES bytes). The flattened span is recoverable from that file." \
    '{key:$key, text:$text, category:"technical", namespace:"agent-ops", layer:3}')
  curl -sS -m 5 -X POST "$CTXSTORE_URL/api/v1/facts" -H "Authorization: Bearer $CTXSTORE_API_KEY" \
    -H 'Content-Type: application/json' -H 'User-Agent: ctxstore-kit/1' -d "$BODY" >/dev/null 2>&1 &
fi
exit 0
