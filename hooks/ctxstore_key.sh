#!/usr/bin/env bash
# ctxstore_key.sh — resolve the ctxstore API key and base URL for the hook kit.
# Sourced by the shell hooks; never prints the key. Resolution order:
#   1. $CTXSTORE_API_KEY (already in the environment)
#   2. macOS Keychain, service $CTXSTORE_KEYCHAIN_SERVICE (default: ctxstore-api-key)
#   3. ~/.ctxstore/key (mode 0600, one line)
#   4. the Authorization header of the `ctxstore` MCP server in ~/.claude.json,
#      ~/.claude/mcp.json, ~/.gemini/settings.json, ~/.cursor/mcp.json or
#      ~/.codex/config.toml (Bearer emk_...)
# Sets CTXSTORE_API_KEY and CTXSTORE_URL (default https://ctxstore.ai). Returns 1
# when no key is found so callers can exit 0 quietly (hooks must never break a session).

ctxstore_resolve_key() {
  CTXSTORE_URL="${CTXSTORE_URL:-https://ctxstore.ai}"
  if [ -n "${CTXSTORE_API_KEY:-}" ]; then return 0; fi
  local svc="${CTXSTORE_KEYCHAIN_SERVICE:-ctxstore-api-key}" k=""
  if command -v security >/dev/null 2>&1; then
    k=$(security find-generic-password -s "$svc" -w 2>/dev/null || true)
  fi
  if [ -z "$k" ] && [ -r "$HOME/.ctxstore/key" ]; then
    k=$(head -n1 "$HOME/.ctxstore/key" | tr -d '[:space:]')
  fi
  if [ -z "$k" ] && command -v jq >/dev/null 2>&1; then
    local f
    for f in "$HOME/.claude.json" "$HOME/.claude/mcp.json" "$HOME/.gemini/settings.json" "$HOME/.cursor/mcp.json"; do
      [ -r "$f" ] || continue
      k=$(jq -r '.mcpServers.ctxstore.headers.Authorization // empty' "$f" 2>/dev/null | sed -E 's/^[Bb]earer +//')
      [ -n "$k" ] && break
    done
  fi
  if [ -z "$k" ] && [ -r "$HOME/.codex/config.toml" ]; then
    k=$(grep -E -o 'Bearer +emk_[A-Za-z0-9_-]+' "$HOME/.codex/config.toml" 2>/dev/null | head -n1 | sed -E 's/^Bearer +//')
  fi
  [ -n "$k" ] || return 1
  CTXSTORE_API_KEY="$k"
  export CTXSTORE_API_KEY CTXSTORE_URL
  return 0
}

# ctxstore_search "<query>" [top_k] — POST /api/v1/facts/search, prints JSON or nothing.
ctxstore_search() {
  local q="$1" k="${2:-3}"
  ctxstore_resolve_key || return 1
  curl -sS -m "${CTXSTORE_TIMEOUT:-6}" -X POST "$CTXSTORE_URL/api/v1/facts/search" \
    -H "Authorization: Bearer $CTXSTORE_API_KEY" -H 'Content-Type: application/json' \
    -H 'User-Agent: ctxstore-kit/1' \
    -d "$(jq -cn --arg q "$q" --argjson k "$k" '{query:$q, top_k:$k}')" 2>/dev/null
}

# ctxstore_pointers <search-json> — up to 3 "key (score) — first 170 chars" lines.
# Drops telemetry and session noise (stream:, loop:, archive:, conversation:,
# compaction:, session-latest, ci:smoke) and anything under the similarity
# floor. Floor default 0.66: on a real tenant true neighbours score 0.67-0.70
# and gibberish 0.59-0.63 (measured 2026-10-04/05), and raw search ranks
# stream:screen telemetry at 0.66 above real facts, so callers should ask for
# more than 3 results (8) and let this trim.
#
# Optional second argument: the prompt. Pure cosine ranks generic "decision"
# and "digest" facts above the specific one (a project-specific question ranked the
# matching facts 6th and 9th behind unrelated 0.68s on 2026-10-05), so each
# prompt keyword (>=4 letters, stopwords dropped) found in a hit's key or text
# adds 0.04 before the floor and the sort. Shown score stays the raw cosine.
ctxstore_pointers() {
  local prompt="${1:-}" kw
  kw=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | tr ' ' '\n' \
       | awk 'length($0) >= 4' \
       | grep -v -x -E 'what|did|about|that|this|with|from|have|will|your|when|where|which|there|their|into|over|than|then|them|they|were|been|also|some|just|like|only|more|most|very|make|made|does|done|want|need|should|would|could|please|tell|know|think|still|again|back|here|were|whats|going|want' \
       | awk '!seen[$0]++' | head -8 | jq -R . | jq -cs . 2>/dev/null)
  [ -n "$kw" ] || kw='[]'
  jq -r --argjson floor "${CTXSTORE_RECALL_FLOOR:-0.66}" --argjson kw "$kw" '
    [.results[]?
      | select((.key // "") | test("^(stream:|loop:|archive:|conversation:|compaction:|session-latest|session-seed|ci:smoke)") | not)
      | . as $f
      | (((.key // "") + " " + (.text // "")) | ascii_downcase) as $hay
      | ($kw | map(select(. as $w | $hay | contains($w))) | length) as $hits
      | $f + {boost: (((.score // 0) | tonumber) + 0.04 * $hits)}
      | select(.boost >= $floor)]
    | sort_by(-.boost)
    | .[:3][]
    | ((.key // ("id:" + (.fact_id // "")[0:8]))
       + " (" + ((((.score // 0) | tonumber) * 100) | floor | tostring) + ") — "
       + ((.text // "") | gsub("\\s+"; " ") | .[0:170]))
  ' 2>/dev/null
}
