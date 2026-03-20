import 'dart:io';
import 'package:test/test.dart';
import 'package:proxima/tools/file/delete_file_tool.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/core/types.dart';

void main() {
  late Directory tempDir;
  late DeleteFileTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_delete_test_');
    tool = DeleteFileTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('1. deletes existing file and verifies it is gone', () async {
    final file = File('${tempDir.path}/target.txt');
    await file.writeAsString('hello');

    await tool.execute({'path': 'target.txt'}, tempDir.path);

    expect(await file.exists(), isFalse);
  });

  test('2. creates backup before deleting and backup exists', () async {
    final file = File('${tempDir.path}/target.txt');
    await file.writeAsString('original');

    await tool.execute({'path': 'target.txt'}, tempDir.path);

    final backup = File('${tempDir.path}/target.txt.proxima_bak');
    expect(await backup.exists(), isTrue);
    expect(await backup.readAsString(), 'original');
  });

  test('3. returns BACKUP_PATH: in result', () async {
    final file = File('${tempDir.path}/to_delete.txt');
    await file.writeAsString('data');

    final result = await tool.execute({'path': 'to_delete.txt'}, tempDir.path);

    expect(result, contains('BACKUP_PATH:'));
  });

  test('4. throws ToolError for missing file', () async {
    expect(
      () => tool.execute({'path': 'nonexistent.txt'}, tempDir.path),
      throwsA(
        isA<ToolError>().having(
          (e) => e.message,
          'message',
          contains('not found'),
        ),
      ),
    );
  });

  test('5. throws ToolError when path is a directory', () async {
    final subDir = Directory('${tempDir.path}/subdir');
    await subDir.create();

    expect(
      () => tool.execute({'path': 'subdir'}, tempDir.path),
      throwsA(
        isA<ToolError>().having(
          (e) => e.message,
          'message',
          contains('Cannot delete directories'),
        ),
      ),
    );
  });

  test('6. throws ToolError for path traversal', () async {
    expect(
      () => tool.execute({'path': '../outside.txt'}, tempDir.path),
      throwsA(
        isA<ToolError>().having(
          (e) => e.message,
          'message',
          contains('outside working directory'),
        ),
      ),
    );
  });

  test('7. riskLevel is highRisk', () {
    expect(tool.riskLevel, RiskLevel.highRisk);
  });

  test('8. dryRun contains [HIGH RISK]', () async {
    final result = await tool.dryRun({'path': 'some.txt'}, tempDir.path);
    expect(result.preview, contains('[HIGH RISK]'));
  });

  test('9. overwrites stale backup if .proxima_bak already exists', () async {
    final file = File('${tempDir.path}/target.txt');
    final staleBackup = File('${tempDir.path}/target.txt.proxima_bak');
    await file.writeAsString('new content');
    await staleBackup.writeAsString('stale content');

    // Should not throw; stale backup is overwritten.
    await tool.execute({'path': 'target.txt'}, tempDir.path);

    expect(await file.exists(), isFalse);
    expect(await staleBackup.readAsString(), 'new content');
  });

  test('10. result string contains the original path', () async {
    final file = File('${tempDir.path}/named.txt');
    await file.writeAsString('x');

    final result = await tool.execute({'path': 'named.txt'}, tempDir.path);

    expect(result, contains('named.txt'));
  });
}
