import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/git/git_commit_tool.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/core/types.dart';

void main() {
  late Directory tempDir;
  late GitCommitTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_git_commit_');
    await Process.run('git', ['init'], workingDirectory: tempDir.path);
    await Process.run('git', [
      'config',
      'user.email',
      'test@test.com',
    ], workingDirectory: tempDir.path);
    await Process.run('git', [
      'config',
      'user.name',
      'Test',
    ], workingDirectory: tempDir.path);
    tool = GitCommitTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('creates a commit with staged changes', () async {
    final file = File(p.join(tempDir.path, 'readme.txt'));
    await file.writeAsString('hello world');
    await Process.run('git', [
      'add',
      'readme.txt',
    ], workingDirectory: tempDir.path);

    final result = await tool.execute({
      'message': 'initial commit',
    }, tempDir.path);
    expect(result, isNotEmpty);

    // Verify commit exists
    final log = await Process.run('git', [
      'log',
      '--oneline',
    ], workingDirectory: tempDir.path);
    expect(log.stdout as String, contains('initial commit'));
  });

  test('throws ToolError when nothing is staged', () async {
    expect(
      () => tool.execute({'message': 'empty commit'}, tempDir.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('riskLevel is confirm', () {
    expect(tool.riskLevel, equals(RiskLevel.confirm));
  });

  test('dryRun preview includes message', () async {
    final result = await tool.dryRun({'message': 'fix bug'}, tempDir.path);
    expect(result.preview, contains('fix bug'));
    expect(result.riskLevel, equals(RiskLevel.confirm));
  });
}
