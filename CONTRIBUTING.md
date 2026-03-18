# Contributing to Proxima

Thanks for your interest in contributing. This document covers the development workflow, code style, and how the project is structured.

---

## Development setup

```bash
git clone https://github.com/jizzel/proxima.git
cd proxima
dart pub get
dart test        # all 71 tests must pass
dart analyze     # must be clean
```

Dart SDK `^3.11.1` is required.

---

## Before opening a PR

Every PR must pass all three checks:

```bash
dart format --output=none --set-exit-if-changed .   # no unformatted files
dart analyze                                         # zero issues
dart test                                            # all tests green
```

CI runs these automatically on every push and PR. Failing CI blocks merge.

---

## Architecture constraints

Proxima is structured as **nine explicit layers** with strict boundaries. The most important rule:

> **The agent loop (Layer 3) never touches the filesystem or executes tools directly. Every tool call goes through `permissionGate.evaluate()` (Layer 5) first, then `toolRegistry` (Layer 6).**

This is load-bearing — it ensures every destructive action is audited and gated. Do not bypass it.

Layer order (layers may only depend on layers below them):

```
1. CLI Entry          bin/proxima.dart, lib/cli/
2. Session Manager    lib/core/session.dart, session_storage.dart
3. Agent Loop         lib/agent/
4. Provider Interface lib/providers/
5. Permission Gate    lib/permissions/
6. Tool System        lib/tools/
7. Context Manager    lib/context/
8. Error Handler      (embedded in agent_loop.dart and providers)
9. Renderer           lib/renderer/
```

---

## Adding a new tool

1. Create `lib/tools/<category>/<name>_tool.dart` implementing `ProximaTool`:

```dart
class MyTool implements ProximaTool {
  @override String get name => 'my_tool';

  @override String get description => 'One sentence describing what it does.';

  @override RiskLevel get riskLevel => RiskLevel.safe; // or confirm / highRisk

  @override Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'param': {'type': 'string', 'description': '...'},
    },
    'required': ['param'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    // Always call isSafePath() before touching any file path.
    ...
  }

  @override
  Future<DryRunResult> dryRun(Map<String, dynamic> args, String workingDir) async {
    return DryRunResult(preview: 'Would do X', riskLevel: riskLevel);
  }
}
```

2. Register it in `lib/cli/repl.dart` → `_buildToolRegistry()`.

3. Add tests in `test/tools/<name>_test.dart`. Cover: happy path, path traversal rejection, and at least one error case.

---

## Adding a new provider

1. Create `lib/providers/<name>_provider.dart` implementing `LLMProvider`.
2. Register it in `lib/providers/provider_registry.dart` by adding a case to the `switch`.
3. If the provider lacks native tool use, wrap it with `ReActFallback`.
4. Add the prefix string (e.g. `"myprovider"`) to the README model table.

---

## Code style

- Run `dart format .` before committing. The formatter is authoritative.
- `dart analyze` must pass with zero issues — warnings are treated as errors in CI.
- No `// TODO` or `// FIXME` comments in merged code — open a GitHub issue instead.
- No `print()` calls — use `stderr.writeln()` for diagnostics or the `Renderer` for user output.
- Error messages shown to users go through `Renderer`. Internal errors go to `stderr`.
- All tools must call `isSafePath()` before accessing any file path supplied by the LLM.

---

## Tests

- Each new feature needs tests. Each bug fix needs a regression test.
- Tests live in `test/` mirroring the `lib/` structure.
- Use real file I/O in tool tests (via `Directory.systemTemp`), not mocks — mocks hide real bugs.
- Provider tests mock the HTTP client; agent loop tests mock the provider.
- The test suite must remain under ~5 seconds total.

---

## Commit messages

Follow conventional commits:

```
feat: add git_status tool
fix: correct word-right navigation past end of buffer
chore: bump dart_console to 4.2.0
docs: update README with Homebrew install instructions
test: add edge cases for path_guard symlink resolution
```

One line summary, imperative mood, no period at the end.

---

## Branching and PRs

- Branch from `main`. Name your branch `<type>/<short-description>`, e.g. `feat/git-tools` or `fix/history-navigation`.
- Keep PRs focused — one feature or fix per PR.
- Include a short description of what changed and why in the PR body.
- Link any related GitHub issues.

---

## Reporting bugs

Open a GitHub issue with:
- Proxima version (`proxima --version`)
- OS and architecture
- The command or input that triggered the bug
- Full terminal output (with `--debug` if relevant)

---

## Questions

Open a GitHub Discussion or an issue tagged `question`.
