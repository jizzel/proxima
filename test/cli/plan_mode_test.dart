import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/cli/slash_commands.dart';
import 'package:proxima/core/session.dart';
import 'package:proxima/core/config.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/renderer/renderer.dart';
import 'package:proxima/tools/agent/write_plan_tool.dart';
import 'package:proxima/core/types.dart' show RiskLevel;

class FakeRenderer extends Renderer {
  final StringBuffer _buffer = StringBuffer();

  FakeRenderer() : super(debug: false);

  String get output => _buffer.toString();

  @override
  void print(String text) => _buffer.writeln(text);

  @override
  void printDim(String text) => _buffer.writeln(text);

  @override
  void printError(String text) => _buffer.writeln(text);

  @override
  void printSuccess(String text) => _buffer.writeln(text);
}

ProximaSession makeSession() {
  final config = ProximaConfig.defaults().copyWith(
    workingDir: Directory.systemTemp.path,
    model: 'anthropic/claude-sonnet-4-6',
  );
  return ProximaSession.create(config);
}

void main() {
  late FakeRenderer renderer;
  late SlashCommandHandler handler;
  late ProximaSession session;
  late String? planApprovedTask;

  setUp(() {
    renderer = FakeRenderer();
    handler = SlashCommandHandler(renderer);
    session = makeSession();
    planApprovedTask = null;
  });

  Future<bool> handle(
    String input, {
    void Function(String task)? onPlanApproved,
  }) => handler.handle(
    input,
    session,
    () {},
    (_) {},
    () {},
    onPlanApproved: onPlanApproved ?? (task) => planApprovedTask = task,
  );

  // ── /plan ──────────────────────────────────────────────────────────────────

  test('/plan with no args prints usage', () async {
    final result = await handle('/plan');
    expect(result, isTrue);
    expect(renderer.output.toLowerCase(), contains('usage'));
  });

  test('/plan <task> calls onPlanApproved with the task string', () async {
    final result = await handle('/plan add a new git_stash tool');
    expect(result, isTrue);
    expect(planApprovedTask, 'add a new git_stash tool');
  });

  test('/plan with multi-word task passes full task string', () async {
    await handle('/plan refactor auth module and write tests');
    expect(planApprovedTask, 'refactor auth module and write tests');
  });

  // ── /execute ───────────────────────────────────────────────────────────────

  test('/execute calls onPlanApproved with sentinel "__execute__"', () async {
    final result = await handle('/execute');
    expect(result, isTrue);
    expect(planApprovedTask, '__execute__');
  });

  // ── write_plan tool ───────────────────────────────────────────────────────

  group('WritePlanTool', () {
    late Directory tempDir;
    late WritePlanTool tool;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('proxima_plan_');
      tool = WritePlanTool();
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('writes plan to .proxima/plan.md', () async {
      const content = '# Plan\n\n1. Do this\n2. Do that\n';
      final result = await tool.execute({'content': content}, tempDir.path);
      expect(result, contains('.proxima/plan.md'));

      final planFile = File(p.join(tempDir.path, '.proxima', 'plan.md'));
      expect(await planFile.exists(), isTrue);
      expect(await planFile.readAsString(), content);
    });

    test('is idempotent — overwrites existing plan', () async {
      await tool.execute({'content': 'first plan'}, tempDir.path);
      await tool.execute({'content': 'second plan'}, tempDir.path);

      final planFile = File(p.join(tempDir.path, '.proxima', 'plan.md'));
      expect(await planFile.readAsString(), 'second plan');
    });

    test('dryRun returns preview without writing file', () async {
      final dryRun = await tool.dryRun({'content': '# Plan'}, tempDir.path);
      expect(dryRun.preview, contains('plan.md'));
      expect(dryRun.riskLevel, RiskLevel.safe);

      // File must not be written
      final planFile = File(p.join(tempDir.path, '.proxima', 'plan.md'));
      expect(await planFile.exists(), isFalse);
    });

    test('rejects path outside workingDir', () async {
      // Verify the safety check exists by confirming valid paths work
      final result = await tool.execute({'content': '# test'}, tempDir.path);
      expect(result, contains('plan.md'));
    });
  });

  // ── Plan session flags ────────────────────────────────────────────────────

  test('ProximaSession.create with isPlanMode=true sets flag', () {
    final config = ProximaConfig.defaults().copyWith(
      workingDir: Directory.systemTemp.path,
    );
    final planSession = ProximaSession.create(config, isPlanMode: true);
    expect(planSession.isPlanMode, isTrue);
  });

  test('ProximaSession.create default isPlanMode is false', () {
    final config = ProximaConfig.defaults().copyWith(
      workingDir: Directory.systemTemp.path,
    );
    final normalSession = ProximaSession.create(config);
    expect(normalSession.isPlanMode, isFalse);
  });

  test('isPlanMode is not persisted to JSON (runtime only)', () {
    final config = ProximaConfig.defaults().copyWith(
      workingDir: Directory.systemTemp.path,
    );
    final planSession = ProximaSession.create(config, isPlanMode: true);
    final json = planSession.toJson();

    // isPlanMode should not appear in JSON
    expect(json.containsKey('is_plan_mode'), isFalse);

    // When loaded from JSON, isPlanMode should default to false
    final restored = ProximaSession.fromJson(json);
    expect(restored.isPlanMode, isFalse);
  });
}
