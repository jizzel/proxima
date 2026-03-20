import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/git/git_reset_tool.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/core/types.dart';

void main() {
  late Directory tempDir;
  late GitResetTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_git_reset_');
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
    tool = GitResetTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('resets to HEAD successfully', () async {
    final file = File(p.join(tempDir.path, 'f.txt'));
    await file.writeAsString('original');
    await Process.run('git', ['add', 'f.txt'], workingDirectory: tempDir.path);
    await Process.run('git', [
      'commit',
      '-m',
      'base',
    ], workingDirectory: tempDir.path);
    await file.writeAsString('modified');

    final result = await tool.execute({'ref': 'HEAD'}, tempDir.path);
    expect(result, isNotEmpty);

    final content = await file.readAsString();
    expect(content, equals('original'));
  });

  test('resets to HEAD by default (no ref arg)', () async {
    final file = File(p.join(tempDir.path, 'g.txt'));
    await file.writeAsString('v1');
    await Process.run('git', ['add', 'g.txt'], workingDirectory: tempDir.path);
    await Process.run('git', [
      'commit',
      '-m',
      'first',
    ], workingDirectory: tempDir.path);
    await file.writeAsString('v2');
    await Process.run('git', ['add', 'g.txt'], workingDirectory: tempDir.path);

    await tool.execute({}, tempDir.path);
    final content = await file.readAsString();
    expect(content, equals('v1'));
  });

  test('throws ToolError for non-git directory', () async {
    final nonGit = await Directory.systemTemp.createTemp('proxima_nongit_');
    addTearDown(() => nonGit.delete(recursive: true));
    expect(
      () => tool.execute({'ref': 'HEAD'}, nonGit.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('riskLevel is highRisk', () {
    expect(tool.riskLevel, equals(RiskLevel.highRisk));
  });

  test('dryRun preview shows [HIGH RISK] and ref', () async {
    final result = await tool.dryRun({'ref': 'HEAD~1'}, tempDir.path);
    expect(result.preview, contains('[HIGH RISK]'));
    expect(result.preview, contains('HEAD~1'));
    expect(result.riskLevel, equals(RiskLevel.highRisk));
  });

  test('dryRun defaults ref to HEAD when not provided', () async {
    final result = await tool.dryRun({}, tempDir.path);
    expect(result.preview, contains('HEAD'));
  });
}
