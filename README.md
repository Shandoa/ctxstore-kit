# ctxstore-kit

Ambient recall hooks that give an AI coding agent persistent memory through [ctxstore.ai](https://ctxstore.ai). They search your memory store on every prompt and tool failure, and remind the agent to write what it learns, so Claude Code, Codex CLI, Gemini CLI and Cursor stop starting from zero.

The server delivers memory. It cannot make an agent *read before asking*, *write as it goes*, or *check its grants before saying "I can't"*. Those habits live in the harness, so this kit installs them as hooks.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Shandoa/ctxstore-kit/main/install.sh | bash -s -- --client claude-code
```

Swap `claude-code` for `gemini-cli`, `cursor` or `codex`, or use `all`. From a clone:

```sh
./install.sh --client claude-code
./install.sh --client cursor --project ~/code/myapp   # Cursor rules are per project
./install.sh --client claude-code --uninstall
```

Idempotent: run it twice, nothing changes the second time. It never overwrites hooks you wrote; ours carry `/.ctxstore/kit/hooks/` in their command and only those are replaced or removed. Needs `bash`, `jq`, `python3`, `curl`, on macOS or Linux. No sudo; it writes only under `~/.ctxstore` and the chosen client's own config directory, and prints every change.

## Get a key

Sign up at https://ctxstore.ai to get an account and API key, then connect the ctxstore MCP server in your client (see https://ctxstore.ai/docs).

## What is in this repo

| Path | Purpose |
|---|---|
| `install.sh` | installer and uninstaller; merges hook entries into each client's config |
| `hooks/` | the hook scripts themselves (bash and python), copied to `~/.ctxstore/kit/hooks` |
| `claude-code/` | hook entries for `~/.claude/settings.json` |
| `codex/` | hook entries for `~/.codex/hooks.json` and a `config.toml` snippet |
| `cursor/` | hook entries for `~/.cursor/hooks.json` and a per-project rule |
| `gemini-cli/` | hook entries for `~/.gemini/settings.json` |
| `snippets/` | the memory ritual text appended to `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` |

Key resolution, in order: `$CTXSTORE_API_KEY`, macOS Keychain service `ctxstore-api-key`, `~/.ctxstore/key`, or the `Authorization` header of the `ctxstore` MCP server in the client's own config. No key found: the recall hooks stay silent and nothing ever breaks a session.

## What each hook does, and why

| Hook | When | What | Why |
|---|---|---|---|
| `session_start.sh` | session start; again after a compaction | injects the five-line ritual (read first, write as you go, check grants before claiming blocked, close, no secrets); after compaction adds "the summary is a lead, the store is the truth" | an agent that wakes without the ritual re-asks and re-derives |
| `recall_on_prompt.sh` | every prompt | searches the store with the prompt text (8 results), drops telemetry and session noise and anything under the similarity floor (`CTXSTORE_RECALL_FLOOR`, default 0.66), and hands back up to 3 `key (score), headline` pointers; skips scheduled-routine prompts; resets the turn tally | ambient recall: the agent should not have to *think* to look.  In one audit of 854 agent turns, memory was read in 16% of turns without this hook |
| `recall_before_build.sh` | the first time in a session the agent writes or edits a file, cuts a branch, or opens a PR | searches the store with the nouns of the path or branch slug (12 results, keyword rerank, product-map and PR-digest facts boosted, floor `CTXSTORE_PRIOR_ART_FLOOR` 0.60) and ripgreps the repo for the same nouns; injects up to 4 facts and 8 files as `PRIOR ART`; once per subject per session; silent on scratch paths | prior art before the hands move. An agent can design something that already exists; the first Write to the file is the cheapest moment to show it the map. The prompt hook fires on what the person says, this one on what the agent is about to do |
| `tool_tally.py` | after every tool call / agent response | counts tools, memory writes, memory reads, keeps the last reply text, per session | evidence for the stop checks on harnesses whose transcript we cannot parse |
| `stop_check.py` | end of turn | **write check**: ≥5 tool calls and zero `store_fact`/`store_facts`/`store_session_summary` → one block. **read check**: reply says "only you can / I can't / I don't have access / needs your login" with zero memory reads → one block: "search your grants first" | the write habit is the whole product; the read check catches the moment an agent declares itself blocked by something the person already granted |
| `recall_on_error.sh` | a shell command fails | searches the store with command + error, injects top 3 pointers | the store often already knows the fix (forgotten token locations, known flaky steps) |
| `secret_guard.sh` | before `store_fact` / `store_facts` | denies if the text carries a token-shaped value (`emk_`, `sk-`, `ghp_`, `AKIA`, `xox`, `AIza`, private keys) | the store holds pointers, never secret values |
| `compaction_ledger.sh` | before compaction | appends to `~/.ctxstore/compaction-ledger.jsonl` and stores a `compaction:<session>:<epoch>` fact | a flattening should be an observed event, and the transcript path is the door back |

Tunables: `CTXSTORE_WORK_THRESHOLD` (default 5), `CTXSTORE_RECALL_MIN_CHARS`
(12), `CTXSTORE_PRIOR_ART_FLOOR` (0.60), `CTXSTORE_URL`, `CTXSTORE_STATE_DIR`, `CTXSTORE_LEDGER`.

## Per-client capability matrix

What each harness lets us enforce. "✓" = the hook runs as designed; "≈" = same
intent, weaker mechanism; "✗" = the harness has no seam, the snippet carries it.

| Ritual | Claude Code | Grok CLI (reads `~/.claude/settings.json`) | Codex ≥ 0.15x (hooks feature) | Gemini CLI | Cursor |
|---|---|---|---|---|---|
| Ritual at session start | ✓ `SessionStart` (+ `compact` matcher) | ≈ `SessionStart` context is dropped; `post_tool.py` injects it on the first tool call | ✓ `SessionStart` | ✓ `SessionStart` (`source: resume` treated as compaction) | ✓ `sessionStart` → `additional_context` |
| Recall on prompt | ✓ `UserPromptSubmit` | ≈ `UserPromptSubmit` context is discarded; pointers are saved and replayed by `post_tool.py` on the turn's first tool call | ✓ `UserPromptSubmit` | ✓ `BeforeAgent` → `additionalContext` | ✗ `beforeSubmitPrompt` can only allow/deny; the hook still resets the tally |
| Write check (block the turn) | ✓ `Stop` + transcript | ✓ `Stop` `decision: block` works (tally evidence) | ✓ `Stop` (transcript if Claude-shaped, else tally) | ✓ `AfterAgent` `decision: block` + tally | ≈ `stop` cannot block; emits one `followup_message` (`loop_limit: 1`) |
| Read check ("grants first") | ✓ | ✓ | ✓ | ✓ (`prompt_response` is the reply text) | ≈ same follow-up mechanism; reply text from `afterAgentResponse` |
| Recall on error | ✓ `PostToolUseFailure` (Bash) | ✓ `PostToolUseFailure` context is delivered (Bash is aliased to `run_terminal_command`) | ≈ no failure event documented; not wired | ≈ `AfterTool` on `run_shell_command`, error-shaped output only | ✗ `afterShellExecution` is observational; nowhere to inject |
| Secret guard | ✓ `PreToolUse` deny | ✓ deny works; matcher also covers Grok's `ctxstore__store_fact` spelling | ✓ `PreToolUse` deny | ✓ `BeforeTool` `decision: deny` | ✓ `beforeMCPExecution` `permission: deny` |
| Compaction ledger | ✓ `PreCompact` | ? not reported; harmless if unsupported | ✓ `PreCompact` | ✓ `PreCompress` | ✓ `preCompact` |
| Instructions file | `~/.claude/CLAUDE.md` | `~/.claude/CLAUDE.md` (shared) | `~/.codex/AGENTS.md` | `~/.gemini/GEMINI.md` | `.cursor/rules/ctxstore-memory.mdc` (per project) |

**Tolerant by design.** Harnesses differ in which events actually deliver
`additionalContext`, so the two things that matter most, the ritual and the
recall pointers, are delivered twice: once where the event is designed for it
(`SessionStart`, `UserPromptSubmit`) and once on the first tool call
(`post_tool.py`, which also keeps the tally). On Claude Code that costs one
repeated paragraph per session; on Grok CLI it is the only path that lands. Set
`CTXSTORE_REPLAY_RECALL=1` to replay pointers on every harness.

**Codex is capability-detected.** `install.sh` runs `codex features list`; when
the `hooks` feature is present it installs real lifecycle hooks (Claude-shaped
`~/.codex/hooks.json`, which Codex accepts) and Codex asks you to trust them on
first run (automation: `--dangerously-bypass-hook-trust`). Older CLIs get
`AGENTS.md` + a `notify` script that can only observe (it logs the turn and,
when the last message claims to be blocked, stores a nudge fact for the next
wake). `CODEX_FORCE_MODE=hooks|notify` overrides detection. Either way the
server-side cues remain the floor: `SessionStart` can fire before the MCP server
is ready, so the first tool result's memory block is what every Codex session
can count on.

Not covered by any kit, by design: claude.ai, Claude Desktop, ChatGPT, Grok and
Gemini web have no hook seam. Those get the ritual from the server (first-call
memory block, in-band nudges) plus the paste-able snippet at https://ctxstore.ai/docs.

## Uninstall

`./install.sh --client <c> --uninstall` removes our hook entries and the snippet block; `rm -rf ~/.ctxstore/kit` removes the scripts. State files live in `~/.ctxstore/turns/` and are safe to delete at any time.

## License

MIT, Copyright (c) 2026 PAAMT LLC. See [LICENSE](LICENSE).
