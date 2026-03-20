import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/git/git_add_tool.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/core/types.dart';

void main() {
  late Directory tempDir;
  late GitAddTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_git_add_');
    await Process.run('git', ['init'], workingDirectory: tempDir.path);
    await Process.run(
      'git',
      ['config', 'user.email', 'test@test.com'],
      workingDirectory: tempDir.path,
    );
    await Process.run(
      'git',
      ['config', 'user.name', 'Test'],
      workingDirectory: tempDir.path,
    );
    tool = GitAddTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('stages an existing file', () async {
    await File(p.join(tempDir.path, 'hello.dart')).writeAsString('// hello');
    final result = await tool.execute({'path': 'hello.dart'}, tempDir.path);
    expect(result, contains('hello.dart'));

    // Verify the file is actually staged
    final status = await Process.run(
      'git',
      ['status', '--short'],
      workingDirectory: tempDir.path,
    );
    expect(status.stdout as String, contains('A'));
  });

  test('throws ToolError for path traversal', () async {
    expect(
      () => tool.execute({'path': '../escape.txt'}, tempDir.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('throws ToolError if git add fails (non-existent file)', () async {
    expect(
      () => tool.execute({'path': 'nonexistent.dart'}, tempDir.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('riskLevel is confirm', () {
    expect(tool.riskLevel, equals(RiskLevel.confirm));
  });

  test('dryRun preview shows path', () async {
    final result = await tool.dryRun({'path': 'foo.dart'}, tempDir.path);
    expect(result.preview, contains('git add foo.dart'));
    expect(result.riskLevel, equals(RiskLevel.confirm));
  });
}
