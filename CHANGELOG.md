# Changelog

All notable changes to Proxima are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

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
- enhance install script with unified fetch function for curl and wget
- format code for improved readability and consistency
- add Windows installation script and update CI configuration for cross-platform support
- simplify header formatting logic in renderer for better maintainability
- improve PATH update logic in installation script

[Unreleased]: https://github.com/jizzel/proxima/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jizzel/proxima/releases/tag/v0.1.0
