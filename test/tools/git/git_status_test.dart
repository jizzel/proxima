import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/git/git_status_tool.dart';
import 'package:proxima/core/types.dart';

void main() {
  late Directory tempDir;
  late GitStatusTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_git_status_');
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
    await File(
      p.join(tempDir.path, 'hello.dart'),
    ).writeAsString('void main(){}');
    final result = await tool.execute({}, tempDir.path);
    expect(result, contains('hello.dart'));
    expect(result, contains('?'));
  });

  test('shows staged file', () async {
    final file = File(p.join(tempDir.path, 'staged.dart'));
    await file.writeAsString('// staged');
    await Process.run('git', [
      'add',
      'staged.dart',
    ], workingDirectory: tempDir.path);
    final result = await tool.execute({}, tempDir.path);
    expect(result, contains('staged.dart'));
  });

  test('reports a non-git directory instead of failing', () async {
    // Not being a repository is an ordinary condition — a freshly scaffolded
    // project has no repo yet, and a hard error there reads as a broken tool.
    final nonGit = await Directory.systemTemp.createTemp('proxima_nongit_');
    addTearDown(() => nonGit.delete(recursive: true));

    final result = await tool.execute({}, nonGit.path);
    expect(result, contains('Not a git repository'));
  });

  test('dryRun returns expected preview', () async {
    final result = await tool.dryRun({}, tempDir.path);
    expect(result.preview, contains('git status --short'));
    expect(result.riskLevel, equals(RiskLevel.safe));
  });
}
