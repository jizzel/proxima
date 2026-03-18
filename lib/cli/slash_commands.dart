import 'dart:io';
import '../core/session.dart';
import '../providers/ollama_provider.dart';
import '../renderer/renderer.dart';

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
        session.history.clear();
        _renderer.print('Conversation cleared.');
      case '/model':
        if (rest.isEmpty) {
          await _printModels(session.model, ollamaModels);
        } else {
          onModelChange(rest);
          _renderer.print('Switched to model: $rest');
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
        _printHistory(session);
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
  /history           Show conversation history
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
    _renderer.print('''
Session: ${session.id}
Model: ${session.model}
Mode: ${session.mode.name}
Iterations: ${session.iterationCount}
Messages: ${session.history.length}
Tokens: ↑${session.cumulativeUsage.inputTokens} ↓${session.cumulativeUsage.outputTokens}
''');
  }

  void _printHistory(ProximaSession session) {
    for (final msg in session.history) {
      final role = msg.role.name.toUpperCase();
      final preview = msg.content.length > 80
          ? '${msg.content.substring(0, 80)}...'
          : msg.content;
      _renderer.print('[$role] $preview');
    }
  }
}
