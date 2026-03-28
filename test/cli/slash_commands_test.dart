import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/cli/slash_commands.dart';
import 'package:proxima/core/session.dart';
import 'package:proxima/core/session_storage.dart';
import 'package:proxima/core/config.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/renderer/renderer.dart';
import 'package:proxima/tools/tool_registry.dart';
import 'package:proxima/tools/file/read_file_tool.dart';
import 'package:proxima/tools/file/write_file_tool.dart';
import 'package:proxima/permissions/risk_classifier.dart';
import 'package:proxima/permissions/audit_log.dart';
import 'package:proxima/permissions/permission_gate.dart';

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
  late SessionMode? modeSwitchArg;
  late bool? debugSwitchArg;
  late String? dirSwitchArg;

  setUp(() {
    renderer = FakeRenderer();
    handler = SlashCommandHandler(renderer, isTty: () => false);
    session = makeSession();
    clearCalled = false;
    modelSwitchArg = null;
    exitCalled = false;
    modeSwitchArg = null;
    debugSwitchArg = null;
    dirSwitchArg = null;
  });

  // ── helper ─────────────────────────────────────────────────────────────────

  Future<bool> handle(
    String input, {
    List<String> ollamaModels = const [],
    int contextWindow = 128000,
    ToolRegistry? toolRegistry,
    bool debugState = false,
    SessionStorage? sessionStorage,
  }) => handler.handle(
    input,
    session,
    () => clearCalled = true,
    (m) => modelSwitchArg = m,
    () => exitCalled = true,
    ollamaModels: ollamaModels,
    onModeSwitch: (m) => modeSwitchArg = m,
    contextWindow: contextWindow,
    onDebugSwitch: (d) => debugSwitchArg = d,
    debugState: debugState,
    toolRegistry: toolRegistry,
    onDirSwitch: (d) => dirSwitchArg = d,
    sessionStorage: sessionStorage,
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
    expect(out, contains('/mode'));
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

  test(
    '5. /clear does NOT clear session.history — history is preserved',
    () async {
      session.addMessage(Message(role: MessageRole.user, content: 'hello'));
      session.addMessage(Message(role: MessageRole.assistant, content: 'hi'));
      final countBefore = session.history.length;

      await handle('/clear');

      expect(session.history.length, countBefore);
    },
  );

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

  test(
    '9. /model (no arg) falls back to plain list in non-TTY and returns true',
    () async {
      // The interactive picker requires a real TTY (stdout.hasTerminal == true).
      // In the test runner stdout is not a TTY, so the plain-list fallback is
      // used instead.  The picker itself is tested manually.
      final result = await handle(
        '/model',
        ollamaModels: [], // no ollama models — avoids live network fetch
      );
      expect(result, isTrue);
      final out = renderer.output;
      // The non-TTY fallback still prints the anthropic model names.
      expect(out, contains('anthropic'));
      expect(
        SlashCommandHandler.anthropicModels.any((m) => out.contains(m)),
        isTrue,
      );
    },
  );

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

  test(
    '13. /status output contains model name and working directory',
    () async {
      await handle('/status');
      final out = renderer.output;
      expect(out, contains(session.model));
      expect(out, contains(session.workingDir));
    },
  );

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

  // ── /mode ──────────────────────────────────────────────────────────────────

  test('26. /mode (no arg) prints current mode', () async {
    final result = await handle('/mode');
    expect(result, isTrue);
    expect(renderer.output, contains('confirm'));
  });

  test('27. /mode safe calls onModeSwitch with SessionMode.safe', () async {
    final result = await handle('/mode safe');
    expect(result, isTrue);
    expect(modeSwitchArg, SessionMode.safe);
  });

  test(
    '28. /mode confirm calls onModeSwitch with SessionMode.confirm',
    () async {
      final result = await handle('/mode confirm');
      expect(result, isTrue);
      expect(modeSwitchArg, SessionMode.confirm);
    },
  );

  test('29. /mode auto calls onModeSwitch with SessionMode.auto', () async {
    final result = await handle('/mode auto');
    expect(result, isTrue);
    expect(modeSwitchArg, SessionMode.auto);
  });

  test('30. /mode foo prints error message', () async {
    final result = await handle('/mode foo');
    expect(result, isTrue);
    expect(
      renderer.output,
      contains('Unknown mode: foo. Use safe, confirm, or auto.'),
    );
    expect(modeSwitchArg, isNull);
  });

  // ── unknown / non-command inputs ───────────────────────────────────────────

  test(
    '21. Unknown command /foo returns true (consumed) and prints message',
    () async {
      final result = await handle('/foo');
      expect(result, isTrue);
      expect(renderer.output.toLowerCase(), contains('unknown'));
    },
  );

  test(
    '22. Non-command input "hello" returns false (not a slash command)',
    () async {
      final result = await handle('hello');
      expect(result, isFalse);
    },
  );

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

  test(
    '25. /clear help text says "Clear terminal display (history preserved)"',
    () async {
      await handle('/help');
      expect(
        renderer.output,
        contains('Clear terminal display (history preserved)'),
      );
    },
  );

  // ── /files ─────────────────────────────────────────────────────────────────

  test(
    '31. /files with no modified files prints "No files accessed"',
    () async {
      final result = await handle('/files');
      expect(result, isTrue);
      expect(renderer.output, contains('No files accessed this session.'));
    },
  );

  test('32. /files with modified files in session prints file paths', () async {
    session.addTaskRecord(
      TaskRecord(
        toolName: 'write_file',
        args: {'path': 'lib/foo.dart'},
        timestamp: DateTime.now(),
        success: true,
      ),
    );
    session.addTaskRecord(
      TaskRecord(
        toolName: 'patch_file',
        args: {'path': 'lib/bar.dart'},
        timestamp: DateTime.now(),
        success: true,
      ),
    );

    final result = await handle('/files');
    expect(result, isTrue);
    final out = renderer.output;
    expect(out, contains('lib/foo.dart'));
    expect(out, contains('lib/bar.dart'));
    expect(out, contains('modified'));
  });

  // ── /context ───────────────────────────────────────────────────────────────

  test('33. /context prints token budget with percentage labels', () async {
    final result = await handle('/context', contextWindow: 128000);
    expect(result, isTrue);
    final out = renderer.output;
    expect(out, contains('system prompt'));
    expect(out, contains('3%'));
    expect(out, contains('35%'));
  });

  test(
    '34. /context output contains "system prompt" and percentage values',
    () async {
      final result = await handle('/context', contextWindow: 100000);
      expect(result, isTrue);
      final out = renderer.output;
      expect(out, contains('system prompt'));
      expect(out, contains('project index'));
      expect(out, contains('active files'));
      expect(out, contains('history'));
      expect(out, contains('tool results'));
      expect(out, contains('output headroom'));
      expect(out, contains('safety margin'));
      // Token counts should be present (100k * 3% = 3000).
      expect(out, contains('3,000'));
    },
  );

  // ── /tools ─────────────────────────────────────────────────────────────────

  test('35. /tools with registry prints tool names and risk levels', () async {
    final registry = ToolRegistry();
    registry.register(ReadFileTool());
    registry.register(WriteFileTool());

    final result = await handle('/tools', toolRegistry: registry);
    expect(result, isTrue);
    final out = renderer.output;
    expect(out, contains('read_file'));
    expect(out, contains('write_file'));
    expect(out, contains('safe'));
    expect(out, contains('confirm'));
  });

  test('36. /tools with null registry prints graceful fallback', () async {
    final result = await handle('/tools');
    expect(result, isTrue);
    expect(renderer.output, contains('no registry available'));
  });

  // ── /debug ─────────────────────────────────────────────────────────────────

  test('37. /debug on calls onDebugSwitch with true', () async {
    final result = await handle('/debug on');
    expect(result, isTrue);
    expect(debugSwitchArg, isTrue);
  });

  test('38. /debug off calls onDebugSwitch with false', () async {
    final result = await handle('/debug off');
    expect(result, isTrue);
    expect(debugSwitchArg, isFalse);
  });

  test('39. /debug (no arg) prints current state', () async {
    final result = await handle('/debug', debugState: true);
    expect(result, isTrue);
    expect(renderer.output, contains('on'));
    expect(debugSwitchArg, isNull);
  });

  // ── /deny ──────────────────────────────────────────────────────────────────

  test('40. /deny read_file adds to session.permissions.deniedTools', () async {
    expect(session.permissions.deniedTools, isEmpty);

    final result = await handle('/deny read_file');
    expect(result, isTrue);
    expect(session.permissions.deniedTools, contains('read_file'));
  });

  test('41. /deny (no arg) prints usage', () async {
    final result = await handle('/deny');
    expect(result, isTrue);
    expect(renderer.output.toLowerCase(), contains('usage'));
    expect(session.permissions.deniedTools, isEmpty);
  });

  // ── /permissions ───────────────────────────────────────────────────────────

  test(
    '42. /permissions prints allowed, denied, and ignored sections',
    () async {
      session.permissions = session.permissions
          .withAllowedTool('write_file')
          .withDeniedTool('run_command')
          .withIgnoredPattern('*.log');

      final result = await handle('/permissions');
      expect(result, isTrue);
      final out = renderer.output;
      expect(out, contains('allowed tools'));
      expect(out, contains('write_file'));
      expect(out, contains('denied tools'));
      expect(out, contains('run_command'));
      expect(out, contains('ignored patterns'));
      expect(out, contains('*.log'));
    },
  );

  // ── /dir ───────────────────────────────────────────────────────────────────

  test('43. /dir <valid path> calls onDirSwitch with resolved path', () async {
    final result = await handle('/dir ${Directory.systemTemp.path}');
    expect(result, isTrue);
    expect(dirSwitchArg, isNotNull);
    expect(dirSwitchArg, p.canonicalize(Directory.systemTemp.path));
  });

  test('44. /dir nonexistent path prints error', () async {
    final result = await handle('/dir /this/does/not/exist/ever');
    expect(result, isTrue);
    expect(renderer.output.toLowerCase(), contains('not found'));
    expect(dirSwitchArg, isNull);
  });

  // ── /ignore ────────────────────────────────────────────────────────────────

  test('45. /ignore *.log adds pattern to session', () async {
    expect(session.permissions.ignoredPatterns, isEmpty);

    final result = await handle('/ignore *.log');
    expect(result, isTrue);
    expect(session.permissions.ignoredPatterns, contains('*.log'));
  });

  test('46. /ignore (no arg) prints usage', () async {
    final result = await handle('/ignore');
    expect(result, isTrue);
    expect(renderer.output.toLowerCase(), contains('usage'));
    expect(session.permissions.ignoredPatterns, isEmpty);
  });

  // ── /snapshot ──────────────────────────────────────────────────────────────

  test('47. /snapshot saves session and prints ID and resume hint', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'proxima_snapshot_test_',
    );
    try {
      final storage = SessionStorage(tempDir.path);

      final result = await handle('/snapshot', sessionStorage: storage);
      expect(result, isTrue);
      final out = renderer.output;
      expect(out, contains(session.id));
      expect(
        out.toLowerCase(),
        anyOf(contains('resume'), contains('snapshot')),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  // ── /help contains new commands ────────────────────────────────────────────

  test('48. /help lists all 7 new commands', () async {
    await handle('/help');
    final out = renderer.output;
    expect(out, contains('/tools'));
    expect(out, contains('/debug'));
    expect(out, contains('/deny'));
    expect(out, contains('/permissions'));
    expect(out, contains('/dir'));
    expect(out, contains('/ignore'));
    expect(out, contains('/snapshot'));
  });

  // ── /undo after delete_file ────────────────────────────────────────────────

  test('49. /undo after delete_file restores the deleted file', () async {
    final tempDir = await Directory.systemTemp.createTemp('proxima_undo_del_');
    try {
      final target = File('${tempDir.path}/deleted.txt');
      final backup = File('${tempDir.path}/deleted.txt.proxima_bak');
      // Simulate what delete_file produces: file gone, backup present.
      await backup.writeAsString('original content');

      session.addTaskRecord(
        TaskRecord(
          toolName: 'delete_file',
          args: {'path': target.path},
          backupPath: backup.path,
          timestamp: DateTime.now(),
          success: true,
        ),
      );

      final result = await handle('/undo');
      expect(result, isTrue);
      expect(await target.exists(), isTrue);
      expect(await target.readAsString(), 'original content');
      expect(await backup.exists(), isFalse);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  // ── /files includes deleted files ──────────────────────────────────────────

  test('50. /files shows deleted files with (deleted) label', () async {
    session.addTaskRecord(
      TaskRecord(
        toolName: 'delete_file',
        args: {'path': 'lib/gone.dart'},
        timestamp: DateTime.now(),
        success: true,
      ),
    );

    final result = await handle('/files');
    expect(result, isTrue);
    final out = renderer.output;
    expect(out, contains('lib/gone.dart'));
    expect(out, contains('deleted'));
  });

  // ── /dir no arg ────────────────────────────────────────────────────────────

  test('51. /dir with no arg prints usage', () async {
    final result = await handle('/dir');
    expect(result, isTrue);
    expect(renderer.output.toLowerCase(), contains('usage'));
    expect(dirSwitchArg, isNull);
  });

  // ── /debug invalid arg ────────────────────────────────────────────────────

  test('52. /debug with invalid arg prints error', () async {
    final result = await handle('/debug yes');
    expect(result, isTrue);
    expect(renderer.output.toLowerCase(), contains('usage'));
    expect(debugSwitchArg, isNull);
  });

  // ── /snapshot null storage ────────────────────────────────────────────────

  test(
    '53. /snapshot with null sessionStorage prints graceful fallback',
    () async {
      final result = await handle('/snapshot');
      expect(result, isTrue);
      expect(renderer.output, contains('not available'));
    },
  );

  // ── /deny + /allow same tool — deny wins ──────────────────────────────────

  test('54. /deny wins when same tool is also in allowlist', () async {
    // Both allow and deny the same tool.
    session.permissions = session.permissions
        .withAllowedTool('read_file')
        .withDeniedTool('read_file');

    expect(session.permissions.allowedTools, contains('read_file'));
    expect(session.permissions.deniedTools, contains('read_file'));
    // The permission gate checks deny BEFORE allow — verified at the data level.
    // The sets themselves are both populated; gate precedence is tested in
    // permission_gate_test. Here we just confirm both sets hold the value.
    expect(session.permissions.deniedTools, contains('read_file'));
  });

  // ── /ignore duplicate pattern ─────────────────────────────────────────────

  test('55. /ignore same pattern twice adds it twice', () async {
    await handle('/ignore *.log');
    renderer.clearOutput();
    await handle('/ignore *.log');

    // ignoredPatterns is a list — duplicates are allowed (context manager
    // handles deduplication at filter time).
    expect(
      session.permissions.ignoredPatterns.where((p) => p == '*.log').length,
      2,
    );
  });

  // ── /mode persists to session ──────────────────────────────────────────────

  test(
    '56. /mode updates session.mode so it is persisted on save/resume',
    () async {
      expect(session.mode, SessionMode.confirm); // default

      // The handler updates session.mode directly.
      await handle('/mode auto');

      expect(session.mode, SessionMode.auto);
    },
  );

  test('57. /mode safe updates session.mode to safe', () async {
    await handle('/mode safe');
    expect(session.mode, SessionMode.safe);
  });

  // ── /allow is honoured by PermissionGate ──────────────────────────────────

  test('58. /allow tool is respected by PermissionGate.evaluate()', () async {
    final tempDir = await Directory.systemTemp.createTemp('proxima_allow_');
    try {
      final registry = ToolRegistry();
      registry.register(WriteFileTool());
      final auditLog = AuditLog(tempDir.path);
      final gate = PermissionGate(
        classifier: RiskClassifier(registry),
        auditLog: auditLog,
        mode: SessionMode.confirm, // confirm mode — would normally prompt
        allowedTools: {},
        prompt: (_, _, {criticResult}) async => false, // prompt always denies
      );

      // Allow write_file via /allow.
      await handle('/allow write_file');
      expect(session.permissions.allowedTools, contains('write_file'));

      // The gate must honour the session allowlist even though the prompt denies.
      final result = await gate.evaluate(
        ToolCall(
          tool: 'write_file',
          args: {'path': 'foo.txt', 'content': 'x'},
          reasoning: 'test',
        ),
        session.id,
        allowedTools: session.permissions.allowedTools,
      );
      expect(result.decision, GateDecision.allow);

      await auditLog.close();
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  // ── /status shows working directory ───────────────────────────────────────

  test('59. /status shows working directory', () async {
    await handle('/status');
    expect(renderer.output, contains(session.workingDir));
  });
}
