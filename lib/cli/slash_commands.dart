import 'dart:io';
import '../core/session.dart';
import '../providers/ollama_provider.dart';
import '../renderer/renderer.dart';
import '../renderer/ansi_helpers.dart';

/// Handles /commands typed in the REPL.
class SlashCommandHandler {
  final Renderer _renderer;

  SlashCommandHandler(this._renderer);

  /// Returns true if input was a slash command (consumed).
  /// Returns false if input should be passed to the agent.
  Future<bool> handle(
    String input,
    ProximaSession session,
    void Function() onClear,
    void Function(String model) onModelChange,
    void Function() onExit, {
    List<String> ollamaModels = const [],
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
          await _printModels(session.model, ollamaModels);
        } else {
          onModelChange(rest);
        }
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
  ) async {
    _renderer.print('Current model: $currentModel');
    _renderer.print('');
    _renderer.print('Anthropic models:');
    for (final m in anthropicModels) {
      final full = 'anthropic/$m';
      final marker = full == currentModel ? ' ◀' : '';
      _renderer.printDim('  $full$marker');
    }

    // Use cached list first; fall back to live fetch if cache is empty.
    var models = cachedOllamaModels;
    final ollamaBaseUrl =
        Platform.environment['OLLAMA_BASE_URL'] ?? 'http://localhost:11434';
    if (models.isEmpty) {
      models = await OllamaProvider(
        model: '',
        baseUrl: ollamaBaseUrl,
      ).listModels();
    }

    if (models.isNotEmpty) {
      _renderer.print('');
      _renderer.print('Ollama models (running at $ollamaBaseUrl):');
      for (final m in models) {
        final full = 'ollama/$m';
        final marker = full == currentModel ? ' ◀' : '';
        _renderer.printDim('  $full$marker');
      }
    } else {
      _renderer.printDim('');
      _renderer.printDim('  (Ollama not reachable at $ollamaBaseUrl)');
    }

    _renderer.print('');
    _renderer.printDim('Usage: /model <provider>/<name>');
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
  /clear             Clear conversation history
  /model [name]      Show or switch model
  /undo              Undo last file change
  /allow <tool>      Allow a tool for this session without prompting
  /status            Show session status
  /history [--last N] Show conversation history (optionally last N messages)
''');
  }

  void _handleUndo(ProximaSession session) {
    final lastWriteTask = session.taskHistory.reversed.firstWhere(
      (t) =>
          (t.toolName == 'write_file' || t.toolName == 'patch_file') &&
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
    row('Iterations', session.iterationCount.toString());
    row('Messages', session.history.length.toString());
    row(
      'Tokens',
      '↑${session.cumulativeUsage.inputTokens} ↓${session.cumulativeUsage.outputTokens}',
    );
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
      final preview = _truncateAtWord(msg.content, 80);
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
}
