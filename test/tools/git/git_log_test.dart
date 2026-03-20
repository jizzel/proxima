import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/git/git_log_tool.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/core/types.dart';

void main() {
  late Directory tempDir;
  late GitLogTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_git_log_');
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
    tool = GitLogTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('returns "No commits found." on empty repo', () async {
    final result = await tool.execute({}, tempDir.path);
    expect(result, equals('No commits found.'));
  });

  test('shows commit after committing', () async {
    final file = File(p.join(tempDir.path, 'a.txt'));
    await file.writeAsString('hello');
    await Process.run('git', ['add', 'a.txt'], workingDirectory: tempDir.path);
    await Process.run('git', [
      'commit',
      '-m',
      'initial commit',
    ], workingDirectory: tempDir.path);
    final result = await tool.execute({}, tempDir.path);
    expect(result, contains('initial commit'));
  });

  test('respects limit argument', () async {
    for (var i = 1; i <= 5; i++) {
      final file = File(p.join(tempDir.path, 'file$i.txt'));
      await file.writeAsString('content $i');
      await Process.run('git', [
        'add',
        'file$i.txt',
      ], workingDirectory: tempDir.path);
      await Process.run('git', [
        'commit',
        '-m',
        'commit $i',
      ], workingDirectory: tempDir.path);
    }
    final result = await tool.execute({'limit': 3}, tempDir.path);
    final lines = result.trim().split('\n');
    expect(lines.length, equals(3));
  });

  test('throws ToolError for path traversal', () async {
    expect(
      () => tool.execute({'path': '../escape.txt'}, tempDir.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('throws ToolError for non-git directory', () async {
    final nonGit = await Directory.systemTemp.createTemp('proxima_nongit_');
    addTearDown(() => nonGit.delete(recursive: true));
    expect(() => tool.execute({}, nonGit.path), throwsA(isA<ToolError>()));
  });

  test('dryRun preview includes limit and path', () async {
    final result = await tool.dryRun({
      'limit': 5,
      'path': 'lib/',
    }, tempDir.path);
    expect(result.preview, contains('-n 5'));
    expect(result.preview, contains('lib/'));
    expect(result.riskLevel, equals(RiskLevel.safe));
  });
}
