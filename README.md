# Proxima

A terminal-native, model-agnostic coding agent built in Dart. Proxima understands, navigates, and modifies codebases through structured tool execution, with an explicit permission gate at every destructive boundary and zero required cloud dependency.

---

## Features

- **Model-agnostic** — Works with Anthropic Claude (cloud) and any Ollama model (local). Switch models mid-session with `/model`.
- **Full tool suite** — Read, write, patch, search files; run shell commands and tests; glob file trees.
- **Permission gate** — Every destructive action requires approval. Risk levels: `safe` (auto), `confirm` (diff + y/n), `high_risk` (typed CONFIRM), `blocked` (rejected outright).
- **Persistent sessions** — Conversation history saved to `~/.proxima/sessions/`. Resume with `--resume <id>`.
- **Persistent input history** — Command history saved across sessions (`~/.proxima/input_history`). Navigate with ↑/↓.
- **Interactive suggestion panel** — Tab completion for slash commands and model names. Arrow keys navigate; Enter selects and executes.
- **Audit log** — Every permission decision appended to `~/.proxima/audit.jsonl`.
- **Undo** — `/undo` restores the last file changed by `write_file` or `patch_file`.
- **Dry-run mode** — `--dry-run` shows what the agent would do without executing anything.

---

## Requirements

- Dart SDK `^3.11.1`
- For Anthropic models: `ANTHROPIC_API_KEY` environment variable
- For local models: [Ollama](https://ollama.com) running at `http://localhost:11434`

---

## Installation

### macOS and Linux

```bash
curl -fsSL https://raw.githubusercontent.com/jizzel/proxima/main/install.sh | sh
```

Detects platform and architecture automatically. Installs to `/usr/local/bin/proxima`. Override with `PROXIMA_INSTALL_DIR`.

### Windows

```powershell
irm https://raw.githubusercontent.com/jizzel/proxima/main/install.ps1 | iex
```

Installs to `%LOCALAPPDATA%\proxima\proxima.exe` and adds it to your user `PATH`. Override with `$env:PROXIMA_INSTALL_DIR`.

### Manual download

Download the pre-built binary for your platform from [Releases](https://github.com/jizzel/proxima/releases):

| Platform | Binary |
|---|---|
| macOS (Apple Silicon + Intel via Rosetta 2) | `proxima-macos-arm64` |
| Linux x86_64 | `proxima-linux-x64` |
| Windows x86_64 | `proxima-windows-x64.exe` |

```bash
# macOS Apple Silicon
curl -fsSL https://github.com/jizzel/proxima/releases/latest/download/proxima-macos-arm64 \
  -o /usr/local/bin/proxima && chmod +x /usr/local/bin/proxima
```

### Updating

Re-run the install script — it always fetches the latest release and overwrites the existing binary:

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/jizzel/proxima/main/install.sh | sh

# Windows
irm https://raw.githubusercontent.com/jizzel/proxima/main/install.ps1 | iex
```

You can check your current version with:

```bash
proxima --version
```

---

### Build from source

Requires Dart SDK `^3.11.1`:

```bash
git clone https://github.com/jizzel/proxima.git
cd proxima
dart pub get
dart compile exe bin/proxima.dart -o proxima
./proxima
```

---

## Usage

### Interactive REPL

```bash
proxima
```

### One-shot task

```bash
proxima --task "list all TODO comments in this project"
# or using positional arg:
proxima "refactor the auth module to use JWT"
```

### All flags

```
--task, -t       Run a single task and exit
--dir, -d        Working directory (default: current directory)
--model, -m      Model to use (e.g. anthropic/claude-sonnet-4-6)
--mode           Permission mode: confirm (default), safe, auto
--resume         Resume a previous session by ID
--debug          Show reasoning and full tool output
--dry-run        Preview actions without executing
--version        Print version
--help           Show usage
```

---

## Models

### Anthropic (cloud)

Requires `ANTHROPIC_API_KEY`:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
proxima --model anthropic/claude-sonnet-4-6
```

| Model | ID |
|---|---|
| Claude Opus 4.6 | `anthropic/claude-opus-4-6` |
| Claude Sonnet 4.6 | `anthropic/claude-sonnet-4-6` |
| Claude Haiku 4.5 | `anthropic/claude-haiku-4-5-20251001` |

### Ollama (local)

Requires Ollama running locally. No API key needed.

```bash
ollama pull qwen2.5-coder:32b
proxima --model ollama/qwen2.5-coder:32b
```

Switch models from inside the REPL:

```
 ❯ /model ollama/mistral:latest
```

---

## Slash Commands

| Command | Description |
|---|---|
| `/help` | Show all commands |
| `/model` | Open interactive model picker (arrow keys + Enter) |
| `/model <provider>/<name>` | Switch directly to a specific model |
| `/mode [safe\|confirm\|auto]` | Show or change permission mode at runtime |
| `/clear` | Clear terminal display (history preserved) |
| `/undo` | Restore the last file changed |
| `/allow <tool>` | Allow a tool for this session without prompting |
| `/status` | Show session info (model, tokens, iterations) |
| `/history [--last N]` | Show conversation history (optionally last N messages) |
| `/files` | Show files read or written this session |
| `/context` | Show token budget breakdown |
| `/tools` | List all registered tools with risk levels |
| `/debug [on\|off]` | Show or toggle debug output (reasoning + token counts) |
| `/deny <tool>` | Block a tool for this session |
| `/permissions` | Show current session permissions (allowed, denied, ignored) |
| `/dir <path>` | Switch working directory |
| `/ignore <pattern>` | Exclude a glob pattern from context |
| `/snapshot` | Save a session snapshot (resume with `--resume <id>`) |
| `/exit` | Exit Proxima |

---

## Keyboard Shortcuts

| Key | Action |
|---|---|
| ↑ / ↓ | Scroll through input history |
| ↑ / ↓ (suggestion panel) | Navigate suggestions |
| Enter (on suggestion) | Accept and execute |
| Tab | Accept top suggestion into buffer |
| Escape | Dismiss suggestion panel |
| Ctrl-A / Home | Move cursor to start |
| Ctrl-E / End | Move cursor to end |
| Ctrl-K | Delete from cursor to end of line |
| Ctrl-U | Delete from cursor to start of line |
| Alt-← / Alt-→ | Jump word left/right |
| Ctrl-C | Cancel current input |

---

## Configuration

### User config: `~/.proxima/config.yaml`

```yaml
model: anthropic/claude-sonnet-4-6
mode: confirm          # confirm | safe | auto
debug: false
dry_run: false
max_iterations: 10
max_subagent_delegations: 2    # max delegate_to_subagent calls per turn
anthropic_api_key: sk-ant-...   # or set via environment variable
ollama_base_url: http://localhost:11434
plugin_dirs:                   # additional plugin search paths
  - .proxima/plugins
```

### Project config: `.proxima/config.yaml`

Same format. Project config takes precedence over user config.

### Permission modes

| Mode | Behaviour |
|---|---|
| `confirm` (default) | Prompt for all writes, commands, and tests |
| `safe` | Only read operations — no writes, no commands |
| `auto` | Execute everything without prompting (use with care) |

---

## Tools

| Tool | Risk | Description |
|---|---|---|
| `read_file` | safe | Read file contents with optional line range |
| `list_files` | safe | List files in a directory |
| `glob` | safe | Find files matching a glob pattern |
| `search` | safe | Search file contents with regex |
| `search_symbol` | safe | Find function, class, method, or variable definitions by name |
| `find_references` | safe | Find all usages of a symbol across the codebase |
| `get_imports` | safe | List all imports in a file, categorised by type (Dart, JS/TS, Python, Go) |
| `write_file` | confirm | Write or create a file (auto-backup) |
| `patch_file` | confirm | Search-and-replace in a file (auto-backup) |
| `run_command` | confirm | Run a shell command |
| `run_tests` | confirm | Run the project test suite (auto-detects framework) |
| `git_status` | safe | Show working tree status |
| `git_diff` | safe | Show unstaged or staged diff |
| `git_log` | safe | Show recent commit history |
| `git_add` | confirm | Stage a file for commit |
| `git_commit` | confirm | Create a commit with a message |
| `git_reset` | high_risk | Reset working tree to a ref (destructive) |
| `delete_file` | high_risk | Delete a file (backup created, supports `/undo`) |
| `delegate_to_subagent` | safe | Delegate to a specialist subagent (`code_analyzer`, `refactor`, `test`) |

Blocked commands (never executed regardless of mode): `rm -rf /`, `sudo`, `curl | sh`, `git push --force`, path traversal, and other destructive patterns.

### Plugin tools

Drop-in tools live under `.proxima/plugins/<name>/` and consist of a `plugin.json` descriptor and an executable:

```
.proxima/plugins/word-count/
  plugin.json   ← descriptor
  run.sh        ← the executable (shell script, Python, Go binary, anything)
  README.md     ← optional, but good practice
```

**`plugin.json`:**
```json
{
  "name": "word_count",
  "description": "Count words, lines, and characters in a file.",
  "risk_level": "safe",
  "timeout_seconds": 10,
  "executable": "run.sh",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": { "type": "string", "description": "Relative path to the file" }
    },
    "required": ["path"]
  }
}
```

**Protocol:** Proxima serialises the tool arguments as JSON and writes them to the plugin's `stdin`. The plugin writes its result to `stdout`. Exit `0` on success; any non-zero exit is an error (stderr is shown to the user).

**Test your plugin standalone:**
```sh
echo '{"path":"README.md"}' | sh .proxima/plugins/word-count/run.sh
```

A fully annotated example plugin lives at `.proxima/plugins/word-count/` — including `run.sh` with inline comments explaining the protocol and `README.md` with tips for writing your own.

Malformed descriptors produce a startup warning and are skipped — Proxima always launches regardless.

| `plugin.json` field | Required | Notes |
|---|---|---|
| `name` | ✅ | Snake-case; must not clash with built-in tool names |
| `description` | ✅ | Shown to the LLM — be specific |
| `executable` | ✅ | Filename inside the plugin directory |
| `input_schema` | ✅ | JSON Schema object for the tool's arguments |
| `risk_level` | — | `safe` / `confirm` / `high_risk` (default: `confirm`) |
| `timeout_seconds` | — | Default: `30` |

Configure additional plugin directories via `plugin_dirs` in `.proxima/config.yaml`:

```yaml
plugin_dirs:
  - .proxima/plugins          # default
  - /shared/team-plugins      # extra dirs
```

---

## Data & Privacy

- Sessions: `~/.proxima/sessions/<id>.json`
- Input history: `~/.proxima/input_history`
- Audit log: `~/.proxima/audit.jsonl` (append-only)
- File backups: `<original_path>.proxima_bak` (deleted after `/undo`)

No data is sent anywhere except to the configured LLM provider.

---

## Development

```bash
# Run all tests
dart test

# Run a single test file
dart test test/agent/agent_loop_test.dart

# Lint
dart analyze

# Format
dart format .

# Smoke test (requires ANTHROPIC_API_KEY)
dart run bin/proxima.dart --debug --dry-run "list the files in this project"

# Build with version injected (version is otherwise 'dev' when run with dart run)
dart compile exe bin/proxima.dart -o proxima --define=APP_VERSION=0.1.4
```

### Architecture

Proxima is structured as nine explicit layers with strict downward-only dependencies:

![Proxima Architecture](https://res.cloudinary.com/attakorah/image/upload/v1773832428/others/Screenshot_2026-03-18_at_11.12.25_AM_ejqbjg.png)

```
┌─────────────────────────────────────────────────────────────────┐
│  L1  CLI Entry                                                  │
│      args · config.yaml · --debug · --dry-run · --resume       │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  L2  Session Manager                                            │
│      conversation history · undo stack · token usage           │
│      ~/.proxima/sessions/                                       │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  L3  Agent Loop                                                 │
│      think → act → observe · max 10 iter · schema validator    │
│      stuck (3 identical calls) · spinning (6 read-only calls)  │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────┬───────────────▼───────────────┐
│  L4  Cloud    │         L4  Local             │
│  Anthropic    │  Ollama · LM Studio           │
│  (streaming + │  (ReAct fallback for          │
│  native tools)│   no-tool models)             │
└───────────────┴───────────────────────────────┘
                  unified LLMProvider interface
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  L5  Permission Gate  ⚠  (load-bearing)                        │
│      safe → auto-run  ·  confirm → y/n diff prompt             │
│      high-risk → typed CONFIRM  ·  blocked → hard reject       │
│      audit log → ~/.proxima/audit.jsonl                        │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌──────────────────┬────────────▼──────────┬────────────────────┐
│  L6  File tools  │   L6  Shell tools     │  L6  Search tools  │
│  read_file       │   run_command         │  search (regex)    │
│  write_file      │   run_tests           │                    │
│  patch_file      │                       │                    │
│  list_files      │                       │                    │
│  glob            │                       │                    │
└──────────────────┴───────────────────────┴────────────────────┘
          ProximaTool interface · each tool declares risk level
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  L7  Context Manager                                            │
│      token budget · project index · 3-pass compaction          │
│      relevance scoring · file chunking                         │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  L8  Error Handler                                              │
│      tool retry ×3 · LLM backoff · schema re-prompt            │
│      emergency compaction · user escalation                    │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  L9  Renderer                                                   │
│      ANSI output · diff viewer · permission prompts            │
│      spinner · markdown · streaming                            │
└─────────────────────────────────────────────────────────────────┘
```

**Critical constraint:** The agent loop (L3) never touches the filesystem or executes tools directly. Every tool call goes through the permission gate (L5) first — this is load-bearing architecture.

**Agent behavior:** Max 2 delegations per turn via `delegate_to_subagent`. Subagents receive no tools and cannot delegate further. Subagent token usage is folded into the session cumulative total visible in `/status`.

---

## Roadmap

The following items are planned for future releases as minor additions in v1:

### V1.2.0 — Expanded tools and providers
- **Additional cloud providers** — OpenAI, Gemini, Groq, Mistral (same `LLMProvider` interface, new adapters)
- **Local providers** — LM Studio and llama.cpp in addition to Ollama
- **`delete_file` tool** — ✅ shipped: high-risk level, requires typed CONFIRM
- **`git` tools** — ✅ shipped: `git_status`, `git_diff`, `git_log`, `git_add`, `git_commit`, `git_reset`
- **Subagent support** — ✅ shipped: `delegate_to_subagent` with `code_analyzer`, `refactor`, and `test` specialist agents
- **`find_references` tool** — ✅ shipped: cross-file symbol reference finder
- **`get_imports` tool** — ✅ shipped: import graph extractor for a single file
- **Plugin system** — ✅ shipped: drop-in shell/binary tools via `.proxima/plugins/<name>/plugin.json`

### V1.3.0 — Official plugin distribution

Install community and official plugins with a single command:

```bash
proxima plugin list
proxima plugin install word-count
proxima plugin install jira-search
```

Or from inside the REPL: `/plugin install word-count`

**How it works:**
- Official plugins live in `plugins/` in this repo and are published as zip assets on every release alongside a signed `catalog.json`
- `proxima plugin install <name>` downloads the zip, verifies its SHA-256 checksum, and installs it to `~/.proxima/plugins/` (user-global, visible in every project)
- Works offline gracefully — existing installed plugins still load, install commands show a clear error
- Manual drop-in (copying a directory to `.proxima/plugins/`) always remains supported

**CI/CD additions for this milestone:**
- Release workflow packages each `plugins/<name>/` as a zip, generates `catalog.json` with checksums, and uploads both alongside the binary
- CI validates every official `plugin.json` against the descriptor schema on every push

### V1.4.0 — Intelligence
- **Semantic search** — embedding-based file retrieval for large codebases
- **Cross-session memory** — lightweight local store for persistent context
- **PR description generation** — from git diff
- **Community plugin registry** — third-party plugins at a separate catalogue URL

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow, how to add tools and providers, code style requirements, and PR guidelines.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## License

MIT — see [LICENSE](LICENSE).
