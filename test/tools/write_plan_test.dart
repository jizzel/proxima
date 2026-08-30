import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/tools/agent/write_plan_tool.dart';

void main() {
  late Directory tempDir;
  late WritePlanTool tool;

  File planFile() => File(p.join(tempDir.path, '.proxima', 'plan.md'));

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_plan_');
    tool = WritePlanTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('WritePlanTool', () {
    test('writes the plan and creates .proxima/', () async {
      await tool.execute({'content': '# Plan\n- step one'}, tempDir.path);

      expect(await planFile().exists(), isTrue);
      expect(await planFile().readAsString(), contains('step one'));
    });

    test('returns the documented confirmation string', () async {
      final result = await tool.execute({'content': 'x'}, tempDir.path);
      expect(result, contains('.proxima/plan.md'));
    });

    test('overwrites an existing plan rather than appending', () async {
      await tool.execute({'content': 'first'}, tempDir.path);
      await tool.execute({'content': 'second'}, tempDir.path);

      final written = await planFile().readAsString();
      expect(written, equals('second'));
      expect(written, isNot(contains('first')));
    });

    test('writes into an existing .proxima directory', () async {
      await Directory(p.join(tempDir.path, '.proxima')).create();
      await tool.execute({'content': 'x'}, tempDir.path);
      expect(await planFile().exists(), isTrue);
    });

    test('preserves content exactly, including markdown', () async {
      const content =
          '# Plan\n\n1. read\n2. write\n\n```dart\nvoid main() {}\n```';
      await tool.execute({'content': content}, tempDir.path);
      expect(await planFile().readAsString(), equals(content));
    });

    test('throws ToolError when content is missing', () async {
      // Regression: an unguarded cast surfaced a raw TypeError, which the agent
      // loop's error taxonomy cannot classify or report usefully.
      await expectLater(
        tool.execute({}, tempDir.path),
        throwsA(isA<ToolError>()),
      );
    });

    test('throws ToolError when content is not a string', () async {
      await expectLater(
        tool.execute({'content': 42}, tempDir.path),
        throwsA(isA<ToolError>()),
      );
    });

    test('is classified safe — it writes only inside .proxima/', () {
      expect(tool.riskLevel, equals(RiskLevel.safe));
    });

    test('requires content in its schema', () {
      expect(tool.inputSchema['required'], contains('content'));
    });

    test('dryRun writes nothing', () async {
      final result = await tool.dryRun({'content': 'x'}, tempDir.path);
      expect(result.preview, contains('plan.md'));
      expect(await planFile().exists(), isFalse);
    });
  });
}
