# Changelog

All notable changes to Proxima are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

- **Example plugin** (`.proxima/plugins/word-count/`) — fully annotated reference implementation; `run.sh` demonstrates the stdin/stdout/exit-code protocol with inline comments; `README.md` documents how to write, test, and register plugins; intended as a copy-paste starting point for community plugins

---

## [1.1.0] — 2026-03-28

### Added

#### Terminal UX — Rich Feedback & Activity Indicators
- `AgentCallbacks.onIterationStart(iteration, maxIterations)` — called at the start of each loop iteration; `Renderer` uses it to show `⠋ Thinking… [N/10]` spinner with iteration depth between tool calls
- `AgentCallbacks.onToolExecuting(toolCall)` — fires immediately before tool execution (after permission grant); `Renderer` shows `  ◆ Reading core/session.dart…` activity line
- Animated blink dots on in-progress tool lines — executing line pulses `…` → `….` → `…..` → `…...` every 400ms via `Timer.periodic` so users see the tool is alive, not stuck
- Context preserved in result lines — the activity label from `onToolExecuting` is held in `_pendingLabel` and reused in `onToolResult`; result now reads `  ✓ Reading core/session.dart…  (1423 lines)  0.3s` instead of `  ✓ read_file  (1423 lines)`
- Per-tool elapsed time — `_toolStartTime` captured at `onToolExecuting`, formatted as `ms` or `s` and appended dim to every result line
- Turn elapsed time in usage report — `_turnStartTime` set on iteration 1 via `onIterationStart`; appended to the `↑N ↓N  total: N` line: `  ↑1240 ↓387  total: 14832  4.2s  cost: $0.0042`
- `onThinking` now shows `⠋ Working…` spinner after printing the reasoning line, bridging the gap between reasoning and the first tool executing line
- Clarify styling — `onClarify` now renders `  ? question` with cyan `?` instead of raw bold text
- `_fmtElapsed(Duration)` helper — `<1000ms` → `NNNms`, `≥1000ms` → `N.Ns`
- Static `showSpinner('Thinking...')` calls removed from `repl.dart`; spinner is now driven entirely by `onIterationStart`
- **342 tests total** (up from 237 — 105 new tests across `find_references_test.dart`, `get_imports_test.dart`, `test/tools/plugin/shell_plugin_test.dart`)
- **`find_references` tool** (`lib/tools/search/find_references_tool.dart`, `safe`) — finds all usages of a symbol across the codebase using `\b<symbol>\b` word-boundary matching. Supports `path` scoping, `file_extensions` filter, `exclude_definition` flag (skips definition lines using the same heuristics as `search_symbol`), and `max_results` (default 100). Skips `.git`, `node_modules`, `build`, `.dart_tool`, `.pub-cache`, and generated files. Output: `file:line  content` lines followed by a `Found N references in M files.` summary.

- **`get_imports` tool** (`lib/tools/search/get_imports_tool.dart`, `safe`) — parses all import/require statements from a single file and categorises them by source type. Supports Dart (`[dart]`/`[package]`/`[local]`), JS/TS (`[node]`/`[local]`), Python (`[stdlib]`/`[local]`), and Go (`[stdlib]`/`[external]`). `resolve_paths: true` expands local imports to project-relative paths. Throws typed `ToolError(notFound)` when the file does not exist; `ToolError(parseError)` for binary files or unsupported extensions.

- **Plugin system** — shell/binary drop-in tools via `.proxima/plugins/<name>/`:
  - `ShellPluginTool` (`lib/tools/plugin/shell_plugin_tool.dart`) — wraps any executable as a `ProximaTool`; passes args as JSON on stdin, reads result from stdout, enforces configurable `timeout_seconds`; non-zero exit → `ToolError`
  - `PluginLoader` (`lib/tools/plugin/plugin_loader.dart`) — `load(dirs, workingDir)` discovers plugin directories, validates `plugin.json` (required fields: `name`, `description`, `executable`, `input_schema`), checks the executable exists and has the execute bit, parses `risk_level` string → `RiskLevel` (defaults to `confirm` for unrecognised values); logs startup warnings for invalid plugins and never throws
  - `ProximaConfig.pluginDirs` field — `List<String>`, default `['.proxima/plugins']`; parsed from `plugin_dirs` YAML key; included in `copyWith()`
  - `_buildToolRegistry()` in `repl.dart` is now `async`; loads plugins after all built-ins; silently skips any plugin whose name conflicts with a built-in tool (built-in wins)

#### Plan Mode
- `/plan <task>` slash command — runs the agent in `SessionMode.safe` with `isPlanMode: true`, produces `.proxima/plan.md`, then shows an arrow-key picker (Execute / Edit / Skip) before executing
- `/execute` slash command — executes the saved plan in `.proxima/plan.md` without re-running the research phase
- `/cost` slash command — shows current session cost and a cost table for the 10 most recent sessions
- **Shift+Tab REPL mode cycle** — Shift+Tab now cycles through three modes: normal → plan → accept-edits → normal; each press updates the prompt tag (`❯` / `❯ [plan]` / `❯ [edits]`) and shows a compact tip line *below* the prompt (`⏸ plan mode on` / `⏵⏵ accept edits on`); the previous verbose green print above the prompt is removed
- **Accept-edits mode** (`❯ [edits]`) — third cycle state; sets `_permissionGate.mode` to `SessionMode.auto` transiently so confirm-level tool calls (writes, commands) execute without the Approve/Deny picker; cycling back to normal restores the configured mode; `_session.mode` and the session file are unchanged (transient only)
- `_ReplMode` enum (`normal | plan | acceptEdits`) in `repl.dart` replaces the former `bool _planMode` field
- `_cycleReplMode()` replaces `_togglePlanMode()`; syncs permission gate and calls `_renderer.updateStatus(planMode:, acceptEditsMode:)` with no print
- `_modeTip()` helper returns the tip string for the active mode (null when normal)
- `ReadLine.readLine()` gains optional `String? statusTip` parameter; stored as `_statusTip` field and folded into `_renderPanel()` — when no suggestions are visible and a tip is set, one dim tip line is drawn below the prompt; suggestions take priority (tip suppressed while panel is open)
- `ReadLine.readLine()` gains `onShiftTab` callback; detects `ESC [ Z` (standard terminal Shift+Tab), fires the callback, and returns `ReadLine.shiftTabSentinel` — no history entry, no completion side-effects
- `ReadLine.shiftTabSentinel` public constant (`\x00__shift_tab__`) — lets the REPL identify the toggle without a magic string literal
- `ProximaSession.isPlanMode` runtime-only bool (not persisted) — set by `ProximaSession.create(..., isPlanMode: true)`
- `ProximaSession.cumulativeCost` field — tracks session-total USD cost; persisted to session JSON as `cumulative_cost`; incremented via `recordCost(double)`
- `ContextBuilder` injects a PLAN MODE system-prompt block when `session.isPlanMode` is true — instructs the agent to use only read tools, then call `write_plan` with a structured markdown plan (context, step-by-step changes, tests, risks)
- `WritePlanTool` (`lib/tools/agent/write_plan_tool.dart`) — `confirm`-risk tool that writes agent-produced plans to `.proxima/plan.md`; supports `dryRun()`

#### Model Persistence
- `/model <name>` now persists the selected model as `model:` in `~/.proxima/config.yaml` — future sessions start with the last chosen model
- `ProximaConfig.saveDefaultModel(model)` static helper — creates `~/.proxima/config.yaml` (and parent directory) if absent; replaces the `model:` line in-place, leaving all other keys untouched

#### Cost Tracking
- `CostCalculator.compute(model, usage)` — maps known Anthropic model IDs to per-token USD rates; returns `0.0` for unknown/local models
- `CostCalculator.format(cost)` — formats USD cost as `$0.0000` (4 decimal places)
- `AgentCallbacks.onUsageReport` extended with `turnCost` and `sessionCost` parameters; `Renderer` appends `cost: $N.NNNN` to the usage line when non-zero
- `AgentLoop` computes `turnCost` via `CostCalculator.compute` and passes it to `onUsageReport` alongside the session cumulative
- `/status` now shows `Cost` row when session cost is non-zero

#### Search
- `search_symbol` tool (`lib/tools/search/search_symbol_tool.dart`) — searches for symbol definitions (class, function, variable, any) using regex across the working directory; supports `path` scoping and `kind` filtering; rejects path traversal

#### Interactive UX — Consistent Arrow-Key Pickers & Status Line
- `PickerWidget` (`lib/renderer/picker_widget.dart`) — shared synchronous arrow-key single-choice picker; renders `▶ Option  hint` rows with inverse-video highlight; used everywhere a fixed choice list is presented; Escape/Ctrl-C returns `defaultIndex`
- **Permission prompt → picker** — `PermissionPrompt._confirmPrompt()` replaced with `PickerWidget.pick(options: ['Approve', 'Deny'], ...)` with dim hints; high-risk typed `CONFIRM` path unchanged
- **Stuck dialog → picker** — `TaskSummaryRenderer.renderStuck()` `a/c` single-keypress replaced with `PickerWidget.pick(options: ['Continue', 'Abort'], defaultIndex: 1)` (Abort is the safer default when stuck)
- **`/mode` no-arg → picker** — `/mode` with no argument opens an arrow-key picker pre-selected to the current mode (safe / confirm / auto with hints); previously showed a dim text line only
- **Plan approval picker simplified** — `_planApprovalPicker()` in `repl.dart` now delegates to `PickerWidget` instead of the hand-rolled `_renderPlanPicker`/`_clearPlanPicker` helpers (removed)
- **Persistent status line after each turn** — `Renderer.onUsageReport()` calls `_printStatusLine()` after the token line; shows `model: <name>` always, `mode: <name>` when non-default (non-confirm), `[plan]` when plan mode active, `[edits]` when accept-edits mode active
- `Renderer.updateStatus({model, mode, planMode, acceptEditsMode})` — push current state into the renderer; called from `initialize()`, `_switchModel()`, `_switchMode()`, and `_cycleReplMode()`
- **`ClarifyResponse` gains `options` field** — `List<String> options` (default empty); when non-empty the agent loop stays alive: `onClarifyWithOptions` shows a picker, the selected answer is injected as a user message, and the loop continues without exiting
- `AgentCallbacks.onClarifyWithOptions(question, options)` — new abstract method; `Renderer` implements it via `PickerWidget.pick(options: options)`; all mock callbacks in tests return `Future.value(0)`
- `SchemaValidator._validateClarify()` parses optional `options` array from the LLM response
- `ContextBuilder` adds operating rule 8 — instructs the LLM to use `"options"` array in `clarify` responses when presenting a fixed choice list

### Fixed
- **Plan mode agent offered numbered options menu instead of stopping** — system prompt now explicitly forbids presenting options or asking for approval after `write_plan`; instructs the agent to emit a brief confirmation and stop
- **`onFinalResponse` printed a spurious blank line during streaming** — when streaming was active, `text` is `''`; the renderer now skips `writeln('')` + `_renderMarkdown('')` when text is empty, avoiding a double blank line above the closing separator
- **`_dispatchPlan` silently discarded async results** — `_runPlan()` and `_handleExecutePlan()` are now wrapped with `unawaited()` making the fire-and-forget intent explicit
- **Redundant `Researching…` spinner in `_runPlan`** — removed manual `showSpinner`/`hideSpinner` calls; the renderer drives the spinner correctly via `onIterationStart`
- **Plan approval picker `Edit` hint was misleading** — said "save to .proxima/plan.md" (plan is already saved at that point); corrected to "edit .proxima/plan.md, then run /execute"
- **`write_plan` called twice by small local models** — the agent loop now exits immediately after the first successful `write_plan` in a plan-mode session (`session.planWritten = true`); the LLM no longer takes a second turn, eliminating the duplicate write and the "Would you like to: 1. Approve..." options noise that appeared before the picker
- **Status line printed before plan content** — `onUsageReport` was firing (and printing the status line) before `_maybeShowPlanPicker` displayed the plan text and picker; fixed by `suppressNextStatusLine()` before the plan agent turn and `printStatusLine()` explicitly after the picker
- **Shift+Tab verbose print removed** — the green `Plan mode ON/OFF` + dim description line printed *above* the prompt on every toggle is replaced by the compact tip line rendered *below* the prompt by `ReadLine`
- **Shift+Tab detection used exact byte match only** — added `endsWith('[Z')` guard to cover terminal emulators that deliver the sequence with a prefix variation

---

## [1.0.1] — 2026-03-26

### Added
- `SessionMode.safe` now enforced in `PermissionGate` — any tool above `safe` risk level is denied without prompt when the session is in safe mode (step 3a, audited as `safe_mode_blocked`)
- `ToolErrorCode` enum on `ToolError` (`notFound | permissionDenied | pathViolation | timeout | parseError | unknown`) — tools can now classify errors for actionable LLM feedback
- `_formatToolError()` helper in `AgentLoop` — tool errors now return structured context (`Tool: …\nError: …\nSuggestion: …`) instead of bare `'Error: $e'` strings
- `AgentCallbacks.onUsageReport(turnUsage, cumulative)` — called after every completed turn; `Renderer` displays `↑N ↓N  total: N` as a dim line after each response
- System prompt overhauled in `ContextBuilder._buildSystemPrompt()`: identity section, 7 ordered operating rules (read-before-write, patch-over-write, verify-after-write, diagnose-before-retry, no-identical-duplicate-calls, safe-mode-tool-list, test-fix-cycle limit), and session state (mode + cumulative token count)
- 3 new permission gate tests: safe mode blocks confirm tools, safe mode allows safe tools, deny list pre-empts risk classification
- `TestOutputParser` — parses raw test runner output into structured `TestResult`/`TestFailure` objects; supports Dart, Jest, Pytest, Cargo, Go; graceful fallback to raw string on unparseable output
- `run_tests` tool now embeds `FRAMEWORK:<name>` marker in output and returns a concise structured failure summary (test name, file, message) before the raw output; LLM gets actionable context instead of wall-of-text stdout
- 15 new parser tests covering all five frameworks and the framework marker extractor
- Critic subagent (`SubagentType.critic`) — pre-commit review agent that fires before the permission prompt on `write_file`/`patch_file` at `confirm` risk; returns `CriticResult` with `approve | warn | block_suggestion` verdict; advisory only, never a hard gate; silent on `approve`; displays amber/red note above y/n prompt for `warn`/`block_suggestion`
- `CriticResult`, `CriticVerdict`, `CriticIssue` types added to `subagent_runner.dart`
- `SubagentRunner.runCritic()` — never throws; graceful fallback to `approve` on LLM error or malformed JSON; strips markdown fences; capped at 1024 tokens
- `PermissionGate.criticCallback` — optional `CriticCallback?` wired in before step 6 (user prompt); only fires for confirm-level write tools, never in `auto` mode
- `PromptCallback` extended with `{CriticResult? criticResult}` named parameter
- `critic_on_write: true` config field in `.proxima/config.yaml` (default: true)
- `ProximaConfig.criticOnWrite` field with yaml key `critic_on_write`
- Critic wired in `repl.dart` using the active model and a fresh provider per invocation
- 7 new critic tests (approve/warn/block_suggestion/malformed JSON/LLM error/system prompt/markdown fence)
- `ProximaSession.fileCache` — `Map<String, String>` keyed by canonical path; populated by the agent loop after every successful `read_file` call
- `Compaction.deduplicateFileReads()` — new Pass 0 that replaces all but the most recent `read_file` tool result for any given path with `[File already in context]`; integrated into `Compaction.compact()` via optional `fileCache` param; estimated 15–30% token savings in file-heavy sessions
- `ContextBuilder` passes `session.fileCache` to `Compaction.compact()`
- 11 new compaction tests covering deduplication, pruning, and truncation
- `FallbackProvider` (`lib/providers/fallback_provider.dart`) — wraps a primary `LLMProvider` with a secondary; transparently retries on non-auth `LLMError`; auth errors rethrown immediately; `listModels()` also falls back; no changes to `AgentLoop`
- `ProviderRegistry.create()` accepts optional `fallbackModel` string; wraps primary in `FallbackProvider` when set; best-effort (ignores fallback config errors)
- `ProximaConfig.fallbackModel` field with yaml key `fallback_model` (default: null)
- Fallback model wired in `repl.dart` `_getAgentLoop()`
- 5 new fallback provider tests

### Fixed
- **`FallbackProvider.stream()` never reached secondary** — on primary stream failure the old implementation yielded a done chunk with `hasToolUse: false`, which the agent loop treated as a successful empty response; secondary was never tried. Fixed by rethrowing the non-auth `LLMError` so `_streamResponse`'s catch block falls back to `complete()`, which correctly retries on the secondary
- **Token usage display appeared before response separator** — `onUsageReport` was called before `onFinalResponse`/`onClarify`, so the dim token line printed above the separator instead of below it. Swapped order: text → separator → usage
- **`Compaction.deduplicateFileReads()` missing role guard** — assumed `messages[i-1]` was always an assistant message; added explicit `if (assistantMsg.role != MessageRole.assistant) continue` guard for malformed history
- **Critic `diffOrContent` fallback was too verbose** — `toolCall.args.toString()` sent the full serialized args map to the critic LLM when neither `content` nor `patch` was present; replaced with `''` to avoid wasting tokens on irrelevant data
- 4 additional tests (streaming fallback, auth rethrow, fallback path, orphaned tool message)
- 237 tests total

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

[Unreleased]: https://github.com/jizzel/proxima/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/jizzel/proxima/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/jizzel/proxima/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/jizzel/proxima/compare/v0.1.4...v1.0.0
[0.1.4]: https://github.com/jizzel/proxima/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/jizzel/proxima/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/jizzel/proxima/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/jizzel/proxima/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jizzel/proxima/releases/tag/v0.1.0
