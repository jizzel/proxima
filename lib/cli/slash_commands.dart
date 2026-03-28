import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;
import '../context/token_budget.dart';
import '../core/cost_calculator.dart';
import '../core/session.dart';
import '../core/session_storage.dart';
import '../core/types.dart';
import '../providers/ollama_provider.dart';
import '../renderer/renderer.dart';
import '../renderer/ansi_helpers.dart';
import '../renderer/picker_widget.dart';
import '../tools/tool_registry.dart';

/// Handles /commands typed in the REPL.
class SlashCommandHandler {
  final Renderer _renderer;
  final bool Function() _isTty;

  SlashCommandHandler(this._renderer, {bool Function()? isTty})
      : _isTty = isTty ?? (() => stdout.hasTerminal);

  /// Returns true if input was a slash command (consumed).
  /// Returns false if input should be passed to the agent.
  Future<bool> handle(
    String input,
    ProximaSession session,
    void Function() onClear,
    void Function(String model) onModelChange,
    void Function() onExit, {
    List<String> ollamaModels = const [],
    void Function(SessionMode mode)? onModeSwitch,
    int contextWindow = 128000,
    void Function(bool debug)? onDebugSwitch,
    bool debugState = false,
    ToolRegistry? toolRegistry,
    void Function(String dir)? onDirSwitch,
    SessionStorage? sessionStorage,
    void Function(String task)? onPlanApproved,
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
          await _printModels(session.model, ollamaModels, onModelChange);
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
    void Function(String model) onModelSwitch,
  ) async {
    // Use cached list first; only do a live fetch in interactive (TTY) mode
    // to avoid blocking non-interactive callers (tests, piped output, etc.).
    var ollamaModels = cachedOllamaModels;
    if (ollamaModels.isEmpty && _isTty()) {
      final ollamaBaseUrl =
          Platform.environment['OLLAMA_BASE_URL'] ?? 'http://localhost:11434';
      ollamaModels = await OllamaProvider(
        model: '',
        baseUrl: ollamaBaseUrl,
      ).listModels().catchError((_) => <String>[]);
    }

    // Build the full ordered model list.
    final allModels = [
      for (final m in anthropicModels) 'anthropic/$m',
      for (final m in ollamaModels) 'ollama/$m',
    ];

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
    // (e.g. during unit tests or when output is piped).
    if (!_isTty()) {
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
            // Clear the picker (list + header line) before returning.
            _clearModelList(console, models.length + 1);
            return models[selected];
          case ControlCharacter.escape:
          case ControlCharacter.ctrlC:
            _clearModelList(console, models.length + 1);
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
  void _renderModelList(
    Console console,
    List<String> models,
    int selected,
    String current, {
    bool firstRender = false,
  }) {
    // On every call after the first, move the cursor back up to overwrite.
    if (!firstRender && models.isNotEmpty) {
      stdout.write('\x1b[${models.length}A'); // move up N lines
    }

    for (int i = 0; i < models.length; i++) {
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
  }

  /// Moves the cursor up [lineCount] lines and erases each line.
  void _clearModelList(Console console, int lineCount) {
    for (int i = 0; i < lineCount; i++) {
      console.cursorUp();
      console.eraseLine();
    }
  }

  /// Known Anthropic model IDs for listing and tab completion.
  static const anthropicModels = [
    'claude-opus-4-6',
    'claude-sonnet-4-6',
    'claude-haiku-4-5-20251001',
  ];

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
    // Collect unique file paths from file-mutating task records.
    final seen = <String>{};
    final entries = <(String, String)>[];
    for (final record in session.taskHistory) {
      final label = switch (record.toolName) {
        'write_file' || 'patch_file' => '(modified)',
        'delete_file' => '(deleted)',
        _ => null,
      };
      if (label != null) {
        final path = record.args['path'] as String?;
        if (path != null && seen.add(path)) {
          entries.add((path, label));
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
