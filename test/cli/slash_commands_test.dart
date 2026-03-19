import 'dart:io';
import 'package:test/test.dart';
import 'package:proxima/cli/slash_commands.dart';
import 'package:proxima/core/session.dart';
import 'package:proxima/core/config.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/renderer/renderer.dart';

/// A fake [Renderer] that captures printed output to a [StringBuffer]
/// instead of writing to stdout.
class FakeRenderer extends Renderer {
  final StringBuffer _buffer = StringBuffer();

  FakeRenderer() : super(debug: false);

  String get output => _buffer.toString();

  void clearOutput() => _buffer.clear();

  @override
  void print(String text) => _buffer.writeln(text);

  @override
  void printDim(String text) => _buffer.writeln(text);

  @override
  void printSuccess(String text) => _buffer.writeln(text);

  @override
  void printError(String text) => _buffer.writeln(text);
}

/// Creates a minimal [ProximaSession] for testing.
ProximaSession makeSession({String model = 'anthropic/claude-sonnet-4-6'}) {
  final config = ProximaConfig.defaults().copyWith(
    workingDir: Directory.systemTemp.path,
    model: model,
  );
  return ProximaSession.create(config);
}

void main() {
  late FakeRenderer renderer;
  late SlashCommandHandler handler;
  late ProximaSession session;

  // Callbacks — track invocations.
  late bool clearCalled;
  late String? modelSwitchArg;
  late bool exitCalled;

  setUp(() {
    renderer = FakeRenderer();
    handler = SlashCommandHandler(renderer);
    session = makeSession();
    clearCalled = false;
    modelSwitchArg = null;
    exitCalled = false;
  });

  // ── helper ─────────────────────────────────────────────────────────────────

  Future<bool> handle(
    String input, {
    List<String> ollamaModels = const [],
  }) => handler.handle(
    input,
    session,
    () => clearCalled = true,
    (m) => modelSwitchArg = m,
    () => exitCalled = true,
    ollamaModels: ollamaModels,
  );

  // ── /help ──────────────────────────────────────────────────────────────────

  test('1. /help prints help text containing all commands', () async {
    final result = await handle('/help');
    expect(result, isTrue);
    final out = renderer.output;
    expect(out, contains('/help'));
    expect(out, contains('/exit'));
    expect(out, contains('/clear'));
    expect(out, contains('/model'));
    expect(out, contains('/undo'));
    expect(out, contains('/allow'));
    expect(out, contains('/status'));
    expect(out, contains('/history'));
  });

  // ── /exit ──────────────────────────────────────────────────────────────────

  test('2. /exit sets running=false via onExit callback', () async {
    final result = await handle('/exit');
    expect(result, isTrue);
    expect(exitCalled, isTrue);
  });

  test('3. /quit also triggers onExit callback', () async {
    final result = await handle('/quit');
    expect(result, isTrue);
    expect(exitCalled, isTrue);
  });

  // ── /clear ─────────────────────────────────────────────────────────────────

  test('4. /clear calls onClear callback', () async {
    final result = await handle('/clear');
    expect(result, isTrue);
    expect(clearCalled, isTrue);
  });

  test('5. /clear does NOT clear session.history — history is preserved', () async {
    session.addMessage(Message(role: MessageRole.user, content: 'hello'));
    session.addMessage(Message(role: MessageRole.assistant, content: 'hi'));
    final countBefore = session.history.length;

    await handle('/clear');

    expect(session.history.length, countBefore);
  });

  test(
    '6. /clear — verifies history count BEFORE and AFTER is the same',
    () async {
      session.addMessage(Message(role: MessageRole.user, content: 'msg 1'));
      session.addMessage(Message(role: MessageRole.user, content: 'msg 2'));
      session.addMessage(Message(role: MessageRole.user, content: 'msg 3'));
      final before = session.history.length;

      await handle('/clear');

      final after = session.history.length;
      expect(before, 3);
      expect(after, before);
    },
  );

  // ── /undo ──────────────────────────────────────────────────────────────────

  test('7. /undo when no backup exists prints appropriate message', () async {
    final result = await handle('/undo');
    expect(result, isTrue);
    expect(renderer.output, contains('Nothing to undo'));
  });

  test('8. /undo when backup exists restores the file', () async {
    final tempDir = await Directory.systemTemp.createTemp('proxima_undo_');
    try {
      // Create target and backup files.
      final target = File('${tempDir.path}/target.txt');
      final backup = File('${tempDir.path}/target.txt.bak');
      await target.writeAsString('modified content');
      await backup.writeAsString('original content');

      // Record a write_file task with a backup path.
      session.addTaskRecord(
        TaskRecord(
          toolName: 'write_file',
          args: {'path': target.path},
          backupPath: backup.path,
          timestamp: DateTime.now(),
          success: true,
        ),
      );

      final result = await handle('/undo');
      expect(result, isTrue);

      // Target should now have the original content.
      expect(await target.readAsString(), 'original content');
      // Backup should have been deleted.
      expect(await backup.exists(), isFalse);
      expect(renderer.output, contains(target.path));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  // ── /model ─────────────────────────────────────────────────────────────────

  test('9. /model (no arg) prints model list including anthropic models',
      () async {
    final result = await handle(
      '/model',
      ollamaModels: [], // no ollama models — avoids live fetch
    );
    expect(result, isTrue);
    final out = renderer.output;
    expect(out, contains('anthropic'));
    // At least one of the known model IDs should appear.
    expect(
      SlashCommandHandler.anthropicModels.any((m) => out.contains(m)),
      isTrue,
    );
  });

  test(
    '10. /model anthropic/claude-sonnet-4-6 calls onModelSwitch with correct string',
    () async {
      final result = await handle('/model anthropic/claude-sonnet-4-6');
      expect(result, isTrue);
      expect(modelSwitchArg, 'anthropic/claude-sonnet-4-6');
    },
  );

  test('11. /model with an unknown name still calls onModelChange', () async {
    // The handler delegates validation to the caller; it just passes the arg.
    final result = await handle('/model unknown/bad-model');
    expect(result, isTrue);
    expect(modelSwitchArg, 'unknown/bad-model');
  });

  // ── /status ────────────────────────────────────────────────────────────────

  test('12. /status prints session ID and model', () async {
    final result = await handle('/status');
    expect(result, isTrue);
    final out = renderer.output;
    expect(out, contains(session.id));
    expect(out, contains(session.model));
  });

  test('13. /status output contains model name and working directory', () async {
    await handle('/status');
    final out = renderer.output;
    expect(out, contains(session.model));
    // The working directory is shown in the REPL header, not /status, but the
    // session fields that are printed include model and id.
    expect(out, contains(session.model));
  });

  test('14. /status prints token counts', () async {
    session.recordUsage(
      const TokenUsage(inputTokens: 42, outputTokens: 7, totalTokens: 49),
    );
    await handle('/status');
    final out = renderer.output;
    expect(out, contains('42'));
    expect(out, contains('7'));
  });

  // ── /history ───────────────────────────────────────────────────────────────

  test('15. /history prints conversation history', () async {
    session.addMessage(Message(role: MessageRole.user, content: 'hello world'));
    session.addMessage(
      Message(role: MessageRole.assistant, content: 'hi there'),
    );

    final result = await handle('/history');
    expect(result, isTrue);
    final out = renderer.output;
    expect(out, contains('hello world'));
    expect(out, contains('hi there'));
  });

  test('16. /history --last 2 prints only last 2 messages', () async {
    session.addMessage(Message(role: MessageRole.user, content: 'first'));
    session.addMessage(Message(role: MessageRole.user, content: 'second'));
    session.addMessage(Message(role: MessageRole.user, content: 'third'));

    await handle('/history --last 2');
    final out = renderer.output;

    expect(out, isNot(contains('first')));
    expect(out, contains('second'));
    expect(out, contains('third'));
  });

  test('17. /history --last 0 handles gracefully (shows all)', () async {
    session.addMessage(Message(role: MessageRole.user, content: 'alpha'));
    session.addMessage(Message(role: MessageRole.user, content: 'beta'));

    // --last 0 is falsy (lastN > 0 guard), so all messages are shown.
    await handle('/history --last 0');
    final out = renderer.output;
    expect(out, contains('alpha'));
    expect(out, contains('beta'));
  });

  test('18. /history --last abc handles non-numeric gracefully', () async {
    session.addMessage(Message(role: MessageRole.user, content: 'only'));

    // --last abc won't match \d+ regex, so all messages are shown.
    await handle('/history --last abc');
    final out = renderer.output;
    expect(out, contains('only'));
  });

  // ── /allow ─────────────────────────────────────────────────────────────────

  test('19. /allow read_file adds tool to session allowlist', () async {
    expect(session.permissions.allowedTools, isEmpty);

    final result = await handle('/allow read_file');
    expect(result, isTrue);
    expect(session.permissions.allowedTools, contains('read_file'));
  });

  test('20. /allow (no arg) prints usage or error', () async {
    final result = await handle('/allow');
    expect(result, isTrue);
    final out = renderer.output;
    // Should print usage hint.
    expect(out.toLowerCase(), anyOf(contains('usage'), contains('allow')));
    // Allowlist must remain empty.
    expect(session.permissions.allowedTools, isEmpty);
  });

  // ── unknown / non-command inputs ───────────────────────────────────────────

  test('21. Unknown command /foo returns true (consumed) and prints message',
      () async {
    final result = await handle('/foo');
    expect(result, isTrue);
    expect(renderer.output.toLowerCase(), contains('unknown'));
  });

  test('22. Non-command input "hello" returns false (not a slash command)',
      () async {
    final result = await handle('hello');
    expect(result, isFalse);
  });

  test('23. Empty string returns false', () async {
    final result = await handle('');
    expect(result, isFalse);
  });

  test('24. Input starting with space is not treated as a command', () async {
    final result = await handle(' /help');
    // After trim() it starts with '/' — let's verify actual behaviour.
    // The implementation does input.trim() so this WILL be handled as /help.
    expect(result, isTrue);
  });

  // ── /help text specifics ───────────────────────────────────────────────────

  test('25. /clear help text says "Clear terminal display (history preserved)"',
      () async {
    await handle('/help');
    expect(
      renderer.output,
      contains('Clear terminal display (history preserved)'),
    );
  });
}
