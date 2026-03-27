import 'dart:io';
import '../core/config.dart';
import '../core/session.dart';
import '../core/session_storage.dart';
import '../core/types.dart';
import '../providers/ollama_provider.dart';
import '../providers/provider_registry.dart';
import '../tools/tool_registry.dart';
import '../tools/file/delete_file_tool.dart';
import '../tools/file/read_file_tool.dart';
import '../tools/file/write_file_tool.dart';
import '../tools/file/patch_file_tool.dart';
import '../tools/file/list_files_tool.dart';
import '../tools/file/glob_tool.dart';
import '../tools/search/search_tool.dart';
import '../tools/search/search_symbol_tool.dart';
import '../tools/agent/write_plan_tool.dart';
import '../tools/shell/run_command_tool.dart';
import '../tools/shell/run_tests_tool.dart';
import '../tools/git/git_status_tool.dart';
import '../tools/git/git_diff_tool.dart';
import '../tools/git/git_log_tool.dart';
import '../tools/git/git_add_tool.dart';
import '../tools/git/git_commit_tool.dart';
import '../tools/git/git_reset_tool.dart';
import '../tools/agent/delegate_tool.dart';
import '../permissions/risk_classifier.dart';
import '../permissions/audit_log.dart';
import '../permissions/permission_gate.dart';
import '../context/context_builder.dart';
import '../agent/agent_loop.dart';
import '../agent/subagent_runner.dart' show SubagentRunner;
import '../renderer/renderer.dart';
import '../renderer/ansi_helpers.dart';
import 'arg_parser.dart';
import 'readline.dart';
import 'slash_commands.dart';
import 'package:path/path.dart' as p;

/// Main REPL loop integrating all layers.
class ProximaRepl {
  ProximaConfig _config;
  late Renderer _renderer;
  late final ToolRegistry _toolRegistry;
  late final PermissionGate _permissionGate;
  late final SessionStorage _sessionStorage;
  late final SlashCommandHandler _slashCommands;
  late ProximaSession _session;

  /// Cached agent loop — reset to null whenever the active model changes.
  AgentLoop? _agentLoop;

  /// The model currently in use (may differ from _config after /model switch).
  late String _activeModel;

  /// Cached context window size. Resolved from the active model at
  /// initialize() time so /context shows the correct value immediately.
  int _contextWindow = 128000;

  bool _running = true;
  bool _planMode = false;
  late final ReadLine _readline;

  /// Ollama model list, fetched once at startup (best-effort).
  List<String> _ollamaModels = [];

  ProximaRepl(this._config);

  Future<void> initialize({String? resumeSessionId}) async {
    _activeModel = _config.model;
    _contextWindow = _contextWindowForModel(_activeModel);
    _readline = ReadLine.withUserHistory();
    _renderer = Renderer(debug: _config.debug);
    _toolRegistry = _buildToolRegistry();

    final auditLog = AuditLog.forCurrentUser();
    final riskClassifier = RiskClassifier(_toolRegistry);

    _permissionGate = PermissionGate(
      classifier: riskClassifier,
      auditLog: auditLog,
      mode: _config.mode,
      allowedTools: {},
      prompt: (toolCall, riskLevel, {criticResult}) => _renderer
          .promptPermission(toolCall, riskLevel, criticResult: criticResult),
      criticCallback: _config.criticOnWrite
          ? (toolCall) async {
              // Critic runs with the active model; runner is created on demand.
              final providerRegistry = ProviderRegistry(
                env: {
                  'ANTHROPIC_API_KEY': _config.anthropicApiKey ?? '',
                  'OLLAMA_BASE_URL':
                      _config.ollamaBaseUrl ?? 'http://localhost:11434',
                },
              );
              final provider = providerRegistry.create(_activeModel);
              final runner = SubagentRunner(provider: provider);
              final content =
                  toolCall.args['content'] as String? ??
                  toolCall.args['patch'] as String? ??
                  '';
              return runner.runCritic(
                tool: toolCall.tool,
                diffOrContent: content,
                model: _activeModel,
              );
            }
          : null,
    );

    _sessionStorage = SessionStorage.forCurrentUser();
    _slashCommands = SlashCommandHandler(_renderer);

    // Load or create session.
    if (resumeSessionId != null) {
      _session =
          await _sessionStorage.load(resumeSessionId) ??
          ProximaSession.create(_config);
    } else {
      _session = ProximaSession.create(_config);
    }

    // Sync permission gate mode to the resumed session's mode.
    // A session may have had its mode changed at runtime via /mode; the saved
    // mode takes precedence over the config default.
    if (_session.mode != _config.mode) {
      _permissionGate.mode = _session.mode;
    }

    // Pre-fetch Ollama model list in background (non-fatal).
    _fetchOllamaModels();
  }

  void _fetchOllamaModels() {
    final baseUrl = _config.ollamaBaseUrl ?? 'http://localhost:11434';
    OllamaProvider(model: '', baseUrl: baseUrl)
        .listModels()
        .then((models) => _ollamaModels = models)
        .catchError(
          (_) => <String>[],
        ); // silently ignore if Ollama isn't running
  }

  /// Lazily creates the agent loop (and provider) on first use.
  /// Defers API key validation until an actual LLM call is needed.
  AgentLoop _getAgentLoop() {
    if (_agentLoop != null) return _agentLoop!;

    final providerRegistry = ProviderRegistry(
      env: {
        'ANTHROPIC_API_KEY': _config.anthropicApiKey ?? '',
        'OLLAMA_BASE_URL': _config.ollamaBaseUrl ?? 'http://localhost:11434',
      },
    );

    final provider = providerRegistry.create(
      _activeModel,
      fallbackModel: _config.fallbackModel,
    );
    // Update with the exact value from the provider (may differ from estimate).
    _contextWindow = provider.capabilities.contextWindow;
    final contextBuilder = ContextBuilder(
      _toolRegistry,
      contextWindow: _contextWindow,
    );

    _agentLoop = AgentLoop(
      provider: provider,
      toolRegistry: _toolRegistry,
      permissionGate: _permissionGate,
      contextBuilder: contextBuilder,
      config: _config.copyWith(model: _activeModel),
    );
    return _agentLoop!;
  }

  ToolRegistry _buildToolRegistry() {
    final registry = ToolRegistry();
    registry.register(ReadFileTool());
    registry.register(WriteFileTool());
    registry.register(PatchFileTool());
    registry.register(DeleteFileTool());
    registry.register(ListFilesTool());
    registry.register(GlobTool());
    registry.register(SearchTool());
    registry.register(SearchSymbolTool());
    registry.register(RunCommandTool());
    registry.register(RunTestsTool());
    // Git tools — safe reads
    registry.register(GitStatusTool());
    registry.register(GitDiffTool());
    registry.register(GitLogTool());
    // Git tools — writes (confirm)
    registry.register(GitAddTool());
    registry.register(GitCommitTool());
    // Git tools — high risk
    registry.register(GitResetTool());
    // Agent tools
    registry.register(DelegateToSubagentTool());
    registry.register(WritePlanTool());
    return registry;
  }

  /// Run one-shot --task mode.
  Future<void> runTask(String task) async {
    try {
      _session = await _getAgentLoop().runTurn(_session, task, _renderer);
    } on LLMError catch (e) {
      _renderer.hideSpinner();
      _renderer.printError('  ⚠ ${e.message}');
      if (e.kind == LLMErrorKind.auth) {
        _renderer.printDim(
          '  Set ANTHROPIC_API_KEY in your environment or ~/.proxima/config.yaml',
        );
      }
      return;
    } catch (e) {
      _renderer.hideSpinner();
      _renderer.printError('  ⚠ Unexpected error: $e');
      return;
    }
    _renderer.hideSpinner();
    await _sessionStorage.save(_session);
  }

  /// Interactive REPL loop.
  Future<void> runRepl() async {
    _printCurrentHeader();

    while (_running) {
      final input = _readline.readLine(
        prompt: _promptString(),
        completer: _completer,
        onShiftTab: _togglePlanMode,
      );

      if (input == null) {
        // EOF or Ctrl-C — exit gracefully.
        break;
      }

      // Shift+Tab was pressed — mode toggled, re-prompt.
      if (input == ReadLine.shiftTabSentinel) continue;

      final trimmed = input.trim();
      if (trimmed.isEmpty) continue;

      final wasCommand = await _slashCommands.handle(
        trimmed,
        _session,
        () => _clearTerminal(),
        (model) => _switchModel(model),
        () => _running = false,
        ollamaModels: _ollamaModels,
        onModeSwitch: (mode) => _switchMode(mode),
        contextWindow: _contextWindow,
        onDebugSwitch: (debug) => _switchDebug(debug),
        debugState: _config.debug,
        toolRegistry: _toolRegistry,
        onDirSwitch: (dir) => _switchDir(dir),
        sessionStorage: _sessionStorage,
        onPlanApproved: (task) => _dispatchPlan(task),
      );

      if (wasCommand) continue;
      if (!_running) break;

      // In plan mode, every prompt is treated as a /plan task.
      if (_planMode) {
        await _runPlan(trimmed);
        continue;
      }

      try {
        _session = await _getAgentLoop().runTurn(_session, trimmed, _renderer);
      } on LLMError catch (e) {
        _renderer.hideSpinner();
        _renderer.printError('  ⚠ ${e.message}');
        if (e.kind == LLMErrorKind.auth) {
          _renderer.printDim(
            '  Set ANTHROPIC_API_KEY in your environment or ~/.proxima/config.yaml',
          );
        }
        _agentLoop = null; // reset so user can switch model and retry
        continue;
      } catch (e) {
        _renderer.hideSpinner();
        _renderer.printError('  ⚠ Unexpected error: $e');
        continue;
      }
      _renderer.hideSpinner();

      await _sessionStorage.save(_session);

      if (_session.status == TaskStatus.failed) {
        _session.status = TaskStatus.running;
        _session.iterationCount = 0;
      }
    }

    await _permissionGate.close();
    stdout.writeln('\n\x1b[2m bye\x1b[0m');
  }

  /// Tab completer — only fires for `/` prefixes to avoid noise during chat.
  List<String> _completer(String buffer) {
    // Only trigger for slash-command input, never for empty or regular chat.
    if (buffer.isEmpty || !buffer.startsWith('/')) return [];

    // Complete slash commands (no space yet = still typing the command name).
    if (!buffer.contains(' ')) {
      const commands = [
        '/help',
        '/exit',
        '/clear',
        '/model',
        '/mode',
        '/undo',
        '/allow',
        '/status',
        '/history',
        '/files',
        '/context',
        '/tools',
        '/debug',
        '/deny',
        '/permissions',
        '/dir',
        '/ignore',
        '/snapshot',
        '/cost',
        '/plan',
        '/execute',
      ];
      // Only show suggestions once at least one char after '/' is typed.
      if (buffer.length < 2) return [];
      return commands.where((c) => c.startsWith(buffer)).toList();
    }

    // Complete model names after "/model ".
    if (buffer.startsWith('/model ')) {
      final partial = buffer.substring('/model '.length);
      // Only offer completions when the user has started typing a partial name.
      // When the buffer is exactly "/model " (no partial), pressing Enter opens
      // the interactive picker which fetches a complete list — show nothing
      // in the panel so as not to show an incomplete set.
      if (partial.isEmpty) return [];
      final allModels = [
        for (final m in SlashCommandHandler.anthropicModels) 'anthropic/$m',
        for (final m in _ollamaModels) 'ollama/$m',
      ];
      return allModels
          .where((m) => m.startsWith(partial))
          .map((m) => '/model $m')
          .toList();
    }

    return [];
  }

  void _printCurrentHeader() {
    _renderer.printHeader(
      model: _activeModel,
      workingDir: _config.workingDir,
      version: proximaVersion,
    );
  }

  void _clearTerminal() {
    stdout.write('\x1b[2J\x1b[H');
    _printCurrentHeader();
  }

  void _switchModel(String model) {
    _activeModel = model;
    _config = _config.copyWith(model: model);
    _agentLoop = null; // force re-creation with new provider on next call
    _contextWindow = _contextWindowForModel(model);
    // Carry forward the current mode so a prior /mode change is not lost.
    _session = ProximaSession.create(_config);
    _printCurrentHeader();
    // Persist the new default so future sessions start with this model.
    ProximaConfig.saveDefaultModel(model).catchError(
      (e) => _renderer.printDim('  Warning: could not save default model: $e'),
    );
  }

  /// Returns the known context window for [model] without creating a provider
  /// (avoids requiring API key just to show /context output).
  static int _contextWindowForModel(String model) {
    if (model.startsWith('anthropic/')) return 200000;
    if (model.startsWith('ollama/')) return 32768;
    return 128000; // unknown provider — use conservative default
  }

  void _switchMode(SessionMode mode) {
    _config = _config.copyWith(mode: mode);
    _permissionGate.mode = mode;
    // Keep session in sync so the mode is persisted on save/resume.
    _session.mode = mode;
    _renderer.printSuccess('  Mode: ${mode.name}');
  }

  void _switchDebug(bool debug) {
    _config = _config.copyWith(debug: debug);
    _renderer = Renderer(debug: debug);
    _renderer.printSuccess('  Debug: ${debug ? 'on' : 'off'}');
  }

  void _switchDir(String dir) {
    _config = _config.copyWith(workingDir: dir);
    _session = ProximaSession.create(_config);
    _agentLoop = null;
    _renderer.printSuccess('  Working dir: $dir');
  }

  void _togglePlanMode() {
    _planMode = !_planMode;
    if (_planMode) {
      _renderer.printSuccess('  Plan mode  ON   ❯ [plan]');
      _renderer.printDim('  Every prompt researches + asks approval before writing.');
    } else {
      _renderer.printSuccess('  Plan mode  OFF  ❯');
      _renderer.printDim('  Back to normal — prompts go straight to the agent.');
    }
  }

  String _promptString() {
    final modeTag = switch (_config.mode) {
      SessionMode.auto => yellow(' auto'),
      SessionMode.safe => green(' safe'),
      SessionMode.confirm => '',
    };
    final planTag = _planMode ? cyan(' [plan]') : '';
    // Colored prompt: "  ❯ " in cyan, mode/plan tags if set.
    return '\n${cyan(' ❯')}$modeTag$planTag ';
  }

  /// Dispatches /plan and /execute tasks without blocking the REPL loop.
  /// Called synchronously from the slash command callback; runs async work
  /// after returning by scheduling via the event loop.
  void _dispatchPlan(String task) {
    if (task == '__execute__') {
      _handleExecutePlan();
    } else {
      _runPlan(task);
    }
  }

  Future<void> _runPlan(String task) async {
    // 1. Run agent in safe mode with plan mode flag set.
    final planConfig = _config.copyWith(mode: SessionMode.safe);
    var planSession = ProximaSession.create(planConfig, isPlanMode: true);

    _renderer.showSpinner('Researching…');
    try {
      planSession = await _getAgentLoop().runTurn(planSession, task, _renderer);
    } catch (e) {
      _renderer.hideSpinner();
      _renderer.printError('  ⚠ Plan research failed: $e');
      return;
    }
    _renderer.hideSpinner();

    // 2. Check if .proxima/plan.md was written.
    final planFile = File(p.join(_config.workingDir, '.proxima', 'plan.md'));
    if (!await planFile.exists()) {
      _renderer.printError(
        '  Plan was not produced. Try again with more detail.',
      );
      return;
    }

    // 3. Show plan and prompt for approval.
    final planText = await planFile.readAsString();
    stdout.writeln('');
    stdout.writeln(planText);
    stdout.writeln('');
    stdout.write('  Execute this plan? [y/N] ');

    final line = stdin.readLineSync() ?? '';
    stdout.writeln('');

    if (line.trim().toLowerCase() != 'y') {
      _renderer.printDim(
        '  Plan saved to .proxima/plan.md — edit it and run /execute to proceed.',
      );
      return;
    }

    // 4. Execute: new normal session running the plan.
    _session = ProximaSession.create(_config);
    _renderer.showSpinner('Executing…');
    try {
      _session = await _getAgentLoop().runTurn(
        _session,
        'Execute the plan in .proxima/plan.md step by step.',
        _renderer,
      );
    } catch (e) {
      _renderer.hideSpinner();
      _renderer.printError('  ⚠ Execution failed: $e');
      return;
    }
    _renderer.hideSpinner();
    await _sessionStorage.save(_session);
  }

  Future<void> _handleExecutePlan() async {
    final planFile = File(p.join(_config.workingDir, '.proxima', 'plan.md'));
    if (!await planFile.exists()) {
      _renderer.printError(
        '  No plan found. Run /plan <task> first to create one.',
      );
      return;
    }

    _session = ProximaSession.create(_config);
    _renderer.showSpinner('Executing plan…');
    try {
      _session = await _getAgentLoop().runTurn(
        _session,
        'Execute the plan in .proxima/plan.md step by step.',
        _renderer,
      );
    } catch (e) {
      _renderer.hideSpinner();
      _renderer.printError('  ⚠ Execution failed: $e');
      return;
    }
    _renderer.hideSpinner();
    await _sessionStorage.save(_session);
  }
}
