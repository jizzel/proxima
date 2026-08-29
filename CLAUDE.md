# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Proxima** is a terminal-native, model-agnostic coding agent built in Dart. It understands, navigates, and modifies codebases through structured tool execution, with an explicit permission gate at every destructive boundary and zero required cloud dependency.

The full product specification is in `SPECS.md` — read it before making significant architectural decisions.

## Commands

```bash
# Run the app
dart run bin/proxima.dart

# Run all tests
dart test

# Run a single test file
dart test test/some_test.dart

# Run tests matching a name pattern
dart test --name "pattern"

# Analyze code (lint)
dart analyze

# Format code
dart format .
```

## Architecture

Proxima is structured as **nine explicit layers** with strict boundaries — layers never skip:

```
1. CLI Entry          → dart:io, args, config
2. Session Manager    → history, state, undo (stateful source of truth)
3. Agent Loop         → think → act → observe (stateless, reads/writes session)
4. Provider Interface → unified LLM abstraction (cloud + local adapters)
5. Permission Gate    → safe/confirm/high-risk classification (load-bearing)
6. Tool System        → file, shell, search, git tools
7. Context Manager    → token budget, compaction, project index
8. Error Handler      → retry, recovery, escalation taxonomy
9. Renderer           → ANSI, diffs, interactive prompts
```

**Critical constraint:** The agent loop (Layer 3) never touches the filesystem or executes tools directly. Every tool call goes through `permissionGate.evaluate()` (Layer 5) first, then `toolSystem.execute()` (Layer 6). This is load-bearing architecture.

**Session statefulness:** The agent loop is stateless by design. All state lives in `ProximaSession`. Sessions auto-save to `~/.proxima/sessions/<session_id>.json` after every turn.

## Design Principles (priority-ordered)

1. Safety over speed — no file modified without auditable approval
2. Predictability over intelligence — deterministic loops, strict schemas
3. Local-first, cloud-optional — must work fully offline with a local model
4. Composability over completeness — small sharp tools, pluggable
5. Transparency at every step — show reasoning, diffs, costs, token usage

## Key Implementation Details

### LLM Response Schema
Every LLM response must be one of four types: `tool_call`, `final`, `clarify`, or `error`. The schema validator rejects malformed responses and re-prompts (max 2 retries). The `reasoning` field is **required** on `tool_call` responses.

### Permission Gate Risk Levels
- `safe` — auto-execute (read_file, list_files, search, git status)
- `confirm` — show diff + y/n/e/s prompt (write_file, run_command, run_tests)
- `high_risk` — require typed "CONFIRM" (delete_file, git reset --hard)
- `blocked` — hard reject before prompt, no override (path traversal, rm -rf /, curl|sh, sudo)

### Tool Contract
All tools implement `ProximaTool` abstract class with `name`, `description`, `riskLevel`, `inputSchema`, `execute()`, and `dryRun()`. Tools enforce working-directory isolation via `isSafePath()` before execution.

### Context Manager Token Budget
Budget percentages scale automatically from the active model's context window: system prompt (3%), project index (2%), active files (18%), conversation history (35%), tool results (18%), output headroom (10%), safety margin (14%).

### Agent Loop Constraints
- Max iterations per request: 10 (configurable)
- Stuck detection: 3 identical tool calls in a row → show stuck dialog
- Max retries on tool error: 3; on LLM error: 2; on schema violation: 2 (fixed)

### Plan Mode (Shift+Tab Toggle)
Pressing `Shift+Tab` at the REPL prompt toggles plan mode. While active the prompt shows `❯ [plan]` and every submission is routed through `_runPlan()` (same as `/plan <task>`): the agent researches in `safe` mode, writes `.proxima/plan.md`, and shows a `y/N` approval prompt before executing. Press `Shift+Tab` again to return to normal mode. The `/plan <task>` slash command continues to work unchanged.

## Configuration

User config: `~/.proxima/config.yaml`
Project-level override: `.proxima/config.yaml` (takes precedence)
Sessions stored: `~/.proxima/sessions/`
Audit log: `~/.proxima/audit.jsonl` (append-only, every permission decision)

**Config precedence:** project YAML → user YAML → environment. A key in YAML
overrides `ANTHROPIC_API_KEY` / `OLLAMA_BASE_URL` from the environment.

**Secret masking (`lib/core/secret_masker.dart`):** tool arguments are masked
(`***`) before being written to the audit log and session files — see SPECS
§15.3.1. Masking is applied **only inside `toJson()` / `record()`**, never to the
live in-memory session: `AnthropicProvider` sends `Message.toolInput` to the API
and `Compaction` reads `toolInput['path']`, so masking in memory would break
both. Terminal output is intentionally unmasked so the confirm prompt shows the
real command. Tool *results* are intentionally unmasked so `--resume` replays
correctly.

## MVP Checklist

Before a feature is considered complete, verify against the MVP checklist in `SPECS.md` Section 18. All items must pass end-to-end.

## Dart Package Dependencies

Key packages from `SPECS.md` Section 17:
- `args` — CLI argument parsing
- `http` + `eventsource` — provider HTTP/SSE
- `dart_console` + `ansi_styles` — terminal rendering
- `diff_match_patch` — unified diff generation/application
- `json_schema` — LLM response schema validation
- `path` — cross-platform path operations, used in `isSafePath()`
- `test` + `mockito` — testing and provider mocking


Changes in any of SPECS.md, README.md, and CLAUDE.md must always agree or synchronize with each other. If you update one, check the others for consistency. The three documents serve different audiences but must tell a coherent story about the project.
The SPECS.md is the primary source of truth. Always update it when new or changing architectural decisions are made.
