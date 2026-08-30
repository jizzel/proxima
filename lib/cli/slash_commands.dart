import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;
import '../context/token_budget.dart';
import '../core/cost_calculator.dart';
import '../core/session.dart';
import '../core/session_storage.dart';
import '../core/types.dart';
import '../providers/anthropic_provider.dart';
import '../providers/ollama_provider.dart';
import '../providers/openai_provider.dart';
import '../renderer/renderer.dart';
import '../renderer/ansi_helpers.dart';
import '../renderer/picker_widget.dart';
import '../tools/plugin/plugin_installer.dart';
import '../tools/tool_registry.dart';

/// Handles /commands typed in the REPL.
class SlashCommandHandler {
  final Renderer _renderer;
  final bool Function() _isTty;
  final String _ollamaBaseUrl;
  final String _openaiBaseUrl;
  final String? _openaiApiKey;

  SlashCommandHandler(
    this._renderer, {
    bool Function()? isTty,
    String? ollamaBaseUrl,
    String? openaiBaseUrl,
    String? openaiApiKey,
  }) : _isTty = isTty ?? (() => stdout.hasTerminal),
       _ollamaBaseUrl =
           ollamaBaseUrl ??
           Platform.environment['OLLAMA_BASE_URL'] ??
           'http://localhost:11434',
       _openaiBaseUrl =
           openaiBaseUrl ??
           Platform.environment['OPENAI_BASE_URL'] ??
           'https://api.openai.com/v1',
       _openaiApiKey = openaiApiKey ?? Platform.environment['OPENAI_API_KEY'];

  /// The resolved Ollama base URL this handler will query for model listings.
  /// Injected from `ProximaConfig.ollamaBaseUrl`; falls back to the
  /// `OLLAMA_BASE_URL` environment variable, then to localhost.
  String get ollamaBaseUrl => _ollamaBaseUrl;

  /// Returns true if input was a slash command (consumed).
  /// Returns false if input should be passed to the agent.
  Future<bool> handle(
    String input,
    ProximaSession session,
    void Function() onClear,
    void Function(String model) onModelChange,
    void Function() onExit, {
    List<String> ollamaModels = const [],
    List<String> openaiModels = const [],
    void Function(SessionMode mode)? onModeSwitch,
    int contextWindow = 128000,
    void Function(bool debug)? onDebugSwitch,
    bool debugState = false,
    ToolRegistry? toolRegistry,
    void Function(String dir)? onDirSwitch,
    SessionStorage? sessionStorage,
    void Function(String task)? onPlanApproved,
    PluginInstaller? pluginInstaller,
  }) async {
    final trimmed = input.trim();
    if (!trimmed.startsWith('/')) return false;

    final parts = trimmed.split(RegExp(r'\s+'));
    final command = parts[0].toLowerCase();
    final rest = parts.skip(1).join(' ');

    switch (command) {
      case '/help':
        _printHelp();
      case '/exit':
      case '/quit':
        onExit();
      case '/clear':
        onClear();
      case '/model':
        if (rest.isEmpty) {
          await _printModels(
            session.model,
            ollamaModels,
            onModelChange,
            cachedOpenaiModels: openaiModels,
            openaiApiKey: _openaiApiKey,
          );
        } else {
          onModelChange(rest);
        }
      case '/mode':
        _handleMode(rest, session, onModeSwitch);
      case '/undo':
        _handleUndo(session);
      case '/allow':
        if (rest.isEmpty) {
          _renderer.printDim('Usage: /allow <tool_name>');
        } else {
          session.permissions = session.permissions.withAllowedTool(rest);
          _renderer.print('Allowed tool for this session: $rest');
        }
      case '/status':
        _printStatus(session);
      case '/history':
        _printHistory(session, rest);
      case '/files':
        _printFiles(session);
      case '/context':
        _printContext(contextWindow);
      case '/tools':
        _printTools(toolRegistry);
      case '/plugin':
        await _handlePlugin(rest, pluginInstaller);
      case '/debug':
        _handleDebug(rest, debugState, onDebugSwitch);
      case '/deny':
        if (rest.isEmpty) {
          _renderer.printDim('Usage: /deny <tool_name>');
        } else {
          session.permissions = session.permissions.withDeniedTool(rest);
          _renderer.print('Denied tool for this session: $rest');
        }
      case '/permissions':
        _printPermissions(session);
      case '/dir':
        _handleDir(rest, onDirSwitch);
      case '/ignore':
        if (rest.isEmpty) {
          _renderer.printDim('Usage: /ignore <glob_pattern>');
        } else {
          session.permissions = session.permissions.withIgnoredPattern(rest);
          _renderer.print('Ignoring pattern: $rest');
        }
      case '/snapshot':
        await _handleSnapshot(session, sessionStorage);
      case '/cost':
        await _printCost(session, sessionStorage);
      case '/plan':
        if (rest.isEmpty) {
          _renderer.printError('  Usage: /plan <task description>');
        } else {
          await _handlePlan(rest, onPlanApproved);
        }
      case '/execute':
        await _handleExecute(onPlanApproved);
      default:
        _renderer.printDim(
          'Unknown command: $command. Type /help for commands.',
        );
    }

    return true;
  }

  Future<void> _printModels(
    String currentModel,
    List<String> cachedOllamaModels,
    void Function(String model) onModelSwitch, {
    List<String> cachedOpenaiModels = const [],
    String? openaiApiKey,
  }) async {
    // Use cached lists first; only do a live fetch in interactive (TTY) mode
    // to avoid blocking non-interactive callers (tests, piped output, etc.).
    final problems = <String>[];

    var ollamaModels = cachedOllamaModels;
    if (ollamaModels.isEmpty && _isTty()) {
      final discovery = await OllamaProvider(
        model: '',
        baseUrl: _ollamaBaseUrl,
      ).discoverModels();
      ollamaModels = discovery.models;
      // Ollama being absent is the normal case for a cloud-only user, so it is
      // only worth mentioning when it is configured to somewhere non-default.
      if (!discovery.ok && _ollamaBaseUrl != 'http://localhost:11434') {
        problems.add('Ollama: ${discovery.error}');
      }
    }

    // The cache is deliberately complete (tab completion resolves older ids),
    // so narrow it here for the picker.
    var openaiModels = OpenAIProvider.curate(cachedOpenaiModels);
    if (openaiModels.isEmpty && _isTty()) {
      if (openaiApiKey == null || openaiApiKey.isEmpty) {
        problems.add('OpenAI: no API key (set OPENAI_API_KEY)');
      } else {
        final discovery = await OpenAIProvider(
          model: '',
          apiKey: openaiApiKey,
          baseUrl: _openaiBaseUrl,
        ).discoverModels();
        openaiModels = OpenAIProvider.curate(discovery.models);
        if (!discovery.ok) problems.add('OpenAI: ${discovery.error}');
      }
    }

    // Build the full ordered model list. Anthropic ids come from the provider
    // rather than a hardcoded const so new releases need no code change.
    final anthropicModels = await AnthropicProvider(
      model: '',
      apiKey: '',
    ).listModels().catchError((_) => <String>[]);

    final allModels = [
      for (final m in anthropicModels) 'anthropic/$m',
      for (final m in openaiModels) 'openai/$m',
      for (final m in ollamaModels) 'ollama/$m',
    ];

    // The active model must always be selectable. When its provider's discovery
    // fails it is otherwise absent from its own picker — the running model
    // could not be re-selected after switching away from it.
    if (currentModel.isNotEmpty && !allModels.contains(currentModel)) {
      allModels.insert(0, currentModel);
    }

    // A short list used to be indistinguishable from a failing provider.
    for (final problem in problems) {
      _renderer.printDim('  ⚠ $problem');
    }

    if (allModels.isEmpty) {
      _renderer.printDim('  (No models available)');
      return;
    }

    // Attempt interactive picker; falls back to plain list if not a TTY.
    final picked = _runModelPicker(allModels, currentModel);
    if (picked == null) {
      // User cancelled (Escape) or picker fell back to list-only display.
      return;
    }
    if (picked != currentModel) {
      onModelSwitch(picked);
    }
  }

  /// Shows an interactive arrow-key picker for model selection.
  ///
  /// Returns the selected model string, or null if cancelled (Escape) or if
  /// the terminal is not interactive (in which case the plain list is printed
  /// to stdout as a fallback).
  ///
  /// NOTE: This method is interactive terminal I/O and is therefore tested
  /// manually. The unit tests for `/model` cover only the explicit-argument
  /// path (`/model anthropic/claude-sonnet-4-6`).
  String? _runModelPicker(List<String> models, String currentModel) {
    if (models.isEmpty) return null;

    // Non-interactive fallback: print a plain list when stdout is not a TTY
    // (e.g. during unit tests or when output is piped), or when the terminal is
    // too short to frame even one row between the header and the hint —
    // drawing there would overflow and corrupt the scrollback. A non-TTY can
    // also report a height of 0, so this covers that too.
    if (!_isTty() || Console.scrolling().windowHeight < _minPickerHeight) {
      _renderer.print('Current model: $currentModel');
      _renderer.print('');
      for (final m in models) {
        final marker = m == currentModel ? ' ◀' : '';
        _renderer.printDim('  $m$marker');
      }
      _renderer.print('');
      _renderer.printDim('Usage: /model <provider>/<name>');
      return null;
    }

    final console = Console.scrolling();
    int selected = models.indexOf(currentModel);
    if (selected < 0) selected = 0;

    // Print header + list for the first render (no cursor-up on initial draw).
    stdout.writeln(
      dim('  Select model  ↑/↓ navigate · Enter confirm · Esc cancel'),
    );
    _renderModelList(
      console,
      models,
      selected,
      currentModel,
      firstRender: true,
    );

    while (true) {
      final key = console.readKey();

      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.arrowUp:
            if (selected > 0) {
              selected--;
              _renderModelList(console, models, selected, currentModel);
            }
          case ControlCharacter.arrowDown:
            if (selected < models.length - 1) {
              selected++;
              _renderModelList(console, models, selected, currentModel);
            }
          case ControlCharacter.enter:
            // Clear exactly what was drawn: the visible window, the hint line,
            // and the header. Using the full list length erased unrelated
            // scrollback once the list no longer fit on screen.
            _clearModelList(console, _pickerWindow(console, models.length) + 2);
            return models[selected];
          case ControlCharacter.escape:
          case ControlCharacter.ctrlC:
            _clearModelList(console, _pickerWindow(console, models.length) + 2);
            return null;
          default:
            break;
        }
      }
    }
  }

  /// Redraws the model list in-place using cursor-up sequences.
  ///
  /// [firstRender] must be true on the initial draw to skip the cursor-up
  /// that would otherwise overwrite content above the picker.
  /// Rows the picker will draw, given the terminal height.
  ///
  /// The list must fit on screen: redrawing moved the cursor up by the *full*
  /// list length, so once that exceeded the window the cursor could not return
  /// to the top and every keypress appended another copy instead of
  /// overwriting. With ~90 models the picker filled the scrollback.
  /// The picker occupies `window + 2` rows — a header above and the hint below
  /// — so the window must stay within the terminal or the redraw overflows and
  /// corrupts the scrollback again. The floor is therefore derived from the
  /// actual height, never a fixed minimum: on a 6-row pane a hardcoded 6 rows
  /// would draw 8. One row is still reserved for the prompt where there is room
  /// for it.
  /// Below this the picker cannot draw a header, one row, and the hint, so
  /// `_runModelPicker` prints the plain list instead.
  static const _minPickerHeight = 3;

  static int _pickerWindow(Console console, int modelCount) =>
      pickerWindowFor(console.windowHeight, modelCount);

  /// The arithmetic behind [_pickerWindow], separated from the `Console` so it
  /// can be tested directly at heights a test cannot otherwise produce.
  ///
  /// Invariant: the return value plus two (header and hint) never exceeds
  /// [height], for every height at or above [_minPickerHeight]. Visible for
  /// testing.
  static int pickerWindowFor(int height, int modelCount) {
    // Below four rows there is no room for chrome plus a row; show one and let
    // the position hint carry navigation.
    final usable = height < 4 ? 1 : (height > 6 ? height - 4 : height - 3);
    return modelCount < usable ? modelCount : usable;
  }

  /// Exposed for the regression test that pins the fallback threshold.
  static int get minPickerHeight => _minPickerHeight;

  void _renderModelList(
    Console console,
    List<String> models,
    int selected,
    String current, {
    bool firstRender = false,
  }) {
    final window = _pickerWindow(console, models.length);

    // Scroll the window so the selection stays inside it.
    var start = selected - (window ~/ 2);
    if (start < 0) start = 0;
    if (start > models.length - window) start = models.length - window;
    if (start < 0) start = 0;
    final end = (start + window).clamp(0, models.length);

    // One extra line for the "n more" hint, so the cursor arithmetic matches
    // exactly what was drawn.
    final drawn = (end - start) + 1;
    if (!firstRender) {
      stdout.write('\x1b[${drawn}A');
    }

    for (int i = start; i < end; i++) {
      final isCurrent = models[i] == current;
      final isSelected = i == selected;
      final activeTag = isCurrent ? dim('  (active)') : '';

      String line;
      if (isSelected) {
        // Reverse-video highlight for the focused row.
        line = '\x1b[7m  ▶ ${models[i]}${isCurrent ? '  (active)' : ''}\x1b[0m';
      } else {
        line = '    ${dim(models[i])}$activeTag';
      }
      stdout.write('\r\x1b[K$line\n');
    }

    final hidden = models.length - (end - start);
    final hint = hidden > 0
        ? '  … $hidden more · ${selected + 1}/${models.length}'
        : '  ${selected + 1}/${models.length}';
    stdout.write('\r\x1b[K${dim(hint)}\n');
  }

  /// Moves the cursor up [lineCount] lines and erases each line.
  void _clearModelList(Console console, int lineCount) {
    for (int i = 0; i < lineCount; i++) {
      console.cursorUp();
      console.eraseLine();
    }
  }

  void _printHelp() {
    _renderer.print('''
Slash commands:
  /help              Show this help
  /exit              Exit Proxima
  /clear             Clear terminal display (history preserved)
  /model [name]      Show or switch model
  /mode [safe|confirm|auto]  Show or change permission mode
  /undo              Undo last file change
  /allow <tool>      Allow a tool for this session without prompting
  /status            Show session status
  /history [--last N] Show conversation history (optionally last N messages)
  /files             Show files read/written this session
  /context           Show token budget breakdown
  /tools             List all registered tools with risk levels
  /plugin [list|install <name>|remove <name>]  Manage official plugins
  /debug [on|off]    Show or toggle debug output
  /deny <tool>       Deny a tool for this session
  /permissions       Show current session permissions
  /dir <path>        Switch working directory
  /ignore <pattern>  Exclude a glob pattern from context
  /snapshot          Save a session snapshot
  /cost              Show session and recent session costs
  /plan <task>       Research codebase and produce a plan before executing
  /execute           Execute the saved plan in .proxima/plan.md
''');
  }

  void _handleMode(
    String arg,
    ProximaSession session,
    void Function(SessionMode mode)? onModeSwitch,
  ) {
    if (arg.isEmpty) {
      if (!_isTty()) {
        _renderer.printDim('  mode: ${session.mode.name}');
        return;
      }
      const modes = [SessionMode.safe, SessionMode.confirm, SessionMode.auto];
      const labels = ['safe', 'confirm', 'auto'];
      const hints = [
        'read-only, no writes or commands',
        'approve before writes/commands (default)',
        'agent acts without asking',
      ];
      final currentIdx = modes.indexOf(session.mode).clamp(0, 2);
      final idx = PickerWidget.pick(
        options: labels,
        hints: hints,
        defaultIndex: currentIdx,
      );
      final chosen = modes[idx];
      if (chosen != session.mode) {
        session.mode = chosen;
        onModeSwitch?.call(chosen);
      }
      return;
    }
    final mode = switch (arg) {
      'safe' => SessionMode.safe,
      'confirm' => SessionMode.confirm,
      'auto' => SessionMode.auto,
      _ => null,
    };
    if (mode == null) {
      _renderer.printError('  Unknown mode: $arg. Use safe, confirm, or auto.');
      return;
    }
    session.mode = mode;
    onModeSwitch?.call(mode);
  }

  void _handleUndo(ProximaSession session) {
    final lastWriteTask = session.taskHistory.reversed.firstWhere(
      (t) =>
          (t.toolName == 'write_file' ||
              t.toolName == 'patch_file' ||
              t.toolName == 'delete_file') &&
          t.backupPath != null,
      orElse: () => TaskRecord(
        toolName: '',
        args: {},
        timestamp: DateTime.now(),
        success: false,
      ),
    );

    if (lastWriteTask.toolName.isEmpty || lastWriteTask.backupPath == null) {
      _renderer.printDim('Nothing to undo.');
      return;
    }

    try {
      final backup = File(lastWriteTask.backupPath!);
      final target = lastWriteTask.args['path'] as String? ?? '';
      if (backup.existsSync() && target.isNotEmpty) {
        backup.copySync(target);
        backup.deleteSync();
        _renderer.printSuccess('Undid changes to: $target');
      }
    } catch (e) {
      _renderer.printError('Undo failed: $e');
    }
  }

  void _printStatus(ProximaSession session) {
    void row(String key, String value) {
      _renderer.print('  ${dim(key.padRight(12))} $value');
    }

    _renderer.print('');
    row('Session', session.id);
    row('Model', session.model);
    row('Mode', session.mode.name);
    row('Dir', session.workingDir);
    row('Iterations', session.iterationCount.toString());
    row('Messages', session.history.length.toString());
    row(
      'Tokens',
      '↑${session.cumulativeUsage.inputTokens} ↓${session.cumulativeUsage.outputTokens}',
    );
    if (session.cumulativeCost > 0) {
      row('Cost', CostCalculator.format(session.cumulativeCost));
    }
    _renderer.print('');
  }

  void _printHistory(ProximaSession session, String args) {
    // Parse optional --last N argument.
    int? lastN;
    final lastMatch = RegExp(r'--last\s+(\d+)').firstMatch(args);
    if (lastMatch != null) {
      lastN = int.tryParse(lastMatch.group(1)!);
    }

    var messages = session.history;
    if (lastN != null && lastN > 0) {
      final skip = messages.length > lastN ? messages.length - lastN : 0;
      messages = messages.skip(skip).toList();
    }

    for (final msg in messages) {
      final role = msg.role.name.toUpperCase();
      final preview = _truncateAtWord(msg.content.split('\n').first, 80);
      _renderer.print('[$role] $preview');
    }
  }

  /// Truncates [text] to at most [maxLen] chars at a word boundary,
  /// appending '...' only when truncation occurs.
  String _truncateAtWord(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    // Walk back from maxLen to find a space (word boundary).
    var end = maxLen;
    while (end > 0 && text[end - 1] != ' ') {
      end--;
    }
    // If no space found, fall back to hard cut.
    if (end == 0) end = maxLen;
    return '${text.substring(0, end).trimRight()}...';
  }

  void _printFiles(ProximaSession session) {
    // Collect unique file paths from every file-touching task record.
    // Reads count too: the command is documented as "files read or written",
    // and reporting "No files accessed" after a read_file is simply wrong.
    final seen = <String>{};
    final entries = <(String, String)>[];
    for (final record in session.taskHistory) {
      final label = switch (record.toolName) {
        'write_file' || 'patch_file' => '(modified)',
        'delete_file' => '(deleted)',
        'read_file' => '(read)',
        _ => null,
      };
      if (label != null) {
        final path = record.args['path'] as String?;
        if (path == null) continue;
        if (seen.add(path)) {
          entries.add((path, label));
        } else if (label != '(read)') {
          // A later write supersedes an earlier read of the same file.
          final index = entries.indexWhere((e) => e.$1 == path);
          if (index != -1) entries[index] = (path, label);
        }
      }
    }

    _renderer.print('');
    if (entries.isEmpty) {
      _renderer.printDim('  No files accessed this session.');
    } else {
      _renderer.print('  Files this session:');
      for (final (path, label) in entries) {
        _renderer.print('    ${dim("✎")}  $path        ${dim(label)}');
      }
    }
    _renderer.print('');
  }

  void _printContext(int contextWindow) {
    final budget = TokenBudget.calculate(contextWindow);
    final kb = contextWindow ~/ 1000;

    _renderer.print('');
    _renderer.print('  Token budget  (${kb}k context)');

    void row(String label, int pct, int tokens) {
      final paddedLabel = label.padRight(16);
      final paddedPct = '$pct%'.padLeft(4);
      final formatted = _formatTokenCount(tokens);
      _renderer.print('    ${dim(paddedLabel)} $paddedPct   ~$formatted');
    }

    row('system prompt', 3, budget.systemPrompt);
    row('project index', 2, budget.projectIndex);
    row('active files', 18, budget.activeFiles);
    row('history', 35, budget.conversationHistory);
    row('tool results', 18, budget.toolResults);
    row('output headroom', 10, budget.outputHeadroom);
    row('safety margin', 14, budget.safetyMargin);
    _renderer.print('');
  }

  /// Formats a token count with comma thousands separators.
  String _formatTokenCount(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  /// `/plugin list | install <name> | remove <name>`.
  ///
  /// Shares PluginInstaller with the CLI path so both behave identically.
  /// Installs take effect on the next session start — the tool registry is
  /// built once at init.
  Future<void> _handlePlugin(String rest, PluginInstaller? injected) async {
    final installer = injected ?? PluginInstaller();
    final parts = rest
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final subcommand = parts.isEmpty ? 'list' : parts.first;
    final target = parts.length > 1 ? parts[1] : null;

    switch (subcommand) {
      case 'list':
        await _printPluginList(installer);
      case 'install':
        if (target == null) {
          _renderer.printDim('Usage: /plugin install <name>');
          return;
        }
        try {
          final entry = await installer.install(target);
          _renderer.printSuccess('  Installed ${entry.name} ${entry.version}');
          _renderer.printDim('  Available on the next session start.');
        } on PluginInstallError catch (e) {
          _renderer.printError('  ⚠ ${e.message}');
        }
      case 'remove':
        if (target == null) {
          _renderer.printDim('Usage: /plugin remove <name>');
          return;
        }
        try {
          final removed = await installer.remove(target);
          if (removed) {
            _renderer.printSuccess('  Removed $target');
          } else {
            _renderer.printDim('  Plugin "$target" is not installed.');
          }
        } on PluginInstallError catch (e) {
          // remove() rejects a traversing name; an uncaught throw here escapes
          // the slash handler and ends the session over a typo.
          _renderer.printError('  ⚠ ${e.message}');
        }
      default:
        _renderer.printDim(
          'Usage: /plugin [list | install <name> | remove <name>]',
        );
    }
  }

  Future<void> _printPluginList(PluginInstaller installer) async {
    final installed = await installer.listInstalled();
    final catalog = await installer.fetchCatalog();

    _renderer.print('');
    if (catalog == null) {
      // Offline is not an error — show what the user actually has.
      if (installed.isEmpty) {
        _renderer.printDim('  No plugins installed.  (catalogue unavailable)');
      } else {
        _renderer.print('  Installed plugins:  (catalogue unavailable)');
        for (final name in installed) {
          _renderer.print('    $name');
        }
      }
    } else if (catalog.isEmpty) {
      _renderer.printDim('  No plugins in the catalogue.');
    } else {
      _renderer.print('  Available plugins:');
      for (final entry in catalog) {
        final mark = installed.contains(entry.name) ? '✓' : ' ';
        _renderer.print(
          '    $mark ${entry.name.padRight(18)} ${dim(entry.description)}',
        );
      }
    }
    _renderer.print('');
  }

  void _printTools(ToolRegistry? registry) {
    _renderer.print('');
    if (registry == null) {
      _renderer.printDim('  (no registry available)');
      _renderer.print('');
      return;
    }
    _renderer.print('  tools:');
    for (final tool in registry.all()) {
      final namePad = tool.name.padRight(20);
      final riskPad = tool.riskLevel.name.padRight(10);
      _renderer.print('    $namePad $riskPad ${tool.description}');
    }
    _renderer.print('');
  }

  void _handleDebug(
    String arg,
    bool currentState,
    void Function(bool debug)? onDebugSwitch,
  ) {
    if (arg.isEmpty) {
      _renderer.printDim('  debug: ${currentState ? 'on' : 'off'}');
      return;
    }
    if (arg == 'on' || arg == 'off') {
      onDebugSwitch?.call(arg == 'on');
    } else {
      _renderer.printError('Usage: /debug on|off');
    }
  }

  void _printPermissions(ProximaSession session) {
    final perms = session.permissions;
    _renderer.print('');
    _renderer.print('  Permissions:');
    _renderer.print(
      '    allowed tools:    ${perms.allowedTools.isEmpty ? '(none)' : perms.allowedTools.join(', ')}',
    );
    _renderer.print(
      '    denied tools:     ${perms.deniedTools.isEmpty ? '(none)' : perms.deniedTools.join(', ')}',
    );
    _renderer.print(
      '    ignored patterns: ${perms.ignoredPatterns.isEmpty ? '(none)' : perms.ignoredPatterns.join(', ')}',
    );
    _renderer.print('');
  }

  void _handleDir(String path, void Function(String dir)? onDirSwitch) {
    if (path.isEmpty) {
      _renderer.printDim('Usage: /dir <path>');
      return;
    }
    final resolved = p.canonicalize(path);
    if (!Directory(resolved).existsSync()) {
      _renderer.printError('Directory not found: $path');
      return;
    }
    onDirSwitch?.call(resolved);
  }

  Future<void> _handleSnapshot(
    ProximaSession session,
    SessionStorage? sessionStorage,
  ) async {
    if (sessionStorage == null) {
      _renderer.printDim('  (session storage not available)');
      return;
    }
    try {
      await sessionStorage.save(session);
    } catch (e) {
      _renderer.printError('Snapshot failed: $e');
      return;
    }
    _renderer.printSuccess('Snapshot saved: ${session.id}');
    _renderer.printDim('Resume with: proxima --resume ${session.id}');
  }

  Future<void> _printCost(
    ProximaSession session,
    SessionStorage? sessionStorage,
  ) async {
    _renderer.print('');
    _renderer.print(
      '  Session cost: ${CostCalculator.format(session.cumulativeCost)}',
    );
    if (sessionStorage != null) {
      try {
        final ids = await sessionStorage.listSessionIds();
        final recent = ids.reversed.take(10).toList();
        if (recent.length > 1) {
          _renderer.print('');
          _renderer.print('  Recent sessions:');
          double total = 0;
          for (final id in recent) {
            final s = await sessionStorage.load(id);
            if (s == null) continue;
            total += s.cumulativeCost;
            final marker = id == session.id ? '  ◀ current' : '';
            _renderer.printDim(
              '    ${id.padRight(28)} ${CostCalculator.format(s.cumulativeCost)}$marker',
            );
          }
          _renderer.print('');
          _renderer.print(
            '  Total (last ${recent.length}): ${CostCalculator.format(total)}',
          );
        }
      } catch (_) {}
    }
    _renderer.print('');
  }

  Future<void> _handlePlan(
    String task,
    void Function(String task)? onPlanApproved,
  ) async {
    _renderer.print('');
    _renderer.printDim('  Planning: $task');
    _renderer.printDim('  (safe mode — no writes until you approve)');
    _renderer.print('');
    onPlanApproved?.call(task);
  }

  Future<void> _handleExecute(
    void Function(String task)? onPlanApproved,
  ) async {
    // Signal to the REPL to run the saved plan.
    onPlanApproved?.call('__execute__');
  }
}
