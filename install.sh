#!/usr/bin/env bash
# install.sh, `ctxstore init`: install the memory-ritual hooks into a harness.
#
#   kit/install.sh --client claude-code|gemini-cli|cursor|codex|all [--project DIR]
#   kit/install.sh --client <c> --uninstall
#   kit/install.sh --client <c> --dry-run
#
# What it does, idempotently (run it twice, nothing changes the second time):
#   1. copies kit/hooks/* to $HOME/.ctxstore/kit/hooks (the harness configs point there,
#      so the repo checkout is not needed afterwards);
#   2. merges the client's hook entries into its settings file with jq, our entries are
#      recognised by the "/.ctxstore/kit/hooks/" path in their command, so re-running
#      replaces only ours and never touches entries the person wrote;
#   3. appends the memory snippet to the client's instructions file once (marker:
#      "## Memory (ctxstore)").
# Needs: bash, jq, python3, curl. macOS or Linux. No sudo. Writes only under ~/.ctxstore
# and the chosen client's own config directory (and --project DIR/.cursor for Cursor).
# Every change is printed.
set -euo pipefail

here=""
[ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Remote mode: `curl -fsSL https://raw.githubusercontent.com/Shandoa/ctxstore-kit/main/install.sh | bash -s -- --client claude-code`
# has no kit tree beside it. Fetch the repo tarball once and re-run from it.
if [ -z "$here" ] || [ ! -d "$here/hooks" ]; then
  KIT_URL="${CTXSTORE_KIT_URL:-https://github.com/Shandoa/ctxstore-kit/archive/refs/heads/main.tar.gz}"
  tmp="$(mktemp -d)"
  curl -fsSL "$KIT_URL" | tar -xz --strip-components=1 -C "$tmp" || { echo "install: could not fetch $KIT_URL" >&2; exit 1; }
  exec bash "$tmp/install.sh" "$@"
fi
CLIENT=""; UNINSTALL=0; DRY=0; PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --client) CLIENT="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --project) PROJECT="$2"; shift 2 ;;
    -h|--help) sed -n 2,20p "$0"; exit 0 ;;
    *) echo "install: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$CLIENT" ] || { echo "install: --client is required (claude-code|gemini-cli|cursor|codex|all)" >&2; exit 2; }
for dep in jq python3; do command -v "$dep" >/dev/null 2>&1 || { echo "install: $dep is required" >&2; exit 2; }; done

KIT="$HOME/.ctxstore/kit/hooks"
TAG="/.ctxstore/kit/hooks/"
say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" = 1 ]; then say "  (dry-run) $*"; else "$@"; fi; }

install_hooks_dir() {
  say "hooks -> $KIT"
  run mkdir -p "$KIT"
  [ "$DRY" = 1 ] || { find "$here/hooks" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) -exec cp {} "$KIT"/ \; ; chmod +x "$KIT"/*.sh "$KIT"/*.py; printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$KIT/.installed"; }
}

# fragment_json <fragment-file>, the fragment with __KIT__ resolved.
fragment_json() { sed "s#__KIT__#$KIT#g" "$1"; }

# merge_claude_style <settings-file> <fragment-file>
#   settings.hooks[event] is a list of {matcher?, hooks:[{type,command,...}]}.
merge_claude_style() {
  local file="$1" frag="$2" tmp
  [ -f "$file" ] || { run mkdir -p "$(dirname "$file")"; [ "$DRY" = 1 ] || echo '{}' > "$file"; }
  tmp=$(mktemp)
  jq --argjson add "$(fragment_json "$frag")" --arg tag "$TAG" '
    def ours: (.hooks // []) | any(.[]; (.command // "") | contains($tag));
    .hooks = ((.hooks // {}) as $h
      | ($add.hooks | keys) as $events
      | reduce $events[] as $ev ($h;
          .[$ev] = (((.[$ev] // []) | map(select(ours | not))) + $add.hooks[$ev])))
  ' <(cat "$file" 2>/dev/null || echo '{}') > "$tmp"
  if [ "$DRY" = 1 ]; then say "  (dry-run) would write $file"; rm -f "$tmp"; else mv "$tmp" "$file"; say "hooks merged -> $file"; fi
}

remove_claude_style() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  tmp=$(mktemp)
  jq --arg tag "$TAG" '
    def ours: (.hooks // []) | any(.[]; (.command // "") | contains($tag));
    if .hooks then .hooks |= (with_entries(.value |= map(select(ours | not))) | with_entries(select(.value | length > 0))) else . end
    | if (.hooks // {}) == {} then del(.hooks) else . end
  ' "$file" > "$tmp"
  if [ "$DRY" = 1 ]; then say "  (dry-run) would write $file"; rm -f "$tmp"; else mv "$tmp" "$file"; say "hooks removed <- $file"; fi
}

# merge_cursor_style <hooks.json> <fragment-file>, hooks[event] is a list of {command,...}.
merge_cursor_style() {
  local file="$1" frag="$2" tmp
  [ -f "$file" ] || { run mkdir -p "$(dirname "$file")"; [ "$DRY" = 1 ] || echo '{"version":1,"hooks":{}}' > "$file"; }
  tmp=$(mktemp)
  jq --argjson add "$(fragment_json "$frag")" --arg tag "$TAG" '
    .version = (.version // 1)
    | .hooks = ((.hooks // {}) as $h
      | reduce ($add.hooks | keys)[] as $ev ($h;
          .[$ev] = (((.[$ev] // []) | map(select((.command // "") | contains($tag) | not))) + $add.hooks[$ev])))
  ' <(cat "$file" 2>/dev/null || echo '{"version":1,"hooks":{}}') > "$tmp"
  if [ "$DRY" = 1 ]; then say "  (dry-run) would write $file"; rm -f "$tmp"; else mv "$tmp" "$file"; say "hooks merged -> $file"; fi
}

remove_cursor_style() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  tmp=$(mktemp)
  jq --arg tag "$TAG" '
    if .hooks then .hooks |= (with_entries(.value |= map(select((.command // "") | contains($tag) | not))) | with_entries(select(.value | length > 0))) else . end
  ' "$file" > "$tmp"
  if [ "$DRY" = 1 ]; then say "  (dry-run) would write $file"; rm -f "$tmp"; else mv "$tmp" "$file"; say "hooks removed <- $file"; fi
}

# append_once <target-file> <snippet-file>
append_once() {
  local file="$1" snip="$2"
  if [ -f "$file" ] && grep -q '^## Memory (ctxstore)' "$file"; then say "snippet already in $file"; return 0; fi
  run mkdir -p "$(dirname "$file")"
  if [ "$DRY" = 1 ]; then say "  (dry-run) would append snippet to $file"; else { [ -f "$file" ] && printf '\n' >> "$file"; cat "$snip" >> "$file"; say "snippet appended -> $file"; }; fi
}

remove_snippet() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -q '^## Memory (ctxstore)' "$file" || return 0
  if [ "$DRY" = 1 ]; then say "  (dry-run) would remove snippet from $file"; return 0; fi
  python3 - "$file" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
# drop from the marker heading to the next H2 (or EOF)
s2 = re.sub(r"\n?## Memory \(ctxstore\)\n.*?(?=\n## |\Z)", "", s, flags=re.S)
open(p, "w").write(s2)
PY
  say "snippet removed <- $file"
}

do_claude_code() {
  local settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}" md="${CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
  if [ "$UNINSTALL" = 1 ]; then remove_claude_style "$settings"; remove_snippet "$md"; return; fi
  merge_claude_style "$settings" "$here/claude-code/settings.hooks.json"
  append_once "$md" "$here/snippets/CLAUDE.md.snippet"
}

do_gemini_cli() {
  local settings="${GEMINI_SETTINGS:-$HOME/.gemini/settings.json}" md="${GEMINI_MD:-$HOME/.gemini/GEMINI.md}"
  if [ "$UNINSTALL" = 1 ]; then remove_claude_style "$settings"; remove_snippet "$md"; return; fi
  merge_claude_style "$settings" "$here/gemini-cli/settings.hooks.json"
  append_once "$md" "$here/snippets/CLAUDE.md.snippet"
}

do_cursor() {
  local hooks="${CURSOR_HOOKS:-$HOME/.cursor/hooks.json}"
  if [ "$UNINSTALL" = 1 ]; then
    remove_cursor_style "$hooks"
    [ -n "$PROJECT" ] && run rm -f "$PROJECT/.cursor/rules/ctxstore-memory.mdc"
    return
  fi
  merge_cursor_style "$hooks" "$here/cursor/hooks.json"
  if [ -n "$PROJECT" ]; then
    run mkdir -p "$PROJECT/.cursor/rules"
    run cp "$here/cursor/ctxstore-memory.mdc" "$PROJECT/.cursor/rules/ctxstore-memory.mdc"
    say "rule -> $PROJECT/.cursor/rules/ctxstore-memory.mdc"
  else
    say "note: Cursor reads rules per project; re-run with --project <dir> to install kit/cursor/ctxstore-memory.mdc there"
  fi
}

# codex_hooks_supported, true when the installed Codex CLI lists the `hooks` feature
# (stable since 0.15x). Older CLIs get the AGENTS.md + notify fallback.
codex_hooks_supported() {
  command -v codex >/dev/null 2>&1 || return 1
  codex features list 2>/dev/null | awk '$1=="hooks"{found=1} END{exit found?0:1}'
}

do_codex() {
  local hooks="${CODEX_HOOKS:-$HOME/.codex/hooks.json}" md="${CODEX_MD:-$HOME/.codex/AGENTS.md}" toml="${CODEX_TOML:-$HOME/.codex/config.toml}"
  if [ "$UNINSTALL" = 1 ]; then
    remove_claude_style "$hooks"; remove_snippet "$md"
    if [ -f "$toml" ] && grep -q 'ctxstore kit notify' "$toml"; then
      [ "$DRY" = 1 ] || python3 - "$toml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"\n# ctxstore kit notify\nnotify = \[[^\]]*\]\n", "\n", s))
PY
      say "notify fallback removed <- $toml"
    fi
    return
  fi
  append_once "$md" "$here/snippets/AGENTS.md.snippet"
  if [ "${CODEX_FORCE_MODE:-}" = "hooks" ] || { [ "${CODEX_FORCE_MODE:-}" != "notify" ] && codex_hooks_supported; }; then
    merge_claude_style "$hooks" "$here/codex/hooks.json"
    if [ -f "$toml" ] && grep -qE '^\s*hooks\s*=\s*false' "$toml"; then
      say "warning: $toml sets features.hooks = false; set it to true for the kit hooks to run"
    fi
    say "codex: lifecycle hooks installed (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, PreCompact)."
    say "codex: on first run Codex asks you to trust these hooks; automation can pass --dangerously-bypass-hook-trust."
  else
    say "codex: this CLI does not list the hooks feature, falling back to AGENTS.md + notify (observational only)."
    if [ -f "$toml" ] && grep -qE '^\s*notify\s*=' "$toml"; then
      say "notify already set in $toml; the kit's notify script is at $KIT/codex_notify.sh, chain it yourself"
    else
      if [ "$DRY" = 1 ]; then say "  (dry-run) would append notify = [...] to $toml"; else
        run mkdir -p "$(dirname "$toml")"; printf '\n# ctxstore kit notify\nnotify = ["bash", "%s/codex_notify.sh"]\n' "$KIT" >> "$toml"; say "notify fallback -> $toml"; fi
    fi
  fi
}

[ "$UNINSTALL" = 1 ] || install_hooks_dir
case "$CLIENT" in
  claude-code) do_claude_code ;;
  gemini-cli) do_gemini_cli ;;
  cursor) do_cursor ;;
  codex) do_codex ;;
  all) do_claude_code; do_gemini_cli; do_cursor; do_codex ;;
  *) echo "install: unknown client $CLIENT" >&2; exit 2 ;;
esac
if [ "$UNINSTALL" = 1 ]; then
  say "done. $KIT left in place; remove it with: rm -rf $HOME/.ctxstore/kit"
else
  say "done. Key resolution: CTXSTORE_API_KEY, Keychain service ctxstore-api-key, ~/.ctxstore/key, or the ctxstore MCP header in the client config."
fi
