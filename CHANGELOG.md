# Changelog

All notable changes to Proxima are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

---

## [1.0.0] — 2026-03-20

### Added
- `delegate_to_subagent` tool (safe) — delegates to `code_analyzer`, `refactor`, or `test` specialist subagent; max 2 delegations per turn; subagents are tool-free and cannot nest
- `SubagentRunner` — single-shot LLM call with specialist system prompt; never throws; subagent token usage folded into session cumulative total
- `maxSubagentDelegations` config field (default: 2; override via `max_subagent_delegations` in config YAML)
- `delete_file` tool (high_risk) — permanently deletes a file with automatic `.proxima_bak` backup; compatible with `/undo`; refuses directory deletion
- `/tools` slash command — lists all registered tools with risk levels and descriptions
- `/debug [on|off]` slash command — shows or toggles debug output (reasoning + token counts)
- `/deny <tool>` slash command — blocks a tool for the current session; enforced in `PermissionGate` before risk-level checks
- `/permissions` slash command — shows allowed tools, denied tools, and ignored patterns for the current session
- `/dir <path>` slash command — switches working directory and resets the session
- `/ignore <pattern>` slash command — excludes a glob pattern from context
- `/snapshot` slash command — saves a session snapshot with resume instructions
- `SessionPermissions` extended with `deniedTools: Set<String>` and `ignoredPatterns: List<String>`, persisted in session JSON
- Tab completion extended to all 7 new slash commands
- Six git tools: `git_status` (safe), `git_diff` (safe), `git_log` (safe), `git_add` (confirm), `git_commit` (confirm), `git_reset` (high_risk)
- `git push --force` / `git push -f` blocked outright in `blocked_patterns.dart` (belt-and-suspenders)
- `/model` now opens an interactive picker with arrow-key navigation, Enter to select, Escape to cancel; active model is highlighted
- `/mode [safe|confirm|auto]` slash command to view or switch permission mode at runtime
- `/files` slash command to list files read or written during the current session
- `/context` slash command to display token budget breakdown for the active model
- Streaming LLM responses — tokens now appear live in the terminal as the model generates them (Anthropic and Ollama); falls back to non-streaming for unsupported providers
- Tab completion extended to `/mode`, `/files`, `/context`
- 192 tests total covering slash commands, streaming, ReAct fallback, subagent runner, and agent loop integration

### Fixed

- **Tool calls silently dropped for Ollama/ReAct models** — `ReActFallback.stream()` was a passthrough that forwarded raw `<tool_call>` JSON as plain text; `_streamResponse` assembled it into a `FinalResponse` and the agent loop treated the turn as complete without ever executing the tool or showing a permission prompt. Fixed by buffering the full streamed response, detecting tool-call blocks at the end, and signalling `hasToolUse: true` so `_streamResponse` falls back to `complete()` for correct extraction.
- **Tool calls silently dropped for Anthropic streaming** — `stream()` ignored `content_block_start {type: tool_use}` SSE events; when the model chose a tool, the stream ended with an empty text buffer, yielding `FinalResponse('')`. Fixed by detecting `tool_use` content blocks in the stream and signalling `hasToolUse: true` on the done chunk, causing the same `complete()` fallback.
- **Permission prompt silently denied all tool calls** — `PermissionPrompt` used `stdin.readLineSync()` while the terminal was in raw mode (set by `dart_console`'s `Console`); Enter sent `\r` instead of terminating a line, so every prompt returned empty string which defaulted to deny. Fixed by switching `_confirmPrompt` to `console.readKey()` (single-keypress, raw-mode compatible).
- **`SubagentResult` did not flag `ErrorResponse`/`ToolCallResponse` as errors** — both were silently treated as successful results, passing error messages or raw tool-call JSON to the main agent as valid output. `ErrorResponse` now returns `isError: true` with the provider error; `ToolCallResponse` returns `isError: true` with a "hallucinated tool call" message.
- **`/allow` had no effect** — `PermissionGate.evaluate()` only checked the constructor-injected allowlist, never `session.permissions.allowedTools` populated by `/allow`. Fixed by adding an `allowedTools` parameter to `evaluate()` and passing the session allowlist from the agent loop.
- **`/mode` change not persisted on session save/resume** — `_switchMode()` updated `_config` and `_permissionGate.mode` but not `_session.mode`. Fixed.
- **`/status` missing working directory** — added `Dir` row to `_printStatus()`.
- **`/context` showed wrong context window** — defaulted to 128k regardless of active model; now resolved at `initialize()` and `_switchModel()` time via `_contextWindowForModel()`.
- **`/model` tab panel showed only Anthropic models** while Enter opened a full picker including Ollama; fixed by gating the live Ollama fetch behind `stdout.hasTerminal` so non-TTY callers skip the network call.
- **`/dir` path comparison failed on Windows CI** — test used `Directory.absolute.path` (preserves OS casing) while implementation uses `p.canonicalize()` (lowercases on Windows); fixed by using `p.canonicalize()` on both sides.
- **Streaming spinner corrupted output** — `Spinner`'s `Timer.periodic` kept firing during token streaming, overwriting each output line with `\r⠇ Thinking...`; fixed by stopping the spinner on the first `onChunk` call.
- Session permission mode now correctly restored when resuming a session with `--resume`
- `/clear` no longer resets the session; it only clears the terminal display and reprints the header
- `/history` help text corrected from "last N exchanges" to "last N messages"
- `/history` preview now taken from first line only, preventing multiline messages from breaking the display

---

## [0.1.4] — 2026-03-18

### Fixed

- `--version` now reports the correct version (was hardcoded to `0.1.0` in `arg_parser.dart`)
- inject version at compile time and update related docs

---

## [0.1.3] — 2026-03-18

### Changed

- update release workflow to organize binaries under a `dist/` directory

---

## [0.1.2] — 2026-03-18

### Changed

- Drop separate macOS Intel binary; ARM64 binary runs natively on Apple Silicon and via Rosetta 2 on Intel
- `install.sh`: macOS Intel now downloads `proxima-macos-arm64` instead of the removed `proxima-macos-x64`
- CI release workflow: remove `macos-x64` build job — no Intel runner required

---

## [0.1.1] — 2026-03-18

### Added

- README: architecture diagram image and roadmap section (V1.2/V1.3 planned features)

### Fixed

- CI release workflow: replace deprecated `macos-13` runner with `macos-12` for Intel macOS build

---

## [0.1.0] — 2026-03-18

### Added
- Interactive REPL with fixed-bottom suggestion panel and arrow-key navigation
- Persistent input history across sessions (`~/.proxima/input_history`)
- Anthropic Claude provider with SSE streaming and native tool use
- Ollama provider with ReAct fallback for models without native tool use
- `/model` slash command to list and switch models mid-session with tab completion
- Full tool suite: `read_file`, `write_file`, `patch_file`, `list_files`, `glob`, `search`, `run_command`, `run_tests`
- `patch_file` supports `replace_all` flag
- Permission gate with four risk levels: `safe`, `confirm`, `high_risk`, `blocked`
- Audit log at `~/.proxima/audit.jsonl` (append-only, every permission decision)
- Session persistence to `~/.proxima/sessions/<id>.json`; `--resume <id>` flag
- `/undo` command restores last file changed via `write_file` or `patch_file`
- Context manager with token budget, project index, and 3-pass compaction
- Stuck detection (3 identical consecutive tool calls → escalate)
- `--dry-run` mode previews actions without executing
- `--debug` mode shows reasoning and full tool output
- User config at `~/.proxima/config.yaml`; project override at `.proxima/config.yaml`
- 71 unit tests covering all layers
- Windows binary (`proxima-windows-x64.exe`) with PowerShell install script (`install.ps1`)
- CI runs on ubuntu, macOS, and Windows for every push and PR
- Install script (`install.sh`) with unified curl/wget fetch function
- LICENSE, CONTRIBUTING.md, and CHANGELOG

[Unreleased]: https://github.com/jizzel/proxima/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jizzel/proxima/compare/v0.1.4...v1.0.0
[0.1.4]: https://github.com/jizzel/proxima/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/jizzel/proxima/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/jizzel/proxima/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/jizzel/proxima/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jizzel/proxima/releases/tag/v0.1.0
