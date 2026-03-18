import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/file/write_file_tool.dart';

void main() {
  late Directory tempDir;
  late WriteFileTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_write_');
    tool = WriteFileTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('creates new file', () async {
    final result = await tool.execute({
      'path': 'new_file.txt',
      'content': 'hello world',
    }, tempDir.path);
    expect(result, contains('new_file.txt'));

    final file = File(p.join(tempDir.path, 'new_file.txt'));
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), 'hello world');
  });

  test('overwrites existing file and creates backup', () async {
    final file = File(p.join(tempDir.path, 'existing.txt'));
    await file.writeAsString('original content');

    final result = await tool.execute({
      'path': 'existing.txt',
      'content': 'new content',
    }, tempDir.path);

    expect(await file.readAsString(), 'new content');
    expect(result, contains('BACKUP_PATH:'));

    final backup = File(p.join(tempDir.path, 'existing.txt.proxima_bak'));
    expect(await backup.exists(), isTrue);
    expect(await backup.readAsString(), 'original content');
  });

  test('creates parent directories', () async {
    final result = await tool.execute({
      'path': 'deep/nested/file.txt',
      'content': 'content',
    }, tempDir.path);
    expect(result, contains('deep/nested/file.txt'));

    final file = File(p.join(tempDir.path, 'deep', 'nested', 'file.txt'));
    expect(await file.exists(), isTrue);
  });

  test('throws ToolError for path traversal', () async {
    expect(
      () =>
          tool.execute({'path': '../escape.txt', 'content': 'x'}, tempDir.path),
      throwsA(isA<dynamic>()),
    );
  });
}
