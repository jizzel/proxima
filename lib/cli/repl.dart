import 'dart:async';
import 'dart:io';
import '../core/config.dart';
import '../core/cost_calculator.dart';
import '../core/session.dart';
import '../core/session_storage.dart';
import '../core/update_checker.dart';
import '../core/types.dart';
import '../providers/anthropic_provider.dart';
import '../providers/ollama_provider.dart';
import '../providers/openai_provider.dart';
import '../providers/provider_registry.dart';
import '../tools/ignore_matcher.dart';
import '../tools/plugin/plugin_installer.dart';
import '../tools/tool_registry.dart';
import '../tools/file/delete_file_tool.dart';
import '../tools/file/read_file_tool.dart';
import '../tools/file/write_file_tool.dart';
import '../tools/file/patch_file_tool.dart';
import '../tools/file/list_files_tool.dart';
import '../tools/file/glob_tool.dart';
import '../tools/search/search_tool.dart';
import '../tools/search/search_symbol_tool.dart';
import '../tools/search/find_references_tool.dart';
import '../tools/search/get_imports_tool.dart';
import '../tools/plugin/plugin_loader.dart';
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
import '../agent/subagent_runner.dart';
import '../agent/subagent_runner.dart' show SubagentRunner;
import '../renderer/renderer.dart';
import '../renderer/ansi_helpers.dart';
import '../renderer/picker_widget.dart';
import 'arg_parser.dart';
import 'readline.dart';
import 'slash_commands.dart';
import 'package:path/path.dart' as p;

enum _PlanDecision { execute, edit, skip }

enum _ReplMode { normal, plan, acceptEdits }

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
  _ReplMode _replMode = _ReplMode.normal;
  late final ReadLine _readline;

  /// Ollama model list, fetched once at startup (best-effort).
  List<String> _ollamaModels = [];
  List<String> _openaiModels = [];
  List<String> _anthropicModels = [];
  Future<UpdateInfo?>? _updateCheck;

  /// Summaries already generated, keyed by the span of messages they cover, so
  /// repeated compaction of the same history is not paid for repeatedly.
  final Map<String, String> _summaryCache = {};

  /// Shared with the CLI path so both behave identically.
  final PluginInstaller _pluginInstaller = PluginInstaller();
  bool _updateNoticeShown = false;

  ProximaRepl(this._config);

  Future<void> initialize({String? resumeSessionId}) async {
    _activeModel = _config.model;
    _contextWindow = _contextWindowForModel(_activeModel);
    _readline = ReadLine.withUserHistory();
    _renderer = Renderer(debug: _config.debug);
    _toolRegistry = await _buildToolRegistry();

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
              final providerRegistry = _buildProviderRegistry();
              final provider = providerRegistry.create(_activeModel);
              final runner = SubagentRunner(provider: provider);
              final content =
                  toolCall.args['content'] as String? ??
                  toolCall.args['patch'] as String? ??
                  '';
              return runner.runCritic(
                tool: toolCall.tool,
                // The critic was given content with no target, so it reported
                // changes as "lacking a file path" while the confirm panel
                // displayed that very path directly above.
                path: toolCall.args['path'] as String?,
                diffOrContent: content,
                model: _activeModel,
              );
            }
          : null,
    );

    _sessionStorage = SessionStorage.forCurrentUser();
    _slashCommands = SlashCommandHandler(
      _renderer,
      ollamaBaseUrl: _config.ollamaBaseUrl,
      openaiBaseUrl: _config.openaiBaseUrl,
      openaiApiKey: _config.openaiApiKey,
    );

    // Load or create session.
    if (resumeSessionId != null) {
      final loaded = await _sessionStorage.load(resumeSessionId);
      if (loaded == null) {
        // Silently starting a blank session hid typo'd ids and made a user
        // believe their history had been restored when it had not.
        _renderer.printError('  ⚠ Session "$resumeSessionId" not found.');
        _renderer.printDim(
          '  Sessions are stored in ~/.proxima/sessions/. Starting a new one.',
        );
      }
      _session = loaded ?? ProximaSession.create(_config);
    } else {
      _session = ProximaSession.create(_config);
    }

    // Sync permission gate mode to the resumed session's mode.
    // A session may have had its mode changed at runtime via /mode; the saved
    // mode takes precedence over the config default.
    if (_session.mode != _config.mode) {
      _permissionGate.mode = _session.mode;
    }

    // Push initial status to renderer.
    _renderer.updateStatus(
      model: _activeModel,
      mode: _session.mode,
      planMode: _replMode == _ReplMode.plan,
      acceptEditsMode: _replMode == _ReplMode.acceptEdits,
    );

    // Pre-fetch model lists in background (non-fatal).
    _fetchOllamaModels();
    _fetchOpenaiModels();
    _fetchAnthropicModels();
    _fetchUpdateInfo();
  }

  /// Single source for provider credentials.
  ///
  /// Both the agent loop and the write critic create providers; building the
  /// env map in one place stops them drifting apart — the critic previously
  /// omitted the OpenAI keys, so an OpenAI-backed write threw an auth error
  /// before the permission prompt could be shown.
  /// Environment variable that supplies credentials for [model]'s provider,
  /// so an auth failure points at the right one rather than always Anthropic.
  static String _authEnvVarFor(String model) {
    if (model.startsWith('openai/')) return 'OPENAI_API_KEY';
    if (model.startsWith('ollama/')) return 'OLLAMA_BASE_URL';
    return 'ANTHROPIC_API_KEY';
  }

  ProviderRegistry _buildProviderRegistry() => ProviderRegistry(
    env: {
      'ANTHROPIC_API_KEY': _config.anthropicApiKey ?? '',
      'OPENAI_API_KEY': _config.openaiApiKey ?? '',
      'OPENAI_BASE_URL': _config.openaiBaseUrl ?? 'https://api.openai.com/v1',
      if (_config.openaiContextWindow != null)
        'OPENAI_CONTEXT_WINDOW': '${_config.openaiContextWindow}',
      'OLLAMA_BASE_URL': _config.ollamaBaseUrl ?? 'http://localhost:11434',
    },
  );

  /// Background version check. Fire-and-forget like the model prefetches: a
  /// failure must never surface, and startup must never wait on the network.
  void _fetchUpdateInfo() {
    if (!_config.checkForUpdates) return;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return;
    // Keep the future rather than only its result: startup must not wait on
    // the network, but reading a field once immediately after firing the
    // request would almost always see null and silently drop the notice.
    _updateCheck = UpdateChecker(
      currentVersion: proximaVersion,
      homeDir: home,
    ).check().catchError((_) => null);
  }

  /// Shows the update notice, if one arrived, and handles the reply.
  ///
  /// Deliberately never installs: Proxima has filesystem and shell access, so
  /// self-replacing its binary would turn a compromised release channel into
  /// remote code execution. The user is given the command to run.
  /// [waitForResult] awaits the in-flight check (bounded), used at the first
  /// prompt where a brief pause is invisible; elsewhere it peeks without
  /// blocking. The check is never awaited before the header — startup must not
  /// wait on the network.
  Future<void> _maybeShowUpdateNotice({bool waitForResult = false}) async {
    if (_updateNoticeShown) return;
    final pending = _updateCheck;
    if (pending == null) return;

    final UpdateInfo? update;
    if (waitForResult) {
      update = await pending.timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
    } else {
      // Non-blocking peek: yields null unless the future already completed.
      update = await Future.any([pending, Future<UpdateInfo?>.value(null)]);
    }
    if (update == null) return;

    _updateNoticeShown = true;
    _updateCheck = null;

    _renderer.print('');
    _renderer.print(
      '  ↑ Proxima ${update.latestVersion} is available '
      '(you have ${update.currentVersion})',
    );
    _renderer.printDim(
      '    [i] install command   [s] skip this version   '
      '[l] remind me later   [Enter] continue',
    );

    final answer = (stdin.hasTerminal ? stdin.readLineSync() : '')
        ?.trim()
        .toLowerCase();

    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final checker = UpdateChecker(
      currentVersion: proximaVersion,
      homeDir: home,
    );

    switch (answer) {
      case 'i':
        _renderer.print('');
        _renderer.print('  ${update.installCommand}');
        _renderer.printDim('    Run this in a shell, then restart proxima.');
      case 's':
        await checker.skipVersion(update.latestVersion);
        _renderer.printDim('    Skipping ${update.latestVersion}.');
      case 'l':
        await checker.remindLater();
        _renderer.printDim('    Will check again next time.');
      default:
        break;
    }
    _renderer.print('');
  }

  void _fetchOpenaiModels() {
    final apiKey = _config.openaiApiKey;
    if (apiKey == null || apiKey.isEmpty) return;
    OpenAIProvider(
          model: '',
          apiKey: apiKey,
          baseUrl: _config.openaiBaseUrl ?? 'https://api.openai.com/v1',
        )
        .listModels()
        .then((models) => _openaiModels = models)
        .catchError((_) => <String>[]); // silently ignore if unreachable
  }

  void _fetchAnthropicModels() {
    AnthropicProvider(model: '', apiKey: '')
        .listModels()
        .then((models) => _anthropicModels = models)
        .catchError((_) => <String>[]);
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

    final providerRegistry = _buildProviderRegistry();

    final provider = providerRegistry.create(
      _activeModel,
      fallbackModel: _config.fallbackModel,
    );
    // Update with the exact value from the provider (may differ from estimate).
    _contextWindow = provider.capabilities.contextWindow;
    final contextBuilder = ContextBuilder(
      _toolRegistry,
      contextWindow: _contextWindow,
      // Summarise history that compaction has to drop, rather than losing it
      // outright. Uses the active model; a failure falls back to truncation.
      summarizer: _config.summarizeOnCompact
          ? (dropped) async {
              // Cache per session: the agent loop rebuilds context on every
              // iteration from the same history, so without this a
              // 10-iteration turn pays for 10 near-identical summaries.
              final key = _summaryCacheKey(dropped);
              final cached = _summaryCache[key];
              if (cached != null) return cached;

              final result = await SubagentRunner(
                provider: provider,
              ).runSummarizer(messages: dropped, model: _activeModel);
              if (result == null) return null;

              // A summarisation request costs real tokens; recording it keeps
              // the session usage and cost report honest.
              _session.recordUsage(result.usage);
              _session.recordCost(
                CostCalculator.compute(_activeModel, result.usage),
              );

              _summaryCache[key] = result.text;
              return result.text;
            }
          : null,
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

  Future<ToolRegistry> _buildToolRegistry() async {
    final registry = ToolRegistry();
    registry.register(ReadFileTool());
    registry.register(WriteFileTool());
    registry.register(PatchFileTool());
    registry.register(DeleteFileTool());
    registry.register(ListFilesTool(matcher: () => registry.ignoreMatcher));
    registry.register(GlobTool(matcher: () => registry.ignoreMatcher));
    registry.register(SearchTool(matcher: () => registry.ignoreMatcher));
    registry.register(SearchSymbolTool(matcher: () => registry.ignoreMatcher));
    registry.register(
      FindReferencesTool(matcher: () => registry.ignoreMatcher),
    );
    registry.register(GetImportsTool());
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

    // Load plugins
    final plugins = await PluginLoader.load(
      _config.pluginDirs,
      _config.workingDir,
    );
    for (final plugin in plugins) {
      if (!registry.contains(plugin.name)) {
        registry.register(plugin);
      }
    }

    return registry;
  }

  /// Identifies a run of dropped messages so an identical run reuses its
  /// summary instead of paying for it again.
  static String _summaryCacheKey(List<Message> dropped) =>
      '${dropped.length}:${dropped.first.content.hashCode}:'
      '${dropped.last.content.hashCode}';

  /// Rebuilds the shared ignore rules for the current turn.
  ///
  /// Re-read each turn so an edited `.gitignore`, a `/ignore` pattern, or a
  /// `/dir` switch takes effect without restarting. Cheap: one small file read.
  Future<void> _refreshIgnoreMatcher() async {
    _toolRegistry.ignoreMatcher = await IgnoreMatcher.forDirectory(
      _config.workingDir,
      sessionPatterns: _session.permissions.ignoredPatterns,
    );
  }

  /// Run one-shot --task mode.
  Future<void> runTask(String task) async {
    try {
      await _refreshIgnoreMatcher();
      _session = await _getAgentLoop().runTurn(_session, task, _renderer);
    } on LLMError catch (e) {
      _renderer.hideSpinner();
      _renderer.printError('  ⚠ ${e.message}');
      if (e.kind == LLMErrorKind.auth) {
        _renderer.printDim(
          '  Set ${_authEnvVarFor(_activeModel)} in your environment or ~/.proxima/config.yaml',
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

    var firstPrompt = true;
    while (_running) {
      // Fired in the background at init; surfaced at the first prompt rather
      // than before the header, so startup is never delayed.
      await _maybeShowUpdateNotice(waitForResult: firstPrompt);
      firstPrompt = false;

      final input = _readline.readLine(
        prompt: _promptString(),
        statusTip: _modeTip(),
        completer: _completer,
        onShiftTab: _cycleReplMode,
      );

      if (input == null) {
        // EOF or Ctrl-C — exit gracefully.
        break;
      }

      // Shift+Tab was pressed — mode toggled, re-prompt.
      if (input == ReadLine.shiftTabSentinel) continue;

      final trimmed = input.trim();
      if (trimmed.isEmpty) continue;

      // Refresh before dispatch, not after: `/plan` and `/execute` run agent
      // turns from inside handle(), so a later refresh would leave them using
      // the defaults-only matcher.
      await _refreshIgnoreMatcher();

      final wasCommand = await _slashCommands.handle(
        trimmed,
        _session,
        () => _clearTerminal(),
        (model) => _switchModel(model),
        () => _running = false,
        ollamaModels: _ollamaModels,
        openaiModels: _openaiModels,
        onModeSwitch: (mode) => _switchMode(mode),
        contextWindow: _contextWindow,
        onDebugSwitch: (debug) => _switchDebug(debug),
        debugState: _config.debug,
        toolRegistry: _toolRegistry,
        onDirSwitch: (dir) => _switchDir(dir),
        sessionStorage: _sessionStorage,
        onPlanApproved: (task) => _dispatchPlan(task),
        pluginInstaller: _pluginInstaller,
      );

      if (wasCommand) continue;
      if (!_running) break;

      // In plan mode, every prompt is treated as a /plan task.
      if (_replMode == _ReplMode.plan) {
        await _runPlan(trimmed);
        continue;
      }

      final beforeTurn = DateTime.now();
      try {
        _session = await _getAgentLoop().runTurn(_session, trimmed, _renderer);
      } on LLMError catch (e) {
        _renderer.hideSpinner();
        _renderer.printError('  ⚠ ${e.message}');
        if (e.kind == LLMErrorKind.auth) {
          _renderer.printDim(
            '  Set ${_authEnvVarFor(_activeModel)} in your environment or ~/.proxima/config.yaml',
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

      // If write_plan was called during this turn, show the approval picker.
      await _maybeShowPlanPicker(beforeTurn);

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
        '/plugin',
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
        for (final m in _anthropicModels) 'anthropic/$m',
        for (final m in _openaiModels) 'openai/$m',
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
    _renderer.updateStatus(model: model);
    _printCurrentHeader();
    // Persist the new default so future sessions start with this model.
    ProximaConfig.saveDefaultModel(model).catchError(
      (e) => _renderer.printDim('  Warning: could not save default model: $e'),
    );
  }

  /// Returns the known context window for [model] without creating a provider
  /// (avoids requiring API key just to show /context output).
  int _contextWindowForModel(String model) {
    if (model.startsWith('anthropic/')) return 200000;
    if (model.startsWith('ollama/')) return 32768;
    if (model.startsWith('openai/')) {
      // Derived per model — an OpenAI-compatible endpoint may serve 4K or 8K
      // models, and over-reporting makes requests fail as the session grows.
      return _config.openaiContextWindow ??
          OpenAIProvider.contextWindowFor(model.substring('openai/'.length));
    }
    return 8192; // unknown provider — assume the smallest window in common use
  }

  void _switchMode(SessionMode mode) {
    _config = _config.copyWith(mode: mode);
    _permissionGate.mode = mode;
    // Keep session in sync so the mode is persisted on save/resume.
    _session.mode = mode;
    _renderer.updateStatus(mode: mode);
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

  /// Arrow-key picker shown after the plan is displayed.
  /// Returns the user's decision. Defaults to [_PlanDecision.skip] on Escape/Ctrl-C.
  _PlanDecision _planApprovalPicker() {
    const decisions = [
      _PlanDecision.execute,
      _PlanDecision.edit,
      _PlanDecision.skip,
    ];
    stdout.writeln(dim('  Plan written to .proxima/plan.md'));
    final idx = PickerWidget.pick(
      options: ['Execute', 'Edit', 'Skip'],
      hints: [
        'run the plan now',
        'edit .proxima/plan.md, then run /execute',
        'discard and return to prompt',
      ],
      defaultIndex: 0,
    );
    return decisions[idx];
  }

  void _cycleReplMode() {
    _replMode = switch (_replMode) {
      _ReplMode.normal => _ReplMode.plan,
      _ReplMode.plan => _ReplMode.acceptEdits,
      _ReplMode.acceptEdits => _ReplMode.normal,
    };
    // Sync permission gate mode for accept-edits (auto-approves confirm tools).
    _permissionGate.mode = switch (_replMode) {
      _ReplMode.acceptEdits => SessionMode.auto,
      _ => _config.mode,
    };
    _renderer.updateStatus(
      planMode: _replMode == _ReplMode.plan,
      acceptEditsMode: _replMode == _ReplMode.acceptEdits,
    );
    // No print here — tip is shown below the prompt by ReadLine.
  }

  String _promptString() {
    final modeTag = switch (_config.mode) {
      SessionMode.auto => yellow(' auto'),
      SessionMode.safe => green(' safe'),
      SessionMode.confirm => '',
    };
    final replTag = switch (_replMode) {
      _ReplMode.plan => cyan(' [plan]'),
      _ReplMode.acceptEdits => cyan(' [edits]'),
      _ReplMode.normal => '',
    };
    return '\n${cyan(' ❯')}$modeTag$replTag ';
  }

  String? _modeTip() => switch (_replMode) {
    _ReplMode.plan => '  ⏸ plan mode on  (shift+tab to cycle)',
    _ReplMode.acceptEdits => '  ⏵⏵ accept edits on  (shift+tab to cycle)',
    _ReplMode.normal => null,
  };

  /// Dispatches /plan and /execute tasks without blocking the REPL loop.
  /// Called synchronously from the slash command callback; runs async work
  /// after returning by scheduling via the event loop.
  void _dispatchPlan(String task) {
    if (task == '__execute__') {
      unawaited(_handleExecutePlan());
    } else {
      unawaited(_runPlan(task));
    }
  }

  Future<void> _runPlan(String task) async {
    // 1. Run agent in safe mode with plan mode flag set.
    // The renderer drives the spinner via onIterationStart — no manual
    // showSpinner needed here.
    // Suppress the status line that onUsageReport would normally print — we
    // want it to appear *after* the plan content and picker, not before.
    _renderer.suppressNextStatusLine();
    final planConfig = _config.copyWith(mode: SessionMode.safe);
    var planSession = ProximaSession.create(planConfig, isPlanMode: true);

    final beforeTurn = DateTime.now();
    try {
      planSession = await _getAgentLoop().runTurn(planSession, task, _renderer);
    } catch (e) {
      _renderer.hideSpinner();
      _renderer.printError('  ⚠ Plan research failed: $e');
      _renderer.printStatusLine(); // ensure status line still appears
      return;
    }
    _renderer.hideSpinner();

    // 2. Check if .proxima/plan.md was written and show approval picker.
    await _maybeShowPlanPicker(beforeTurn, requirePlan: true);
    // 3. Print status line below the picker (deferred from onUsageReport).
    _renderer.printStatusLine();
  }

  /// If `.proxima/plan.md` was written at or after [since], show the plan
  /// content and the approval picker. When [requirePlan] is true and the file
  /// doesn't exist, print an error.
  Future<void> _maybeShowPlanPicker(
    DateTime since, {
    bool requirePlan = false,
  }) async {
    final planFile = File(p.join(_config.workingDir, '.proxima', 'plan.md'));

    if (!await planFile.exists()) {
      if (requirePlan) {
        _renderer.printError(
          '  Plan was not produced. Try again with more detail.',
        );
      }
      return;
    }

    // Only show picker if the file was written during this turn.
    final modified = await planFile.lastModified();
    if (modified.isBefore(since)) return;

    // 3. Show plan and prompt for approval via arrow-key picker.
    final planText = await planFile.readAsString();
    stdout.writeln('');
    stdout.writeln(planText);
    stdout.writeln('');

    final decision = _planApprovalPicker();
    stdout.writeln('');

    if (decision == _PlanDecision.skip) {
      _renderer.printDim(
        '  Skipped. Plan saved to .proxima/plan.md — run /execute to proceed.',
      );
      return;
    }
    if (decision == _PlanDecision.edit) {
      _renderer.printDim(
        '  Plan saved to .proxima/plan.md — edit it and run /execute to proceed.',
      );
      return;
    }

    // 4. Execute: new normal session running the plan.
    _session = ProximaSession.create(_config);
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
