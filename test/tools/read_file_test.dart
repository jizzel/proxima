import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/file/read_file_tool.dart';

void main() {
  late Directory tempDir;
  late ReadFileTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_read_');
    tool = ReadFileTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('reads existing file with line numbers', () async {
    final file = File(p.join(tempDir.path, 'test.txt'));
    await file.writeAsString('line one\nline two\nline three');

    final result = await tool.execute({'path': 'test.txt'}, tempDir.path);
    expect(result, contains('1: line one'));
    expect(result, contains('2: line two'));
    expect(result, contains('3: line three'));
  });

  test('reads file with line range', () async {
    final file = File(p.join(tempDir.path, 'test.txt'));
    await file.writeAsString('line one\nline two\nline three\nline four');

    final result = await tool.execute({
      'path': 'test.txt',
      'start_line': 2,
      'end_line': 3,
    }, tempDir.path);
    expect(result, contains('2: line two'));
    expect(result, contains('3: line three'));
    expect(result, isNot(contains('1: line one')));
    expect(result, isNot(contains('4: line four')));
  });

  test('throws ToolError for missing file', () async {
    expect(
      () => tool.execute({'path': 'nonexistent.txt'}, tempDir.path),
      throwsA(
        isA<dynamic>().having(
          (e) => e.toString(),
          'message',
          contains('not found'),
        ),
      ),
    );
  });

  test('throws ToolError for path traversal', () async {
    expect(
      () => tool.execute({'path': '../escape.txt'}, tempDir.path),
      throwsA(
        isA<dynamic>().having(
          (e) => e.toString(),
          'message',
          contains('outside working directory'),
        ),
      ),
    );
  });
}
