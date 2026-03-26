# Proxima Issues and Improvements Tracker

## [Code Quality] AV-20: Add missing `@override` annotations to subclass methods
**Description**: The Dart analyzer currently reports 2111 issues related to missing `@override` annotations across the codebase (e.g., in `subagent_runner_test.dart`, `slash_commands_test.dart`, `fallback_provider_test.dart`, `renderer.dart`, and many tool implementations).
**Expected Behavior**: All methods and getters that override inherited members should explicitly use the `@override` annotation to maintain clean code and pass `dart analyze` without warnings.
**Suggested Solution**: Run an automated dart fix command or manually add `@override` to the members flagged by the analyzer. Update CI to strictly enforce `dart analyze` with no warnings.

## [Configuration] AV-21: Dart SDK version constraint mismatch
**Description**: Running `dart pub get` initially fails because `pubspec.yaml` specifies `sdk: ^3.11.1`, but users or CI runners may only have `3.11.0` available. This causes a resolution failure and prevents immediate setup.
**Expected Behavior**: The SDK constraint should accurately reflect the true minimum required version for the project. If `3.11.0` works (which it appears to), the constraint should be relaxed to `^3.11.0`.
**Suggested Solution**: Change the SDK constraint in `pubspec.yaml` to `sdk: ^3.11.0` and commit the change, or clearly document the strict `3.11.1` requirement in `README.md` and upgrade CI/dev environments accordingly.

## [Feature] AV-22: Support additional cloud LLM providers (OpenAI, Gemini, Groq, Mistral)
**Description**: The `README.md` (v1.2.0 roadmap) mentions planned support for additional cloud providers like OpenAI, Gemini, Groq, and Mistral, but they are not yet implemented in the `ProviderRegistry`.
**Expected Behavior**: Users should be able to run `proxima --model openai/gpt-4o` or similar, and the application should route the request through the respective API using the configured API keys.
**Suggested Solution**: Add new provider classes implementing the `LLMProvider` interface (e.g., `OpenAIProvider`, `GeminiProvider`) and register them in `lib/providers/provider_registry.dart`.

## [Feature] AV-23: Support additional local providers (LM Studio, llama.cpp)
**Description**: The roadmap outlines support for LM Studio and llama.cpp as local providers in addition to the current Ollama support.
**Expected Behavior**: Users should be able to configure and use these local providers seamlessly.
**Suggested Solution**: Implement adapters for LM Studio and llama.cpp, leveraging the OpenAI-compatible endpoints they expose, and wire them up in `ProviderRegistry`.

## [Bug] AV-24: CLI `--version` flag reports `dev` when run from source
**Description**: Running `dart run bin/proxima.dart --version` outputs `proxima dev` because `proximaVersion` in `bin/proxima.dart` falls back to `dev` if it isn't injected at compile time via `--define=APP_VERSION=...`.
**Expected Behavior**: The version should ideally reflect the version defined in `pubspec.yaml` (e.g., `1.0.1`), even when running uncompiled from source.
**Suggested Solution**: Introduce a build step (using `build_runner` or a custom script) to generate a `version.dart` file from `pubspec.yaml`, or parse `pubspec.yaml` at runtime if running in a development environment.

## [Feature] AV-25: AST-aware search tool
**Description**: The v1.3.0 roadmap details adding an AST-aware search tool to query code structure (functions, classes, imports) without relying solely on regex.
**Expected Behavior**: Proxima should have a new tool (e.g., `ast_search`) allowing the agent to find specific code constructs semantically.
**Suggested Solution**: Implement `AstSearchTool` in `lib/tools/search/`, leveraging the `analyzer` package to parse Dart code (and potentially tree-sitter or similar for other languages), and register it in `ToolRegistry`.

## [Feature] AV-26: Semantic search tool (embeddings-based)
**Description**: The v1.3.0 roadmap includes adding semantic search (embedding-based file retrieval) for navigating large codebases.
**Expected Behavior**: The agent should be able to use a `semantic_search` tool to find code relevant to natural language queries.
**Suggested Solution**: Implement a local embedding pipeline or utilize a provider's embedding API to index the workspace and provide a retrieval tool.

## [Feature] AV-27: Plugin tool support
**Description**: The roadmap mentions the ability to load third-party tools from a `~/.proxima/plugins/` directory.
**Expected Behavior**: Custom user-defined tools placed in the plugins directory should be automatically discovered, registered, and made available to the agent.
**Suggested Solution**: Implement a plugin discovery mechanism in `ToolRegistry` that reads standard tool definitions (e.g., JSON/YAML schemas paired with executable scripts) from the plugins folder.

## [Refactor] AV-28: Ensure `TODO`s and `FIXME`s are tracked
**Description**: The `CONTRIBUTING.md` specifies that no `// TODO` or `// FIXME` comments should be in merged code, and that GitHub issues should be opened instead. Currently, the codebase is mostly clean, but there are old sample hook files containing TODOs (e.g., `.git/hooks/sendemail-validate.sample`) which are harmless, but as the project grows, a mechanism to enforce this is needed.
**Expected Behavior**: The CI pipeline should enforce the rule that no `// TODO` or `// FIXME` comments are introduced into the `lib/` or `test/` directories.
**Suggested Solution**: Add a simple grep check to the `.github/workflows/ci.yml` that fails the build if `// TODO` or `// FIXME` is found in Dart files.
