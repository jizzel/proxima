# Changelog

All notable changes to Proxima are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Fixed

- `/clear` no longer resets the session; it only clears the terminal display and reprints the header
- `/history` help text corrected from "last N exchanges" to "last N messages"
- `/history` preview now taken from first line only, preventing multiline messages from breaking the display
- Extracted `_printCurrentHeader()` helper in `repl.dart` to eliminate duplicated header print calls

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

[Unreleased]: https://github.com/jizzel/proxima/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/jizzel/proxima/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/jizzel/proxima/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/jizzel/proxima/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/jizzel/proxima/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jizzel/proxima/releases/tag/v0.1.0
