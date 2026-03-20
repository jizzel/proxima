import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/git/git_status_tool.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/core/types.dart';

void main() {
  late Directory tempDir;
  late GitStatusTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_git_status_');
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
    tool = GitStatusTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('returns clean message on empty repo', () async {
    final result = await tool.execute({}, tempDir.path);
    expect(result, equals('Working tree clean.'));
  });

  test('shows untracked file', () async {
    await File(p.join(tempDir.path, 'hello.dart')).writeAsString('void main(){}');
    final result = await tool.execute({}, tempDir.path);
    expect(result, contains('hello.dart'));
    expect(result, contains('?'));
  });

  test('shows staged file', () async {
    final file = File(p.join(tempDir.path, 'staged.dart'));
    await file.writeAsString('// staged');
    await Process.run('git', ['add', 'staged.dart'], workingDirectory: tempDir.path);
    final result = await tool.execute({}, tempDir.path);
    expect(result, contains('staged.dart'));
  });

  test('throws ToolError for non-git directory', () async {
    final nonGit = await Directory.systemTemp.createTemp('proxima_nongit_');
    addTearDown(() => nonGit.delete(recursive: true));
    expect(
      () => tool.execute({}, nonGit.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('dryRun returns expected preview', () async {
    final result = await tool.dryRun({}, tempDir.path);
    expect(result.preview, contains('git status --short'));
    expect(result.riskLevel, equals(RiskLevel.safe));
  });
}
