---

# PROXIMA – PRODUCT REQUIREMENTS SPECIFICATION v1

**Status:** Implementation-ready
**Language:** Dart (CLI-native, single binary)
**Target:** Claude Code-class coding agent, terminal-native, model-agnostic

---

## 1. Product Definition

**Proxima is a terminal-native, model-agnostic coding agent built in Dart that understands, navigates, and modifies codebases through structured tool execution, with an explicit permission gate at every destructive boundary and zero required cloud dependency.**

### Design Principles (priority-ordered — conflicts resolve downward)

| Priority | Principle | What it means in practice |
|---|---|---|
| 1 | Safety over speed | No file is ever modified without an auditable approval |
| 2 | Predictability over intelligence | Deterministic loops, strict schemas, no magic |
| 3 | Local-first, cloud-optional | Must work fully offline with a local model |
| 4 | Composability over completeness | Small sharp tools, pluggable by design |
| 5 | Transparency at every step | Show reasoning, diffs, costs, and token usage |

---

## 2. Architecture Overview

Proxima is structured as **nine explicit layers**, each with a single responsibility and a defined interface to its neighbors. Layers do not skip — the agent loop never touches the filesystem directly; it always goes through the permission gate and then the tool system.

```
┌─────────────────────────────────────────────────────┐
│  1. CLI Entry            dart:io, args, config       │
├─────────────────────────────────────────────────────┤
│  2. Session Manager      history, state, undo        │
├─────────────────────────────────────────────────────┤
│  3. Agent Loop           think → act → observe       │
├─────────────────────────────────────────────────────┤
│  4. Provider Interface   unified LLM abstraction     │
│     ├── Cloud adapters   Anthropic, OpenAI, Gemini   │
│     └── Local adapters   Ollama, LM Studio           │
├─────────────────────────────────────────────────────┤
│  5. Permission Gate      safe/confirm/high-risk      │  ← GAP CLOSED
├─────────────────────────────────────────────────────┤
│  6. Tool System          file, shell, search, git    │
├─────────────────────────────────────────────────────┤
│  7. Context Manager      token budget, compaction    │
├─────────────────────────────────────────────────────┤
│  8. Error Handler        retry, recovery, escalation │  ← GAP CLOSED
├─────────────────────────────────────────────────────┤
│  9. Renderer             ansi, diffs, prompts        │
└─────────────────────────────────────────────────────┘
```

---

## 3. Layer 1 — CLI Entry

### 3.1 Invocation

```bash
proxima                                    # interactive REPL
proxima "fix the login bug"               # single task, then exit
proxima --dir /path/to/project            # explicit project root
proxima --model ollama/qwen2.5-coder:32b  # explicit model
proxima --debug                           # verbose tool call logging
proxima --dry-run                         # no writes, no commands
proxima --mode safe                       # read-only session
proxima --resume last                     # resume last session
proxima --resume sess_20250317_102201     # resume specific session
proxima config set anthropic.api_key KEY  # configure key
proxima config show                       # print active config
```

### 3.1.1 Version Injection

`proximaVersion` is injected at compile time via `--define=APP_VERSION=<version>`. When run via `dart run` without the define flag, the version defaults to `'dev'`.

```bash
dart compile exe bin/proxima.dart -o proxima --define=APP_VERSION=0.1.4
```

The constant is declared in `lib/cli/arg_parser.dart`:

```dart
const String proximaVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);
```

### 3.2 REPL Prompt

```
┌─ proxima ──────────────────────────────────────────────────────┐
│  model: claude-sonnet-4  │  dir: ~/myapp  │  tokens: 4,201     │
└────────────────────────────────────────────────────────────────┘
>
```

The prompt tag reflects the current REPL mode:

```
 ❯            ← normal
 ❯ [plan]     ← plan mode
 ❯ [edits]    ← accept-edits mode
```

### 3.2.1 Keyboard Shortcuts

| Key | Action |
|---|---|
| `↑` / `↓` | Scroll history / navigate suggestion panel |
| `Tab` | Accept top suggestion |
| `Shift+Tab` | Cycle REPL mode: normal → plan → accept-edits → normal |
| `Enter` | Submit input or accept highlighted suggestion |
| `Escape` | Dismiss suggestion panel |
| `Ctrl+C` | Cancel input |
| `Ctrl+A` / `Ctrl+E` | Jump to line start / end |
| `Ctrl+U` / `Ctrl+K` | Delete to line start / end |
| `Ctrl+B` / `Ctrl+F` | Move cursor left / right |
| `Alt+←` / `Alt+→` | Word-left / word-right |

### 3.2.2 REPL Mode Cycle (Shift+Tab)

Pressing `Shift+Tab` cycles through three REPL modes. A compact tip line is shown below the prompt immediately; no verbose print above the prompt.

| Mode | Prompt tag | Tip line | Behaviour |
|---|---|---|---|
| **normal** | `❯` | *(none)* | Standard agent loop, permission gate uses configured mode |
| **plan** | `❯ [plan]` | `⏸ plan mode on  (shift+tab to cycle)` | Every input routed through `_runPlan()` — research in safe mode → `.proxima/plan.md` → approval picker |
| **accept-edits** | `❯ [edits]` | `⏵⏵ accept edits on  (shift+tab to cycle)` | Permission gate temporarily set to `SessionMode.auto`; confirm-level tools (writes, commands) execute without the Approve/Deny picker |

**Cycle order:** normal → plan → accept-edits → normal (repeating).

**Accept-edits details:**
- Only affects the permission gate (`_permissionGate.mode`); the session's own `_session.mode` is unchanged and not persisted — accept-edits is a transient convenience toggle
- High-risk tools (`delete_file`, `git_reset`) still require typed `CONFIRM` — accept-edits only bypasses the confirm-level picker
- Cycling back to normal restores `_config.mode` (the configured default)

**Slash commands** are always handled before the mode check and work in all modes.

### 3.3 Built-in Slash Commands

```bash
# Navigation
/help                         # list all commands with description
/exit                         # quit cleanly, save session
/clear                        # clear terminal display only; session history is preserved

# Model
/model list                   # all models, connection status
/model use <name>             # switch model mid-session
/model info                   # active model details + cost estimate

# Session
/history                      # full conversation
/history --last 5             # last N exchanges
/files                        # all files touched this session
/undo                         # undo last task (restore backups)
/undo <task_id>               # undo specific task
/snapshot                     # save named checkpoint
/context                      # show token budget breakdown

# Permissions
/mode safe                    # read-only
/mode confirm                 # require approval for writes (default)
/mode auto                    # auto-approve low-risk (explicit opt-in)
/allow write lib/auth/**      # session-scope allow
/allow run flutter test       # allow specific command
/deny run                     # block all shell execution
/permissions                  # show current permission state

# Debug
/debug on                     # enable tool call logs
/debug off
/debug timeline               # show execution timeline of last task
/tools                        # list available tools and risk levels

# Workspace
/dir /new/path                # change working directory
/ignore add *.env             # add to ignore list
```

---

## 4. Layer 2 — Session Manager (Gap #1 partially closed)

The session manager is the **single source of truth** for all state. The agent loop is stateless — it reads from the session manager before each turn and writes back after. This makes the loop testable in isolation and makes session persistence free.

### 4.1 Session State Schema

```dart
class ProximaSession {
  final String sessionId;           // sess_20250317_102201
  final DateTime startedAt;
  String workingDir;
  String activeModel;
  SessionMode mode;                 // safe | confirm | auto

  List<Message> conversation;       // full structured history
  List<ToolCallRecord> toolLog;     // every tool call ever made
  List<String> modifiedFiles;       // files changed this session
  List<TaskRecord> tasks;           // top-level tasks with undo info
  SessionPermissions permissions;   // current allow/deny state
  TokenUsage tokenUsage;            // input, output, cost
}

class TaskRecord {
  final String taskId;              // t_20250317_102201
  final String description;
  TaskStatus status;                // running | completed | failed
  List<String> modifiedFiles;
  Map<String, String> backups;      // path -> backup_path
  DateTime completedAt;
}
```

### 4.2 Persistence

Sessions auto-save to `~/.proxima/sessions/<session_id>.json` after every turn. Resumption restores full state including conversation history, modified files, and undo stack.

```
~/.proxima/
  config.yaml            # user-global config
  sessions/              # saved sessions
  audit.jsonl            # append-only audit log
  plugins/               # user-installed tools
```

---

## 5. Layer 3 — Agent Loop

The agent loop is **stateless by design**. It receives a `ProximaSession` and a user input, executes one full think→act→observe cycle, and returns the updated session.

### 5.1 Loop Pseudocode

```dart
Future<ProximaSession> runTurn(ProximaSession session, String userInput) async {
  session.addUserMessage(userInput);

  int iterations = 0;
  final int maxIterations = config.agent.maxIterations; // default: 10

  while (iterations < maxIterations) {
    iterations++;

    // 1. Build context for this LLM call
    final context = contextManager.build(session);

    // 2. Call LLM
    final response = await provider.complete(context);

    // 3. Validate schema
    if (!schemaValidator.isValid(response)) {
      session.addError('invalid_schema', response);
      // re-prompt with schema reminder, max 2x
      if (session.schemaRetries < 2) { session.schemaRetries++; continue; }
      else break;
    }

    // 4. Route response
    switch (response.type) {
      case 'final':
        session.addAssistantMessage(response.message);
        session.completeTask();
        return session;

      case 'clarify':
        final answer = await renderer.promptUser(response.question, response.options);
        session.addClarification(response.question, answer);
        continue;

      case 'tool_call':
        // 5. Stuck detection
        if (isStuck(session.toolLog)) {
          final action = await renderer.showStuckDialog(session.toolLog);
          if (action == StuckAction.abort) break;
          if (action == StuckAction.switchModel) {
            await switchModel(session);
            continue;
          }
        }

        // 6. Run through permission gate
        final permitted = await permissionGate.evaluate(response.toolCall, session);
        if (!permitted) {
          session.addToolResult(response.toolCall.callId, ToolResult.rejected());
          continue;
        }

        // 7. Execute tool
        final result = await toolSystem.execute(response.toolCall, session);
        session.addToolResult(response.toolCall.callId, result);
        session.toolLog.add(ToolCallRecord(response.toolCall, result));
        continue;
    }
  }

  // Max iterations hit
  session.failTask('max_iterations_exceeded');
  await renderer.showTaskFailure(session.currentTask);
  return session;
}
```

### 5.2 Loop Constraints

| Constraint | Default | Configurable |
|---|---|---|
| Max iterations per request | 25 | Yes |

Exhausting the budget returns `TaskStatus.budgetExhausted`, not `failed`, and is
reported through `AgentCallbacks.onNotice` rather than `onError` — the turn may
have done real work and simply run out of steps, and callers need to tell that
apart from an actual error.
| Max retries on tool error | 3 | Yes |
| Max retries on LLM error | 2 | Yes |
| Max retries on schema violation | 2 | No |
| Tool execution timeout | 30s | Yes |
| Stuck detection window | 3 identical calls | Yes |
| Spinning detection window | 6 consecutive read-only calls | Yes |

### 5.3a Plan Mode Early Exit

When `session.isPlanMode` is true, the loop exits immediately after the first successful `write_plan` tool call — before the LLM takes another turn. This prevents small local models from emitting a second response (options lists, questions) that would appear before the plan picker.

The exit fires `onUsageReport` with the current iteration's usage, sets `session.planWritten = true` and `session.status = TaskStatus.completed`, then returns. The REPL's `_runPlan()` then calls `_maybeShowPlanPicker()` to display the plan and the Execute/Edit/Skip picker.

### 5.3 Stuck Detection

Two complementary mechanisms detect when the agent is making no progress:

#### Identical-call detection (`isStuck`)

Fires when the last **3** tool calls have the same tool name and identical args (args sorted for canonical comparison).

```dart
bool isStuck(List<ToolCall> log, {int window = 3}) {
  if (log.length < window) return false;
  final recent = log.sublist(log.length - window);
  final first = '${recent.first.tool}:${jsonEncode(sortedArgs(recent.first))}';
  return recent.every((c) =>
    '${c.tool}:${jsonEncode(sortedArgs(c))}' == first
  );
}
```

#### Spinning detection (`isSpinning`)

Fires when the last **6** tool calls are all read-only tools — the agent is observing without acting. This catches local models that loop through `read_file` → `list_files` → `glob` → … without ever writing.

Read-only tool set: `read_file`, `list_files`, `glob`, `search`, `search_symbol`, `find_references`, `get_imports`, `git_status`, `git_diff`, `git_log`.

```dart
static const spinWindow = 6;

bool isSpinning(List<ToolCall> log, {int window = spinWindow}) {
  if (log.length < window) return false;
  return log.sublist(log.length - window)
    .every((c) => _readOnlyTools.contains(c.tool));
}
```

#### Dialog

Both mechanisms call `onStuck(recentCalls, reason: 'stuck' | 'spinning')`. The renderer shows an arrow-key picker with a reason-specific message:

```
⚠  Agent appears stuck                         (reason: stuck)
   Repeated tool calls detected:
   → read_file({path: lib/auth/auth.dart})  ×3

⚠  Agent is reading without making progress    (reason: spinning)
   Last 6 calls were all read-only — the agent may be unsure how to proceed:
   → read_file · list_files · glob · search · find_references · get_imports

  ↑/↓ select · Enter confirm
    Continue   let the agent try again
  ▶ Abort       stop and return to prompt      (Abort is the safe default)
```

Selecting Abort sets `session.status = TaskStatus.failed` and exits. Selecting Continue clears the tool log and resumes the loop.

---

## 6. Layer 4 — Provider Interface (Gap #2 closed)

This is the **most important architectural decision** for model-agnosticism. Every provider — cloud or local — implements the same Dart abstract class. The agent loop never knows which provider is active.

### 6.1 Abstract Provider

```dart
abstract class LLMProvider {
  String get name;
  ProviderCapabilities get capabilities;

  /// Single-turn completion with optional tool use
  Future<LLMResponse> complete(CompletionRequest request);

  /// Streaming completion — yields chunks as they arrive
  Stream<LLMChunk> stream(CompletionRequest request);

  /// Check if provider is reachable
  Future<bool> ping();
}

class ProviderCapabilities {
  final bool toolCalling;         // native JSON tool calling
  final bool streaming;
  final bool vision;
  final int contextWindow;
  final double costPer1mInputTokens;   // 0.0 for local
  final double costPer1mOutputTokens;
  final bool supportsSystemPrompt;
  final bool requiresReActFallback;   // for models without tool calling
}
```

### 6.2 Supported Providers

#### Cloud

| Provider Class | Models | Notes |
|---|---|---|
| `AnthropicProvider` ✅ | claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5 | Native tool calling |
| `OpenAIProvider` ✅ | discovered live via `GET /v1/models` | Native tool calling. Injectable `baseUrl` also serves Groq / Together / OpenRouter / LM Studio (not Azure — different auth and path shape) |
| `GeminiProvider` | gemini-2.5-pro, gemini-2.0-flash | Tool calling |
| `GroqProvider` | llama-3.3-70b, mixtral-8x7b | Fast inference, check tool support |
| `MistralProvider` | mistral-large, codestral | Code-optimized |

#### Local

| Provider Class | Backend | Notes |
|---|---|---|
| `OllamaProvider` | Ollama server | OpenAI-compatible API, localhost:11434 |
| `LMStudioProvider` | LM Studio | OpenAI-compatible API, localhost:1234 |
| `LlamaCppProvider` | llama.cpp server | Raw HTTP, user provides URL |

#### Recommended Local Models

| Model | Context | Tool Calling | ReAct Required | Best For |
|---|---|---|---|---|
| `qwen2.5-coder:32b` | 32K | Yes | No | Best local code model overall |
| `deepseek-coder-v2:16b` | 16K | Yes | No | Code reasoning, faster than 32B |
| `codellama:34b` | 16K | Partial | No | Code generation |
| `llama3.1:8b` | 8K | Via ReAct | **Yes** | Fast, lightweight tasks |
| `phi4:14b` | 16K | Via ReAct | **Yes** | Efficient reasoning |

#### Model discovery

Model ids are **not** hardcoded in the CLI. The `/model` picker and tab
completion both build their list from `LLMProvider.listModels()`:

| Provider | Source |
|---|---|
| `AnthropicProvider` | static list in `listModels()` (no discovery endpoint) |
| `OpenAIProvider` | live `GET $baseUrl/models`, minus non-chat modalities |
| `OllamaProvider` | live `GET $baseUrl/api/tags` |

Model filtering is an **exclusion** list, not an allow-list: `openai_base_url`
may target Groq, Together, OpenRouter, or LM Studio, whose ids look nothing like
OpenAI's (`llama-3.3-70b`, `meta-llama/…`, `anthropic/…`). Everything is kept
except ids naming a non-chat modality (embeddings, audio, image, rerank).

Context windows are derived per model (`OpenAIProvider.contextWindowFor`) rather
than advertised as a flat figure: `ContextBuilder` derives the entire token
budget from `capabilities.contextWindow`, so over-reporting it against a smaller
model breaks the session as history grows. Unknown ids — likely from a
compatible endpoint — get a conservative 8K, overridable with
`openai_context_window`.

**Per-model parameter support is discovered, not predicted.** Which parameters a
model accepts does not follow family boundaries — verified against the live API,
`gpt-5` rejects an explicit `temperature` while `gpt-5.1` and `gpt-5.2` accept
it. Rather than maintain a prefix rule (which was wrong three times), the
provider sends the request and inspects a 400:

| API says | Provider does |
|---|---|
| `Unsupported value/parameter: 'x'` | drops `x`, retries once |
| `Function tools with reasoning_effort are not supported … set reasoning_effort to 'none'` | sets `reasoning_effort: none`, retries once |

The error message names the remedy; applying it keeps working as new models
ship. Codex models are excluded from discovery entirely — they are either
deprecated or served only by `/v1/responses`, never `/v1/chat/completions`.

New model releases therefore appear without a code change for OpenAI and Ollama;
Anthropic needs only its single `listModels()` list updated. Live fetches happen
in the background at REPL start and are re-tried in the picker only when stdout
is a TTY; every call is wrapped so an unreachable endpoint returns `[]` rather
than blocking or throwing. The picker still works fully offline.

### 6.3 ReAct Fallback

> **Reliability note:** ReAct is explicitly lower-reliability than native tool calling. Output parsing will occasionally fail due to model verbosity, partial JSON, or tag omission. This is expected behavior. The spec below defines how failures are handled, not avoided.

For models without native tool calling (e.g. `llama3.1:8b`), Proxima uses a prompt-based ReAct loop that instructs the model to output tool calls as structured JSON in its text response, which Proxima parses with a strict extractor:

```
You are Proxima, a coding agent. When you need to use a tool, output ONLY this JSON block:
<tool_call>
{"tool": "read_file", "args": {"path": "auth.dart"}, "reasoning": "..."}
</tool_call>

When you have a final answer, output ONLY:
<final>
{"message": "...", "changes": [...]}
</final>
```

#### ReActExtractor behavior

```dart
// ReActExtractor: parse tool calls from raw LLM text
// 1. Scan response for <tool_call>...</tool_call> block
// 2. Extract inner text, attempt JSON.decode()
// 3. Validate required fields: tool (string), args (object), reasoning (string)
// On parse failure:
//   - Re-prompt once with: "Your last response could not be parsed. Output ONLY a valid <tool_call> block."
//   - If second attempt also fails: surface ParseError to agent loop
//     → agent loop treats this as LLMError.schemaViolation (max 2 retries total, shared counter)
// On missing reasoning field: inject empty string, log warning — do not re-prompt
```

### 6.4 Provider Configuration

```yaml
# ~/.proxima/config.yaml

model:
  default: anthropic/claude-sonnet-4
  fallback: ollama/qwen2.5-coder:32b
  auto_fallback_on_failure: true      # switch to fallback if cloud errors

providers:
  anthropic:
    api_key: $ANTHROPIC_API_KEY
    timeout: 60
  openai:
    api_key: $OPENAI_API_KEY
    timeout: 60
  google:
    api_key: $GOOGLE_API_KEY
  groq:
    api_key: $GROQ_API_KEY
  ollama:
    base_url: http://localhost:11434
    timeout: 120
  lm_studio:
    base_url: http://localhost:1234/v1
    model: ~                          # user sets model name
  llama_cpp:
    base_url: http://localhost:8080
    model: ~

# Per-task model overrides (optional)
task_models:
  analysis: ollama/qwen2.5-coder:32b  # use local for privacy-sensitive work
  generation: anthropic/claude-sonnet-4
  tests: openai/gpt-4o
```

### 6.5 Runtime Model Switching

```
> /model list

  ┌─ available models ─────────────────────────────────────────────┐
  │  [cloud]  anthropic/claude-opus-4         ● connected          │
  │  [cloud]  anthropic/claude-sonnet-4       ● connected  ← active│
  │  [cloud]  openai/gpt-4o                   ○ no key set         │
  │  [cloud]  google/gemini-2.5-pro           ○ no key set         │
  │  [local]  ollama/qwen2.5-coder:32b        ● running            │
  │  [local]  ollama/llama3.1:8b              ○ not pulled         │
  └────────────────────────────────────────────────────────────────┘

> /model use ollama/qwen2.5-coder:32b
  ✓ Switched to qwen2.5-coder:32b (local, no cost)
  Context: 32,768 tokens  │  Tool calling: native  │  Cost: $0.00

> /model use anthropic/claude-opus-4
  ⚠  claude-opus-4 is ~8× more expensive than your current model.
     Estimated cost this session so far: $0.04 → $0.32 equivalent.
     Switch anyway? (y/n)
```

---

## 7. Layer 5 — Permission Gate (Gap #2 closed — critical)

The permission gate is a **dedicated layer** between the agent loop and every tool execution. The agent loop calls `permissionGate.evaluate()` before every tool call. Tools never execute without passing through it.

This is not a feature. It is load-bearing structure.

### 7.1 Risk Classification

```dart
enum RiskLevel {
  safe,       // auto-execute, no prompt
  confirm,    // show intent + diff, require y/n
  highRisk,   // show impact, require typed "CONFIRM"
  blocked,    // hard reject, never execute, always log
}
```

| Risk Level | Actions |
|---|---|
| `safe` | `read_file`, `list_files`, `search`, `git status/diff/log` |
| `confirm` | `write_file`, `run_command`, `run_tests`, `git add/commit` |
| `high_risk` | Delete file, recursive write, `git reset --hard`, any `rm` |
| `blocked` | Path traversal, `sudo`, `curl \| sh`, write outside working dir, `rm -rf /` |

### 7.2 Evaluation Flow

```dart
Future<bool> evaluate(ToolCall call, ProximaSession session) async {
  final risk = classifyRisk(call);

  // Blocked — hard reject, no override possible
  if (risk == RiskLevel.blocked) {
    auditLog.write(call, 'blocked');
    renderer.showBlocked(call);
    return false;
  }

  // Check session allowlist first
  if (session.permissions.isAllowed(call)) {
    auditLog.write(call, 'session_allowed');
    return true;
  }

  // Check global mode — safe mode blocks everything above safe risk level
  // (enforced in PermissionGate.evaluate() step 3a; no prompt shown)
  if (session.mode == SessionMode.safe && risk != RiskLevel.safe) {
    auditLog.write(call, 'safe_mode_blocked');
    renderer.showDenied(call, 'session is in safe (read-only) mode');
    return false;
  }

  if (session.mode == SessionMode.auto && risk == RiskLevel.confirm) {
    auditLog.write(call, 'auto_approved');
    return true;
  }

  // Prompt user
  return switch (risk) {
    RiskLevel.safe => true,
    RiskLevel.confirm => await renderer.confirmPrompt(call),
    RiskLevel.highRisk => await renderer.typedConfirmPrompt(call),
    _ => false,
  };
}
```

### 7.3 Confirm Prompt (for `confirm` risk level)

```
──────────────── PERMISSION REQUEST ──────────────────────

  Proxima wants to modify:  lib/auth/auth.dart
  Risk: LOW  │  Reversible: YES  │  Backup: will be created

  ── diff ──────────────────────────────────────────────
  @@ -44,5 +44,5 @@
   Future<User?> validateUser(String email, String pass) async {
     final result = await db.query(email);
  -  if (result.data.user.isActive) {
  +  if (result.data?.user?.isActive == true) {
     return result.data.user;
  ──────────────────────────────────────────────────────

  [y] Apply    [n] Reject    [e] Edit first    [s] Skip    [o] Once (approve this call only)
```

### 7.4 High-Risk Prompt (typed confirmation)

```
──────────────── ⚠ HIGH-RISK ACTION ─────────────────────

  Proxima wants to delete:
    lib/legacy/old_auth.dart
    lib/legacy/old_session.dart
    lib/legacy/helpers.dart  (3 files)

  ⚠  This cannot be automatically undone.
     Proxima does not create backups for deletions.

  Type CONFIRM to proceed, or press Enter to abort:
  > _
```

### 7.5 Audit Log

Every evaluation — approved, rejected, or blocked — is appended to `~/.proxima/audit.jsonl`:

```jsonl
{"ts":"2025-03-17T10:22:01Z","session":"sess_abc","tool":"read_file","args":{"path":"auth.dart"},"decision":"auto_approved","risk":"safe"}
{"ts":"2025-03-17T10:22:03Z","session":"sess_abc","tool":"write_file","args":{"path":"auth.dart"},"decision":"user_approved","risk":"confirm","input":"y"}
{"ts":"2025-03-17T10:22:11Z","session":"sess_abc","tool":"run_command","args":{"command":"rm -rf /"},"decision":"blocked","risk":"blocked","reason":"blocked_pattern:rm_root"}
```

---

## 8. Layer 6 — Tool System

### 8.1 Tool Interface

Every tool — built-in or plugin — implements the same abstract class:

```dart
abstract class ProximaTool {
  String get name;
  String get description;
  RiskLevel get riskLevel;
  Map<String, dynamic> get inputSchema;   // JSON Schema
  bool get dryRunSupported;

  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx);
  Future<String> dryRun(Map<String, dynamic> args, ToolContext ctx);
  List<String> validateArgs(Map<String, dynamic> args);
}

class ToolContext {
  final String workingDir;
  final ProximaSession session;
  final bool isDryRun;
  final Logger logger;
}

class ToolResult {
  final bool success;
  final Map<String, dynamic> output;
  final String? error;
  final int durationMs;
}
```

### 8.2 V1 Tools (MVP — all required)

#### `read_file`

```dart
// Risk: safe | Dry-run: n/a
// Args: path (required), start_line (optional), end_line (optional)
// Output: content, line_count, tokens_used
// Constraints:
//   - path must be within working directory (resolves symlinks, checks boundary)
//   - binary files return metadata only
//   - files > 100KB chunked automatically, returns chunk + pagination info
```

#### `write_file`

```dart
// Risk: confirm | Dry-run: yes (shows diff without applying)
// Args: path, content, mode (overwrite|diff_apply), diff (unified diff string, if mode=diff_apply)
// Output: bytes_written, backup_path
// Constraints:
//   - ALWAYS creates .proxima_bak before writing
//   - ALWAYS shows diff to user via permission gate
//   - Refuses to write outside working directory
//   - Records task_id for undo
//   - Agent should prefer patch_file for edits to existing files
//   - write_file is the correct choice for new files and full rewrites
```

#### `patch_file` (from your diagram — added as first-class tool)

```dart
// Risk: confirm | Dry-run: yes
// Args: path, patch (unified diff string)
// Output: hunks_applied, lines_changed, backup_path
// Constraints:
//   - Applies a unified diff without requiring full file content
//   - Safer than write_file for targeted edits
//   - Falls back to write_file if patch cannot apply cleanly
//   - Shows hunk-by-hunk confirmation in verbose mode
```

#### Agent Decision Rules: `patch_file` vs `write_file`

The agent MUST follow these rules when choosing between write tools:

| Situation | Tool to use |
|---|---|
| Editing an existing file (any size) | `patch_file` |
| Creating a new file | `write_file` |
| Replacing entire file content (full rewrite) | `write_file` |
| `patch_file` fails to apply cleanly | `write_file` (automatic fallback, logged) |

These rules are enforced in the system prompt. The agent's `reasoning` field must
acknowledge which rule applies when selecting a write tool.

#### `list_files`

```dart
// Risk: safe | Dry-run: n/a
// Args: path (optional), pattern (glob), recursive (bool), include_hidden (bool)
// Output: files[], total
// Constraints:
//   - Respects .gitignore and .proximaignore
//   - Max 1000 files per call
//   - Always returns relative paths
```

#### `glob`

```dart
// Risk: safe | Dry-run: n/a
// Args: pattern (glob string), base_dir (optional)
// Output: matches[], total
// Use case: find all *.dart files, **/*_test.dart, etc.
// Distinct from list_files — optimized for pattern-first queries
```

#### `search`

```dart
// Risk: safe | Dry-run: n/a
// Args: pattern (regex or literal), path (optional), file_pattern (glob),
//       case_sensitive (bool), context_lines (int), max_results (int)
// Output: matches[{file, line, content, context_before, context_after}], total
// V1: regex/literal only
// V2: AST-aware search (find all function definitions named X)
// V3: semantic search (find code that does X) — deferred, needs embedding pipeline
```

### 8.3 V1 Shell Tools

#### `run_command`

```dart
// Risk: confirm | Dry-run: yes (shows command, does not run)
// Args: command (string), working_dir (optional), timeout (int, default 30s),
//       capture_output (bool)
// Output: stdout, stderr, exit_code, duration_ms
// Constraints:
//   - Command validated against blocklist BEFORE permission prompt
//   - working_dir must be within project root
//   - No sudo, no curl|sh, no rm -rf /, no /etc writes
//   - Always shown to user verbatim before execution
```

#### `run_tests`

```dart
// Risk: confirm | Dry-run: yes (shows command)
// Args: framework (auto|jest|pytest|flutter|cargo|go|rspec|dart),
//       path (optional), filter (optional)
// Output: passed, failed, skipped,
//         failures[{test, error, file, line}], duration_ms
// Auto-detection: scans pubspec.yaml, package.json, Cargo.toml, etc.
```

### 8.4 V2 Tools (post-MVP)

| Tool | Risk | Description |
|---|---|---|
| `git` | safe/confirm | status, diff, log (safe); add, commit (confirm); reset --hard (high-risk) |
| `delete_file` | high-risk | Delete with typed confirmation, no automatic backup |
| `rename_file` | confirm | Move/rename with undo support |
| `create_dir` | safe | Create directory structure |
| `http_request` | confirm | Fetch a URL (for reading docs, API responses) |

### 8.4.1 Shared Ignore Matcher ✅ Shipped

**File:** `lib/tools/ignore_matcher.dart`

One source of truth for which paths the file-walking tools skip. Previously
there were three inconsistent definitions — `find_references_tool` and
`search_symbol_tool` held byte-identical copies of one skip set,
`project_index` held a different one, and `list_files`, `glob`, and `search`
had none at all, so `search` walked `node_modules` and `list_files` recursed
into `.git`.

Sources, applied in order:
1. built-in defaults (VCS, dependency, and build directories)
2. `.gitignore` in the working directory
3. session patterns added with `/ignore`

Two predicates, because the tools walk in two shapes: `isIgnored(relPath)` for
the flat `list(recursive: true)` walkers, and `shouldPruneDir(basename)` for the
manual recursive walkers, which can skip a subtree before descending.

Gitignore semantics — negation (`!`), leading-`/` anchoring, trailing-`/`
directory-only, `**` crossing separators — are implemented in-repo: there is no
null-safe `.gitignore` matcher on pub.

**Plumbing:** the matcher lives on `ToolRegistry` and is injected into tools as a
callback, so `ProximaTool.execute(args, workingDir)` — a Layer-6 contract that
plugins also implement — is unchanged. The agent loop refreshes it each turn, so
an edited `.gitignore`, a new `/ignore` pattern, or a `/dir` switch takes effect
without a restart.

**`/ignore` is now enforced.** It previously stored and displayed patterns that
nothing read.

### 8.5 Tool Plugin System ✅ Shipped

Plugins drop into `.proxima/plugins/<name>/` (or any path in `plugin_dirs`). Each plugin is a directory containing a `plugin.json` descriptor and an executable file (shell script or binary).

**Files:**
- `lib/tools/plugin/shell_plugin_tool.dart` — `ShellPluginTool` implements `ProximaTool`; passes args as JSON on stdin, reads result from stdout, enforces configurable timeout
- `lib/tools/plugin/plugin_loader.dart` — `PluginLoader.load(dirs, workingDir)` discovers, validates, and registers plugins at REPL init

**Protocol:** args → JSON on `stdin`; result ← `stdout`; non-zero exit → `ToolError`.

`PluginLoader` logs startup warnings for malformed descriptors and skips them — Proxima always launches successfully even if plugins are broken.

Plugin tools go through the same permission gate as built-in tools. `_buildToolRegistry()` in `repl.dart` is async and loads plugins after all built-in tools are registered; a plugin name that conflicts with a built-in is silently skipped (built-in wins).

---

## 9. Layer 7 — Context Manager

### 9.1 Token Budget

At session start, Proxima calculates the token budget from the active model's `contextWindow`:

```dart
TokenBudget calculateBudget(LLMProvider provider) {
  final total = provider.capabilities.contextWindow;
  return TokenBudget(
    systemPrompt:     (total * 0.03).round(),   // ~3%
    projectIndex:     (total * 0.02).round(),   // ~2%
    activeFiles:      (total * 0.18).round(),   // ~18%
    conversationHistory: (total * 0.35).round(), // ~35%
    toolResults:      (total * 0.18).round(),   // ~18%
    outputHeadroom:   (total * 0.10).round(),   // ~10%
    safetyMargin:     (total * 0.14).round(),   // ~14%
  );
}
```

This scales automatically: a 200K model gets generous budgets, an 8K local model forces aggressive compaction.

### 9.2 Project Index

Built once at session start, injected in every LLM call at low token cost:

```
Project: myapp  (Flutter / Dart)
Root: ~/dev/myapp

Structure:
  lib/
    auth/         auth.dart, session_manager.dart, token_service.dart
    models/       user.dart, project.dart, settings.dart
    screens/      login_screen.dart  (+12 others)
    services/     api_client.dart, cache_service.dart
  test/           auth_test.dart  (+8 others)
  pubspec.yaml    sdk: ">=3.5.0", flutter: ^3.24.0

Recently modified: lib/auth/auth.dart (4m), lib/models/user.dart (2h)
Active warnings:   3 null-safety issues in auth.dart
Test status:       last run 14m ago — 2 failing
```

#### 9.2.1 Construction

The project index is built at session start by the following steps, in order:

1. **Filesystem walk** — Recursively list all files from `workingDir`, respecting
   `.gitignore` (via `git ls-files --others --exclude-standard` + tracked files) and
   `.proximaignore`. Directories with >50 files are summarized as `dirname/ (N files)`.

2. **Framework detection** — Scan for known manifest files in priority order:
   - `pubspec.yaml` → Dart / Flutter
   - `package.json` → Node.js / JS/TS
   - `Cargo.toml` → Rust
   - `go.mod` → Go
   - `requirements.txt` / `pyproject.toml` → Python
   - `build.gradle` / `pom.xml` → Java/Kotlin
   First match wins. Unknown projects are labeled "unknown".

3. **Recently modified** — Run `git log --name-only --pretty=format: -n 20` to find
   files changed in the last 20 commits. Format as relative time (e.g. "4m", "2h", "3d").
   Falls back to filesystem mtime if not a git repo.

4. **Active warnings** — Run `dart analyze --format=machine` (or framework equivalent)
   and count warnings/errors per file. Inject top 3 most-warned files only.
   Skip if analysis takes >5s (non-blocking timeout).

5. **Test status** — Check for cached test results in `.proxima/last_test_run.json`.
   If present and <30min old, inject summary. Otherwise omit — do not run tests at index build time.

6. **Token count** — Estimate token count of assembled index. If >600 tokens, truncate
   the file tree (keep top-level dirs only) until within budget.

Rebuilt automatically when `workingDir` changes (e.g. via `/dir`). Not rebuilt mid-session
unless explicitly triggered.

Target: ~500 tokens. Rebuilt if working directory changes.

### 9.3 Compaction Strategy

When conversation history exceeds its budget, three compaction passes run in order:

**Pass 1 — Prune acknowledged tool results**

Tool results that have already been used (the LLM has responded to them) are replaced with summaries:

```
Before: read_file("auth.dart") → [1,204 tokens of file content]
After:  read_file("auth.dart") → [summary: 204-line Dart auth file. Null-safety bug found on line 46. Fixed in turn 4.]
```

**Pass 2 — Summarize old exchanges**

Exchanges older than `config.context.compressAfterTurns` (default: 10) are collapsed:

```
[Summary of turns 1-8: Investigated login bug. Read auth.dart, session_manager.dart, user.dart.
Found null dereference in validateUser() on line 46. Fixed with null-safe operators.
Tests passed after fix. User then asked about token refresh logic.]
```

**Fallback on summarization failure**

Pass 2 requires an LLM call. If that call fails (timeout, rate limit, provider error,
or malformed response), Proxima does NOT retry — it falls back immediately to truncation:

- Drop the oldest N exchanges (where N = however many are needed to bring history within budget)
- Log the failure: `{"event": "compaction_fallback", "reason": "summarization_failed", "exchanges_dropped": N}`
- Continue the session normally — do not surface this failure to the user

Rationale: compaction is a background concern. A failed summarization should never
block or interrupt the user's session. Truncation is safe and deterministic.

**Pass 3 — File relevance scoring**

Files are not injected wholesale. Proxima scores each file per request:

```dart
double scoreRelevance(String filePath, String query, ProximaSession session) {
  double score = 0.0;
  // Filename matches query keywords
  score += keywordOverlap(filePath, query) * 0.4;
  // File was read or modified recently
  if (session.modifiedFiles.contains(filePath)) score += 0.3;
  if (session.recentlyRead.contains(filePath)) score += 0.2;
  // File was mentioned in recent conversation
  score += mentionScore(filePath, session.lastNTurns(5)) * 0.1;
  return score;
}
```

Only the top-K files by relevance score are injected, up to the `activeFiles` budget.

---

## 10. Layer 8 — Error Handler (Gap #3 closed)

### 10.1 Error Taxonomy

| Class | Examples | Recovery |
|---|---|---|
| `ToolExecutionError` | file not found, test failure, command exit code ≠ 0 | Inject error context → LLM attempts fix → retry (max 3) |
| `LLMError.rateLimit` | 429 response | Exponential backoff: 2s, 4s, 8s → retry up to 3× |
| `LLMError.timeout` | No response in time limit | Retry once → offer model switch |
| `LLMError.schemaViolation` | Response not valid JSON or missing `type` field | Re-prompt with schema reminder → retry up to 2× |
| `LLMError.contextTooLong` | 400 from provider | Emergency compaction → retry once |
| `LLMError.authFailure` | 401 invalid key | Hard stop → show fix instructions |
| `SecurityViolation` | Path traversal, blocked command | Hard reject → log → never retry |
| `LogicError.stuck` | 3 identical tool calls | Show stuck dialog → user decides |
| `LogicError.spinning` | 6 consecutive read-only calls | Show spinning dialog → user decides |
| `LogicError.maxIterations` | Loop hit ceiling | Show failure summary with options |

### 10.2 Structured Error Context

When a tool fails, the error injected back to the LLM is structured, not a raw string:

```json
{
  "type": "tool_result",
  "call_id": "c7",
  "tool": "run_tests",
  "status": "error",
  "error": {
    "code": "TEST_FAILURE",
    "message": "2 of 14 tests failed",
    "details": {
      "failures": [
        {
          "test": "AuthTest > validateUser returns null for disabled user",
          "error": "Expected: <null>\n  Actual: User{id:42, isActive:false}",
          "file": "test/auth_test.dart",
          "line": 88
        }
      ]
    }
  },
  "retry_count": 1,
  "max_retries": 3
}
```

### 10.3 User-Facing Failure Summary

When max retries are exhausted, Proxima never shows a raw stack trace:

```
✗  Task failed after 3 attempts

  What I tried:
    1. Fixed null check in validateUser() → tests still failed (2 failures)
    2. Added null guard at call site in login_screen.dart → 1 test passed, 1 still failing
    3. Investigated UserModel — hit retry limit

  Where I got stuck:
    The failing test expects validateUser() to return null for disabled users,
    but UserModel.isDisabled doesn't exist in the model class yet. This looks
    like a test written ahead of the implementation.

  What you can do:
    [1] Show me the failing tests
    [2] Add UserModel.isDisabled and retry from here
    [3] Skip this task and move on
    [4] Undo all changes from this task
```

---

## 11. Layer 9 — Renderer

### 11.1 Output Components

| Component | Package | Description |
|---|---|---|
| Base ANSI | `ansi_styles` | Color, bold, underline |
| Terminal control | `dart_console` | Cursor, clear, raw input |
| Syntax highlight | custom / `highlight` | Dart, JS, Python, etc. |
| Diff render | custom | Unified diff with +/- coloring |
| Spinner | custom | Async progress indicators |
| Tables | custom | Aligned column output |
| Permission prompts | custom | Structured y/n/e/s prompts |

### 11.2 Streaming

LLM responses stream token-by-token to the terminal. The renderer writes chunks as they arrive, handling partial JSON gracefully (accumulates until a full response object is received, then displays the human-readable parts immediately).

### 11.3 Token Usage Display

Token usage displays after every response (both cloud and local models) via `AgentCallbacks.onUsageReport(turnUsage, cumulative)`, called by the agent loop immediately before `onFinalResponse` or `onClarify`:

```
  ↑4201 ↓312  total: 18543
```

The renderer outputs this as a dim line so it doesn't dominate the response. When cloud models are active this can be extended in future to show cost estimates.

---

## 12. LLM Message Contract (strict)

### 12.1 LLM Response Types

Every response from the LLM must be one of four types. Proxima validates the schema on every response — malformed responses are rejected and the model is re-prompted.

#### `tool_call`

```json
{
  "type": "tool_call",
  "tool": "read_file",
  "call_id": "call_a1b2c3",
  "args": { "path": "lib/auth/auth.dart" },
  "reasoning": "Need to read auth.dart to locate the null dereference before proposing a fix."
}
```

`reasoning` is **required**. It surfaces agent intent for observability and prevents mindless looping.

#### `final`

```json
{
  "type": "final",
  "message": "Fixed a null dereference in validateUser(). Applied null-safe operators on line 46. Tests passing.",
  "changes": [
    { "file": "lib/auth/auth.dart", "type": "bug_fix", "lines_changed": 2, "applied": true }
  ],
  "next_suggested_action": "Run flutter test test/auth_test.dart to confirm."
}
```

#### `clarify`

```json
{
  "type": "clarify",
  "question": "The login issue could be in auth.dart or session_manager.dart. Which should I check first?",
  "options": [
    "auth.dart — credential validation",
    "session_manager.dart — session state",
    "Both — check in order"
  ]
}
```

#### `error` (model-generated, not system)

```json
{
  "type": "error",
  "reason": "I cannot determine the root cause without seeing the stack trace from the failing test. Can you run the test and share the output?",
  "missing": "test output / stack trace"
}
```

### 12.2 Tool Result Injection

```json
{
  "type": "tool_result",
  "call_id": "call_a1b2c3",
  "tool": "read_file",
  "status": "success",
  "output": {
    "path": "lib/auth/auth.dart",
    "content": "...",
    "line_count": 204,
    "tokens_used": 1204
  },
  "execution_time_ms": 14
}
```

---

## 13. File Editing Model

### 13.1 V1 — Backup + Overwrite

Before any write:
1. Copy original to `<path>.proxima_bak.<timestamp>`
2. Record `{path, backup_path, task_id}` in session
3. Write new content
4. On `/undo`, restore from backup

### 13.2 V2 — Patch-Based Editing (preferred)

`patch_file` applies a unified diff without requiring full file content. This is safer for large files and allows hunk-level review:

```diff
--- lib/auth/auth.dart (original)
+++ lib/auth/auth.dart (patched)
@@ -44,6 +44,6 @@
   Future<User?> validateUser(String email, String pass) async {
     final result = await db.query(email);
-    if (result.data.user.isActive) {
+    if (result.data?.user?.isActive == true) {
       return result.data.user;
     }
```

### 13.3 Undo System

Every top-level task gets a `task_id`. All file modifications during that task are grouped:

```bash
> /undo
  Undo task: "fix the login bug"  (t_20250317_102201)
  Files to restore:
    lib/auth/auth.dart  ← lib/auth/auth.dart.proxima_bak.1710670921
  Restore? (y/n)

> /undo t_20250317_0945    # undo specific earlier task
```

---

## 14. Subagent System  ← GAP CLOSED

Subagents are **specialized prompt wrappers**, not autonomous systems. The main agent delegates explicitly, receives structured output, and retains full control.

### 14.1 Hierarchy

```
Main Agent (orchestrator)
  │
  ├── CodeAnalyzerAgent    → issues[], severity[], suggestions[]
  ├── RefactorAgent        → proposed_changes[diff], impact_summary
  └── TestAgent            → test_cases[], coverage_gaps[], failing_tests[]
```

### 14.2 Constraints

- Max 2 subagent delegations per main agent turn
- Subagents cannot call tools directly — they work with content provided by the main agent
- Subagents cannot delegate to other subagents (no nesting)
- All subagent outputs return to the main agent for decision-making

---

## 15. Security Model

### 15.1 Filesystem Isolation

```dart
bool isSafePath(String baseDir, String targetPath) {
  final resolved = path.canonicalize(path.join(baseDir, targetPath));
  return resolved.startsWith(path.canonicalize(baseDir));
}
```

Called by every file tool before execution. Symlinks are resolved before comparison.

### 15.2 Command Blocklist

Applied **before** the permission prompt — these cannot be approved:

```dart
final List<RegExp> blockedPatterns = [
  RegExp(r'rm\s+-rf\s+[/~]'),         // rm -rf / or ~/
  RegExp(r'curl\s+.*\|\s*(ba)?sh'),    // curl | bash/sh
  RegExp(r'wget\s+.*\|\s*(ba)?sh'),    // wget | bash/sh
  RegExp(r'\bsudo\b'),                 // any sudo
  RegExp(r'chmod\s+777'),              // world-writable
  RegExp(r'>\s*/etc/'),                // write to /etc
  RegExp(r'\bdd\s+if='),              // disk operations
  RegExp(r'mkfs\.'),                   // format filesystem
  RegExp(r':\(\)\{.*\}'),             // fork bombs
];
```

### 15.3 API Key Handling

- Provider keys: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` (env) or
  `anthropic_api_key`, `openai_api_key` (YAML). Base URLs: `OPENAI_BASE_URL` /
  `openai_base_url` and `OLLAMA_BASE_URL` / `ollama_base_url`.
- Keys read from environment variables or `~/.proxima/config.yaml` only
- Never stored in project directories
- Never sent to any party except the named model provider

**Precedence:** `~/.proxima/config.yaml` → then `.proxima/config.yaml` (project,
wins) → falling back to the environment. A key set in YAML therefore **overrides**
`ANTHROPIC_API_KEY` in the environment; the environment is the fallback, not the
override. Same for `ollama_base_url` / `OLLAMA_BASE_URL`. This is deliberate — the
config file is the more explicit signal — but note that a stale key in YAML will
silently shadow a fresh `export`.

### 15.3.1 Secret Masking ✓ Implemented

**File:** `lib/core/secret_masker.dart`

Tool arguments are persisted in two places, and both are masked before writing:

| Sink | Field | Site |
|---|---|---|
| `~/.proxima/audit.jsonl` | `args` | `lib/permissions/audit_log.dart` |
| `~/.proxima/sessions/*.json` | `tool_input` | `lib/core/types.dart` (`Message.toJson`) |
| `~/.proxima/sessions/*.json` | `task_history[].args` | `lib/core/session.dart` (`TaskRecord.toJson`) |

Masking the audit log at `AuditLog.record()` covers all seven `record(...)` call
sites in `permission_gate.dart` at once — including the `auto_allowed` path, so
every tool call is covered, not just risky ones.

**Detection** is belt-and-braces — value patterns *and* argument names:
- **Patterns:** Anthropic (`sk-ant-`), OpenAI (`sk-proj-`, `sk-`), GitHub
  (`gh[porsu]_`), AWS (`AKIA…`), JWTs (`eyJ….….…`), Slack (`xox[baprs]-`), and
  `Authorization` headers. More specific prefixes are tried first so the generic
  `sk-` rule cannot shadow `sk-ant-`.
- **Authorization headers** consume the optional scheme (`Bearer`, `Basic`,
  `Token`, `Digest`, `APIKey`) **and the credential after it**. Masking only the
  scheme would leave an opaque credential — one with no provider-specific prefix,
  such as `Authorization: Basic dXNlcjpwYXNz` — on disk in the clear. The match
  stops at a quote, comma, or semicolon so the surrounding command stays intact.
  A bare scheme with no `Authorization:` prefix — `Bearer`, `Basic`, `Digest`,
  `APIKey` — is also matched when the credential is ≥8 non-space characters, so
  ordinary prose such as `git commit -m "basic cleanup"` is not mangled. `Token`
  is handled by a stricter rule (≥12 chars and must contain a digit) because it
  is a common English word.
- **Argument names:** `api_key`, `apikey`, `token`, `secret`, `password`,
  `passwd`, `auth`, `authorization`, `credential`, `private_key` — value replaced
  wholesale. `authorization` is listed separately from `auth` because matching is
  per segment (see below): without it, a structurally-passed header such as
  `{'headers': {'Authorization': 'Token abc'}}` would reach disk verbatim, since
  the key is the only signal there.
  Key names are **normalised before matching**: camelCase is split, then any run
  of non-alphanumeric characters collapses to `_`. So `api-key`, `x-api-key`,
  `apiKey`, `api.key`, and `API-KEY` all match `api_key`. Matching is per
  underscore-delimited **segment**, not raw substring, so `author` does not
  collide with `auth`, nor `tokenizer` with `token`.

Replacement is `***`. Nested maps and lists are recursed into.

User and assistant message content is masked as well — a credential pasted into
a prompt would otherwise be stored verbatim.

**Deliberately NOT masked:**
- **Terminal output** — `permission_prompt.dart`, `renderer.dart` `_fmtArgs`,
  `task_summary_renderer.dart`. The confirm prompt must show the *real* command
  being approved; masking it would mean approving text that differs from what
  executes.
- **Tool results** (`Message.content`). Results are replayed to the model on
  `--resume`; feeding back `***` would likely cause the tool to be re-run.

**Load-bearing constraint:** masking happens at the *serialisation boundary only*
— inside `toJson()` / `record()` — never on the live in-memory session.
`AnthropicProvider` sends `Message.toolInput` to the API and `Compaction` reads
`toolInput['path']`; masking in memory would corrupt what the model sees and
break file-read deduplication.

---

## 16. Configuration Reference

```yaml
# ~/.proxima/config.yaml

model:
  default: anthropic/claude-sonnet-4
  fallback: ollama/qwen2.5-coder:32b
  auto_fallback_on_failure: true

providers:
  anthropic:
    api_key: $ANTHROPIC_API_KEY
    timeout: 60
  openai:
    api_key: $OPENAI_API_KEY
  google:
    api_key: $GOOGLE_API_KEY
  groq:
    api_key: $GROQ_API_KEY
  ollama:
    base_url: http://localhost:11434
    timeout: 120
  lm_studio:
    base_url: http://localhost:1234/v1
    model: ~

agent:
  max_iterations: 25
  max_tool_retries: 3
  max_llm_retries: 2
  tool_timeout_seconds: 30
  stuck_detection_window: 3

context:
  compress_after_turns: 10
  max_file_injection_tokens: 20000
  project_index_enabled: true

permissions:
  default_mode: confirm         # safe | confirm | auto
  audit_log_enabled: true
  audit_log_path: ~/.proxima/audit.jsonl

session:
  save_sessions: true
  session_dir: ~/.proxima/sessions
  max_saved_sessions: 50

editor:
  diff_editor: $EDITOR

ui:
  streaming: true
  color: auto                   # auto | always | never
  show_token_usage: true
  show_cost_estimate: true

plugins:
  - path: ~/.proxima/plugins/
    enabled: true
```

```yaml
# .proxima/config.yaml  (project-level, overrides user config)
model:
  default: ollama/qwen2.5-coder:32b

permissions:
  default_mode: safe

ignore:
  - "*.env"
  - ".secrets/"
  - "node_modules/"
  - ".proxima_bak*"
```

---

## 17. Dart Package Reference

| Layer | Package | Purpose |
|---|---|---|
| CLI | `args` | Argument parsing |
| CLI | `dotenv` | .env file loading |
| Config | `yaml` | YAML parsing |
| HTTP | `http` | REST API calls |
| Streaming | `eventsource` | SSE streaming from providers |
| Terminal | `dart_console` | Cursor, raw mode, terminal size |
| Terminal | `ansi_styles` | ANSI color / formatting |
| File diff | `diff_match_patch` | Generate and apply unified diffs |
| Schema | `json_schema` | JSON Schema validation |
| Paths | `path` | Cross-platform path operations |
| Collections | `collection` | DeepCollectionEquality etc. |
| Logging | `logging` | Structured log output |
| Testing | `test` | Unit and integration tests |
| Mocking | `mockito` | Mock providers and tools in tests |

---

## 18. MVP Definition (honest)

Proxima is not an MVP until all of these pass end-to-end:

**Session & CLI**
- [x] `proxima` starts REPL with header showing model, dir, tokens
- [x] `/help`, `/exit`, `/clear`, `/history`, `/files` all work
- [x] `--dry-run` flag prevents all writes and command execution
- [x] `--debug` shows tool call logs and latency per call

**Model Layer**
- [x] At least one cloud provider connects and responds
- [x] At least one local provider (Ollama) connects and responds
- [x] `/model list` shows available models with status
- [x] `/model use` switches mid-session
- [x] Auto-fallback works when cloud provider fails

**Agent Loop**
- [x] Multi-turn reasoning works (agent calls multiple tools before responding)
- [x] Max iteration limit is enforced — no infinite loops
- [x] Stuck detection fires after 3 identical tool calls
- [x] Spinning detection fires after 6 consecutive read-only calls
- [x] Schema validator rejects malformed LLM responses

**Permission Gate**
- [x] Safe tools auto-execute without prompting
- [x] Confirm tools show diff + y/n/e/s prompt before executing
- [x] High-risk actions require typed "CONFIRM"
- [x] Blocked patterns hard-reject before prompt
- [x] Session allowlist (`/allow write lib/auth/**`) works
- [x] Safe session mode blocks all non-safe tools without prompt

**Tools**
- [x] `read_file` reads within working directory, rejects path traversal
- [x] `list_files` respects .gitignore
- [x] `glob` matches patterns correctly
- [x] `search` finds regex matches across files
- [x] `write_file` creates backup, shows diff, applies on approval
- [x] `patch_file` applies unified diff with hunk preview
- [x] `run_command` shows command, requires approval, respects blocklist
- [x] `run_tests` auto-detects framework, parses failures

**Context & Error**
- [x] Token usage displays after each response
- [x] Context compaction triggers before overflow
- [x] Tool errors produce structured context for LLM retry
- [x] User-facing failure summary shown when max retries hit

**Security**
- [x] `../../../etc/passwd` path traversal is blocked
- [x] `rm -rf /` is blocked before permission prompt
- [x] API keys are masked in all logs

---

## 19. V1.1 Architecture Enhancements

These improvements are planned for the next release. All correctness gaps from v1.0 are already fixed (see CHANGELOG).

### 19.1 Test Output Parser ✓ Implemented

**File:** `lib/tools/shell/test_output_parser.dart`

Parses `run_tests` stdout into structured `TestResult` / `TestFailure` objects:
- Frameworks: Dart, Jest, Pytest, Cargo, Go — framework-specific regex, graceful fallback to raw string
- `run_tests_tool.dart` calls the parser and returns a structured failure report (name, file, message) first, then raw output for failures
- `FRAMEWORK:<name>` marker embedded in tool result (same pattern as `BACKUP_PATH:`) for downstream parsing
- `extractFramework(toolResult)` helper reads the marker back out
- 15 tests covering all five frameworks and the extractor

### 19.2 Critic Subagent (GAN-inspired review) ✓ Implemented

A pre-commit review subagent fires before the permission prompt on `write_file` / `patch_file` at `confirm` risk level. It is advisory only — never a hard gate.

**When it fires:** `RiskLevel.confirm` writes only. Never in `SessionMode.auto`. Never on shell/git tools.

**Verdict schema:**
```json
{
  "verdict": "approve | warn | block_suggestion",
  "issues": [{"severity": "low|medium|high", "description": "...", "line_hint": "..."}],
  "summary": "one sentence"
}
```

`approve` → silent (zero noise). `warn` / `block_suggestion` → printed above the y/n prompt in amber/red.

**Config:** `critic_on_write: true` in `.proxima/config.yaml` (default: true). Token cap: 1024.

**Key types:** `CriticResult`, `CriticVerdict`, `CriticIssue` in `subagent_runner.dart`. `PermissionGate.criticCallback` optional `CriticCallback?`. `PromptCallback` extended with `{CriticResult? criticResult}` named parameter. 7 tests.

### 19.3 Context Summarization + File Cache

**LLM-based summarization ✓ Implemented:** `SubagentRunner.runSummarizer()` summarises the run of messages Pass 2 (`truncateHistory`) is about to discard — 3–5 bullets covering files touched, changes made, and decisions reached — and `Compaction.compact()` pins the result to the front of the retained history.

Cost is bounded and opt-out: the call fires **only** when messages would otherwise be dropped, so an under-budget turn spends nothing. `max_tokens` is capped at 512 and no tools are sent. The transcript is bounded twice — each source message is clipped to 2000 characters, *and* the joined transcript to 24000 characters, keeping the newest messages. Bounding only per-message would let a session that discards hundreds of messages build an unbounded prompt, busting the context window exactly when summarising matters most.

The summary is generated at most once per distinct span: the agent loop rebuilds
context on every iteration from the same session history, so without caching a
10-iteration turn would pay for 10 near-identical summaries. `runSummarizer`
returns the request's `TokenUsage`, which the caller records — a summarisation
request costs real tokens and would otherwise be missing from the session totals.

The transcript includes each message's `toolInput`, secret-masked: an assistant
tool-call message keeps its path there and often has empty content, and a
`read_file` result is numbered file text containing no path — so without it the
summariser cannot name the files that were read.

Budget is reserved before truncation, not after: `truncateHistory` trims to `conversationHistory - 512`, so prepending the summary cannot push the retained history back over its allocation. The reserve applies **only** when truncation is actually required — a history that already fits is left alone, with no discarded messages and no paid summary. A summary that overruns its reserve is clipped (the prefix counts against it too), and relevance filtering runs *before* injection so the summary cannot be filtered out in favour of messages it stands in for.

Degrades in every failure mode — no provider, a provider error, a non-final response, a blank summary, or a throwing summariser all fall back to the plain truncation that was already applied. A summarisation failure costs context, never the turn.

`Compaction.compact()` is now `async` and takes an optional `HistorySummarizer`; with none supplied its behaviour is byte-identical to before. Disable with `summarize_on_compact: false`.

**File cache deduplication ✓ Implemented:** `Map<String, String> fileCache` in `ProximaSession`. Agent loop populates it after every successful `read_file` call. `Compaction.deduplicateFileReads()` (Pass 0) replaces all but the most recent read of each path with `'[File already in context — see most recent read above]'`. `Compaction.compact()` accepts `fileCache` and runs deduplication first. Estimated savings: 15–30% in file-heavy sessions. 11 tests.

### 19.4 FallbackProvider ✓ Implemented

**File:** `lib/providers/fallback_provider.dart`

Wraps a primary `LLMProvider` with a secondary fallback. On `LLMError` (excluding `auth` errors), transparently retries via secondary. `ProviderRegistry.create()` accepts optional `fallbackModel` string from config (`fallback_model` yaml key). No changes to `AgentLoop`. 5 tests.

### 19.5 Persistent Default Model ✓ Implemented

`/model <name>` now writes the selected model back to `~/.proxima/config.yaml` via `ProximaConfig.saveDefaultModel()`. Future sessions start with the last chosen model automatically — no `--model` flag or re-selection required. The `model:` key is updated in-place; all other config keys are preserved. Non-fatal: write errors produce a dim warning, never a crash.

---

## 20. V1.2 Milestone Targets

| Feature | Priority | Status | Notes |
|---|---|---|---|
| Git tool (read-only first) | P0 | ✅ Shipped | `git_status`, `git_diff`, `git_log` |
| AST-aware search | P1 | ✅ Shipped | `search_symbol` — definitions; `find_references` — usages |
| `/mode auto` | P1 | ✅ Shipped | Accept-edits REPL mode + `/mode auto` |
| Multi-file refactoring with dependency graph | P1 | ✅ Shipped | `find_references` + `get_imports` cover the dependency surface |
| Cost tracking across sessions | P2 | ✅ Shipped | `CostCalculator`, `/cost` slash command |
| Git write operations | P2 | ✅ Shipped | `git_add`, `git_commit`, `git_reset` |
| Plugin system (live) | P2 | ✅ Shipped | Shell/binary plugins via `.proxima/plugins/` |

### V1.2 Plugin System Specification

Plugins live under `.proxima/plugins/<name>/` (or any directory listed in `plugin_dirs`).

#### Descriptor format (`plugin.json`)

```json
{
  "name": "jira_search",
  "description": "Search Jira issues by keyword",
  "risk_level": "safe",
  "timeout_seconds": 30,
  "executable": "run.sh",
  "input_schema": {
    "type": "object",
    "properties": { "query": { "type": "string" } },
    "required": ["query"]
  }
}
```

**Required fields:** `name`, `description`, `executable`, `input_schema`.
**`risk_level`:** `safe` | `confirm` | `high_risk` | `blocked` (default: `confirm` when unrecognised).
**Protocol:** Proxima passes args as JSON on `stdin`; reads result from `stdout`; non-zero exit → `ToolError`.

#### `PluginLoader`

`PluginLoader.load(dirs, workingDir)` — discovers and wraps valid plugins as `ShellPluginTool` instances.
- Silently skips missing or empty directories.
- Logs a startup warning for malformed/incomplete descriptors; never throws.
- Checks executable exists and has execute bit before registering (skipped on Windows — NTFS has no Unix mode bits).
- Fully async: `exists`, `readAsString`, `stat`, and directory listing all use async I/O to avoid blocking the Dart event loop during startup.

#### Config

```yaml
plugin_dirs:
  - .proxima/plugins        # default (project-level)
  - /shared/team-plugins    # additional dirs
```

Parsed from `plugin_dirs` YAML key in `ProximaConfig`. Default: `['.proxima/plugins']`.

### V1.2 `find_references` Tool

**File:** `lib/tools/search/find_references_tool.dart`
**Risk:** `safe`

Finds all usages of a symbol across the codebase using `\b<symbol>\b` word-boundary matching.

**Input schema:**

| Field | Type | Default | Description |
|---|---|---|---|
| `symbol` | string | required | Symbol to find |
| `path` | string | — | Restrict to subdirectory |
| `file_extensions` | array | `.dart .ts .js .tsx .jsx .py .go .rs .java .kt` | Extensions to scan |
| `exclude_definition` | boolean | `false` | Skip lines that look like the symbol's own definition |
| `max_results` | integer | `100` | Maximum matches returned |

**Output format:**
```
lib/foo/bar.dart:42  someMethod(symbol, other)
lib/foo/baz.dart:7   final x = symbol.field;

Found 2 references in 2 files.
```

Skips `.git`, `node_modules`, `build`, `.dart_tool`, `.pub-cache`, and generated files (`.g.dart`, `.freezed.dart`, `.pb.dart`).

**Implementation:** `_walk` uses `await for` streaming iteration (not `toList()`) so large directory trees are never fully buffered in memory. Scanning stops as soon as `max_results` is reached.

### V1.2 `get_imports` Tool

**File:** `lib/tools/search/get_imports_tool.dart`
**Risk:** `safe`

Parses all import statements from a single file and categorises them by source type.

**Input schema:**

| Field | Type | Default | Description |
|---|---|---|---|
| `path` | string | required | File to parse |
| `resolve_paths` | boolean | `false` | Expand local imports to project-relative paths |

**Language support and categories:**

| Language | Category | Condition |
|---|---|---|
| Dart | `[dart]` | `dart:*` |
| Dart | `[package]` | `package:*` |
| Dart | `[local]` | relative path |
| JS/TS | `[node]` | bare specifier |
| JS/TS | `[local]` | `./` or `../` prefix |
| Python | `[stdlib]` | single word or top-level package |
| Python | `[local]` | `.` relative prefix |
| Go | `[stdlib]` | no dot in path |
| Go | `[external]` | contains dot |

Throws `ToolError(notFound)` when file does not exist; `ToolError(parseError)` for binary files or unsupported extensions.

## 21. V1.3 Horizon

### 21.1 Official Plugin Distribution ✅ Shipped

The goal is a single command that installs any official or community plugin into a user-global directory, with no manual file copying.

#### User experience target

```bash
# CLI — before starting the REPL
proxima plugin list
proxima plugin install word-count
proxima plugin install jira-search
proxima plugin remove word-count

# Inside the REPL
/plugin list
/plugin install word-count
/plugin remove word-count
```

After install, the plugin is immediately available in the current and all future sessions — no restart required for CLI installs; REPL installs take effect on the next session start.

#### Architecture

**1. User-global plugin directory**

`~/.proxima/plugins/` is a second default entry in `ProximaConfig.pluginDirs`.
Plugins installed globally live here and are visible in every project.

Not the one-line change originally assumed: `PluginLoader` resolved relative
paths with `p.join(workingDir, dir)` and did no `~` expansion, so the literal
string would have resolved to `<workingDir>/~/.proxima/plugins`. Expansion is
handled by `PluginLoader.resolvePluginDir`, and **both** config defaults needed
updating.

**2. Official plugin catalogue (`catalog.json`)**

A machine-readable index published alongside every release as a GitHub release asset and permanently accessible at a stable URL:

```
https://github.com/jizzel/proxima/releases/latest/download/catalog.json
```

Schema:

```json
{
  "version": "1",
  "updated_at": "2026-04-01T00:00:00Z",
  "plugins": [
    {
      "name": "word-count",
      "display_name": "Word Count",
      "description": "Count words, lines, and bytes in a file.",
      "version": "1.0.0",
      "risk_level": "safe",
      "author": "proxima-core",
      "tags": ["files", "analysis"],
      "download_url": "https://github.com/jizzel/proxima/releases/latest/download/plugin-word-count.zip",
      "checksum_sha256": "abc123..."
    }
  ]
}
```

**3. Official plugins in the repo**

Official plugins live at `plugins/<name>/` in the repository root (distinct from `.proxima/plugins/` which is project-local). Each is a self-contained directory identical in structure to the existing `word-count` example.

```
plugins/
  word-count/
    plugin.json
    run.sh
    README.md
  git-summary/
    plugin.json
    run.sh
    README.md
```

**4. `PluginInstaller` — `lib/tools/plugin/plugin_installer.dart`**

Handles download, verification, and installation:

- Fetch `catalog.json` from the stable URL (with timeout + graceful offline fallback)
- Resolve the plugin's `download_url`
- Download the zip to a temp file
- Verify SHA-256 checksum against `catalog.json`
- Extract into `~/.proxima/plugins/<name>/`
- On checksum mismatch: delete temp file, throw error, never write to disk

**5. `proxima plugin` CLI subcommand**

Handled in `lib/cli/arg_parser.dart` before REPL init:

```
proxima plugin list              list available plugins from catalogue
proxima plugin list --installed  list locally installed plugins
proxima plugin install <name>    download and install a plugin
proxima plugin remove <name>     remove an installed plugin
proxima plugin update            update all installed plugins to latest
```

**6. `/plugin` slash command**

Maps to the same `PluginInstaller` logic; shows an arrow-key picker for `list` and `install`.

#### CI/CD changes required

| Change | Where | What |
|---|---|---|
| Build plugin zips | `release.yml` | New step: zip each `plugins/<name>/` dir → `plugin-<name>.zip` |
| Generate `catalog.json` | `release.yml` | Script reads each `plugin.json`, injects `download_url` + SHA-256, writes `catalog.json` |
| Upload assets | `release.yml` | Add `dist/plugin-*.zip` and `dist/catalog.json` to the `files:` list in the release step |
| CI plugin test | `ci.yml` | New step: validate every `plugins/*/plugin.json` against the descriptor schema |

The release workflow addition is roughly:

```yaml
- name: Package official plugins and generate catalog
  run: |
    mkdir -p dist
    python3 scripts/build_catalog.py \
      --plugins-dir plugins/ \
      --version "${GITHUB_REF_NAME#v}" \
      --output dist/catalog.json \
      --zip-dir dist/
```

`scripts/build_catalog.py` iterates each subdirectory, zips it, computes the SHA-256, and writes `catalog.json`.

#### Security

- Checksum verification is mandatory — no install proceeds without a match
- **Zip-slip is rejected**: every archive entry must resolve inside the target
  directory before extraction, or the install aborts having written nothing.
  Not in the original spec — a checksum proves the archive matches the
  catalogue, not that its contents are safe, so a compromised or malicious
  plugin could otherwise carry `../` entries and write anywhere the user can.
  Validation and extraction share one separator-normalised path: checking the
  raw entry name let `..\..\x` through on POSIX, where `path` treats a
  backslash as an ordinary character
- **Plugin names must be a single path component**: `plugin remove
  ../../Documents` otherwise resolved outside the install root and deleted it.
  Both CLI and `/plugin` report the rejection rather than propagating it — an
  uncaught throw ended the REPL session over a typo
- **`plugin.json`'s declared `executable` is contained too**: it is
  attacker-controlled, so a declared `../../victim.sh` would otherwise
  `chmod +x` a file outside the plugin, which `PluginLoader` would then follow
  and register under the descriptor's name, schema, and risk level. Such an
  archive is rejected outright, not merely skipped
- **An update never uninstalls on failure**: the existing plugin is moved aside
  and restored if the staged rename fails, rather than deleted up front
- Downloads are staged in a sibling temp directory and swapped into place, so a
  failure part-way through cannot leave a half-installed plugin
- Downloaded zips are extracted into a sandboxed temp directory first; only moved to `~/.proxima/plugins/` after verification
- The stable catalogue URL is HTTPS only; no plain-HTTP fallback
- `plugin remove` deletes the entire plugin directory; no residual files
- Community plugins (not in the official catalogue) can still be manually placed in `.proxima/plugins/` — the manual path is never removed

#### Offline behaviour

If the catalogue fetch fails (no network, GitHub down):
- `plugin list` → prints the locally installed plugins with a dim `(catalogue unavailable)` note
- `plugin install` → prints a clear error: `Could not reach plugin catalogue. Check your connection or install manually.`
- The REPL and all other tools continue to work normally — the catalogue is never a hard dependency

### 21.2 Further Horizon

- Semantic search via local embeddings (no cloud, privacy-preserving)
- Cross-session memory via lightweight local store
- PR description generation from git diff
- `--watch` mode for continuous file-change monitoring
- Community plugin registry (third-party plugins, separate catalogue URL)

---

## 22. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Local model too weak for complex reasoning | High | Medium | Clear capability warnings, one-command fallback to cloud |
| Agent produces incorrect diff | Medium | High | Diff review mandatory, backup always created, `/undo` always available |
| Context overflow on large codebases | High | Medium | Relevance scoring, chunking, compaction — all automatic |
| Schema drift breaks tool-call parsing | Medium | High | Strict validator on every response, re-prompt on violation |
| User enables `/mode auto` and loses files | Low | High | Auto mode requires explicit opt-in, shown in session header |
| Ollama not running | High | Low | Clear error: `Ollama not detected. Run: ollama serve` |
| Plugin executes malicious code | Low | Critical | Plugins require explicit enable per-session; sandboxing in V2 |
| Provider API key exposed in logs | Low | Critical | ✓ Mitigated — `secret_masker.dart` masks tool args in the audit log and session files (§15.3.1); terminal output deliberately unmasked |

---
