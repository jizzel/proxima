import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/git/git_diff_tool.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/core/types.dart';

void main() {
  late Directory tempDir;
  late GitDiffTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_git_diff_');
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
    tool = GitDiffTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('returns "No diff." for clean repo', () async {
    final result = await tool.execute({}, tempDir.path);
    expect(result, equals('No diff.'));
  });

  test('shows unstaged changes', () async {
    final file = File(p.join(tempDir.path, 'foo.txt'));
    await file.writeAsString('initial');
    await Process.run('git', ['add', 'foo.txt'], workingDirectory: tempDir.path);
    await Process.run(
      'git',
      ['commit', '-m', 'init'],
      workingDirectory: tempDir.path,
    );
    await file.writeAsString('changed');
    final result = await tool.execute({}, tempDir.path);
    expect(result, contains('foo.txt'));
    expect(result, contains('-initial'));
    expect(result, contains('+changed'));
  });

  test('shows staged diff with staged:true', () async {
    final file = File(p.join(tempDir.path, 'bar.txt'));
    await file.writeAsString('first');
    await Process.run('git', ['add', 'bar.txt'], workingDirectory: tempDir.path);
    await Process.run(
      'git',
      ['commit', '-m', 'init'],
      workingDirectory: tempDir.path,
    );
    await file.writeAsString('second');
    await Process.run('git', ['add', 'bar.txt'], workingDirectory: tempDir.path);
    final result = await tool.execute({'staged': true}, tempDir.path);
    expect(result, contains('bar.txt'));
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
    expect(
      () => tool.execute({}, nonGit.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('dryRun preview reflects staged flag', () async {
    final result = await tool.dryRun({'staged': true}, tempDir.path);
    expect(result.preview, contains('--staged'));
    expect(result.riskLevel, equals(RiskLevel.safe));
  });

  test('dryRun preview includes path when provided', () async {
    final result = await tool.dryRun({'path': 'foo.txt'}, tempDir.path);
    expect(result.preview, contains('foo.txt'));
  });
}
