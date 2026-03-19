import 'dart:io';
import '../core/config.dart';
import '../core/session.dart';
import '../core/session_storage.dart';
import '../core/types.dart';
import '../providers/ollama_provider.dart';
import '../providers/provider_registry.dart';
import '../tools/tool_registry.dart';
import '../tools/file/read_file_tool.dart';
import '../tools/file/write_file_tool.dart';
import '../tools/file/patch_file_tool.dart';
import '../tools/file/list_files_tool.dart';
import '../tools/file/glob_tool.dart';
import '../tools/search/search_tool.dart';
import '../tools/shell/run_command_tool.dart';
import '../tools/shell/run_tests_tool.dart';
import '../permissions/risk_classifier.dart';
import '../permissions/audit_log.dart';
import '../permissions/permission_gate.dart';
import '../context/context_builder.dart';
import '../agent/agent_loop.dart';
import '../renderer/renderer.dart';
import '../renderer/ansi_helpers.dart';
import 'arg_parser.dart';
import 'readline.dart';
import 'slash_commands.dart';

/// Main REPL loop integrating all layers.
class ProximaRepl {
  ProximaConfig _config;
  late final Renderer _renderer;
  late final ToolRegistry _toolRegistry;
  late final PermissionGate _permissionGate;
  late final SessionStorage _sessionStorage;
  late final SlashCommandHandler _slashCommands;
  late ProximaSession _session;

  /// Cached agent loop — reset to null whenever the active model changes.
  AgentLoop? _agentLoop;

  /// The model currently in use (may differ from _config after /model switch).
  late String _activeModel;

  /// Cached context window size — set when agent loop is first created.
  int _contextWindow = 128000;

  bool _running = true;
  late final ReadLine _readline;

  /// Ollama model list, fetched once at startup (best-effort).
  List<String> _ollamaModels = [];

  ProximaRepl(this._config);

  Future<void> initialize({String? resumeSessionId}) async {
    _activeModel = _config.model;
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
      prompt: (toolCall, riskLevel) =>
          _renderer.promptPermission(toolCall, riskLevel),
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

    final provider = providerRegistry.create(_activeModel);
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
    registry.register(ListFilesTool());
    registry.register(GlobTool());
    registry.register(SearchTool());
    registry.register(RunCommandTool());
    registry.register(RunTestsTool());
    return registry;
  }

  /// Run one-shot --task mode.
  Future<void> runTask(String task) async {
    _renderer.showSpinner('Thinking...');
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
      );

      if (input == null) {
        // EOF or Ctrl-C — exit gracefully.
        break;
      }

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
      );

      if (wasCommand) continue;
      if (!_running) break;

      _renderer.showSpinner('Thinking...');
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
      ];
      // Only show suggestions once at least one char after '/' is typed.
      if (buffer.length < 2) return [];
      return commands.where((c) => c.startsWith(buffer)).toList();
    }

    // Complete model names after "/model ".
    if (buffer.startsWith('/model ')) {
      final partial = buffer.substring('/model '.length);
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
    _agentLoop = null; // force re-creation with new provider on next call
    _session = ProximaSession.create(_config.copyWith(model: model));
    _printCurrentHeader();
  }

  void _switchMode(SessionMode mode) {
    _config = _config.copyWith(mode: mode);
    _permissionGate.mode = mode;
    _renderer.printSuccess('  Mode: ${mode.name}');
  }

  String _promptString() {
    final modeTag = switch (_config.mode) {
      SessionMode.auto => yellow(' auto'),
      SessionMode.safe => green(' safe'),
      SessionMode.confirm => '',
    };
    // Colored prompt: "  ❯ " in cyan, mode tag if set.
    return '\n${cyan(' ❯')}$modeTag ';
  }
}
