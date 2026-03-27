import 'dart:io';
import 'package:test/test.dart';
import 'package:proxima/tools/search/search_symbol_tool.dart';
import 'package:proxima/tools/tool_interface.dart';

void main() {
  late Directory tempDir;
  late SearchSymbolTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_symbol_');
    tool = SearchSymbolTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<void> writeFile(String name, String content) async {
    await File('${tempDir.path}/$name').writeAsString(content);
  }

  test('finds Dart class definition', () async {
    await writeFile('foo.dart', '''
class Foo {
  void bar() {}
}
''');
    final result = await tool.execute({'symbol': 'Foo'}, tempDir.path);
    expect(result, contains('foo.dart'));
    expect(result, contains('[class]'));
    expect(result, contains('class Foo'));
  });

  test('finds Dart top-level function', () async {
    await writeFile('foo.dart', '''
void myFunc(String x) {
  print(x);
}
''');
    final result = await tool.execute({'symbol': 'myFunc'}, tempDir.path);
    expect(result, contains('[function]'));
    expect(result, contains('myFunc'));
  });

  test('finds Dart method (indented)', () async {
    await writeFile('foo.dart', '''
class MyClass {
  String myMethod(int x) {
    return x.toString();
  }
}
''');
    final result = await tool.execute({'symbol': 'myMethod'}, tempDir.path);
    expect(result, contains('[method]'));
    expect(result, contains('myMethod'));
  });

  test('finds Python class', () async {
    await writeFile('foo.py', '''
class MyPyClass:
    def __init__(self):
        pass
''');
    final result = await tool.execute({'symbol': 'MyPyClass'}, tempDir.path);
    expect(result, contains('[class]'));
    expect(result, contains('MyPyClass'));
  });

  test('finds Python function', () async {
    await writeFile('foo.py', '''
def my_func(x):
    return x + 1
''');
    final result = await tool.execute({'symbol': 'my_func'}, tempDir.path);
    expect(result, contains('[function]'));
    expect(result, contains('my_func'));
  });

  test('kind: class filters out function matches', () async {
    await writeFile('foo.dart', '''
class TargetClass {
  void targetFunc() {}
}
void targetFunc() {}
''');
    final result = await tool.execute({
      'symbol': 'targetFunc',
      'kind': 'class',
    }, tempDir.path);
    // No class named targetFunc, should return no definitions
    expect(result, contains('No definitions found'));
  });

  test('skips .g.dart files', () async {
    await writeFile('foo.g.dart', '''
class GeneratedFoo {}
''');
    final result = await tool.execute({'symbol': 'GeneratedFoo'}, tempDir.path);
    expect(result, contains('No definitions found'));
  });

  test('skips .git directory', () async {
    final gitDir = Directory('${tempDir.path}/.git');
    await gitDir.create();
    await File('${tempDir.path}/.git/hidden.dart').writeAsString('''
class HiddenClass {}
''');
    final result = await tool.execute({'symbol': 'HiddenClass'}, tempDir.path);
    expect(result, contains('No definitions found'));
  });

  test('returns "No definitions found" when no matches', () async {
    await writeFile('foo.dart', 'void hello() {}');
    final result = await tool.execute({'symbol': 'NonExistent'}, tempDir.path);
    expect(result, 'No definitions found for: NonExistent');
  });

  test('max_results limits output', () async {
    // Create 5 Dart files each defining the same class name at top level
    for (var i = 0; i < 5; i++) {
      await File('${tempDir.path}/file$i.dart').writeAsString('class Alpha {}');
    }
    final result = await tool.execute({
      'symbol': 'Alpha',
      'max_results': 3,
    }, tempDir.path);
    final lines = result.trim().split('\n').where((l) => l.isNotEmpty).toList();
    expect(lines.length, lessThanOrEqualTo(3));
  });

  test('path arg restricts search to subdirectory', () async {
    await Directory('${tempDir.path}/sub').create();
    await writeFile('sub/inner.dart', 'class InnerClass {}');
    await writeFile('outer.dart', 'class OuterClass {}');

    final result = await tool.execute({
      'symbol': 'InnerClass',
      'path': 'sub',
    }, tempDir.path);
    expect(result, contains('InnerClass'));
    expect(result, isNot(contains('OuterClass')));
  });

  test('rejects path outside workingDir', () async {
    expect(
      () => tool.execute({'symbol': 'Foo', 'path': '/etc'}, tempDir.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('dryRun returns preview without executing', () async {
    final result = await tool.dryRun({'symbol': 'Foo'}, tempDir.path);
    expect(result.preview, contains('Foo'));
    expect(result.preview, contains('Would search'));
  });

  test('binary / malformed file is skipped gracefully', () async {
    // Write a file with invalid UTF-8 bytes
    final binaryFile = File('${tempDir.path}/binary.dart');
    await binaryFile.writeAsBytes([0xFF, 0xFE, 0x00, 0x01]);

    // Should not throw — returns no matches for the binary content
    final result = await tool.execute({'symbol': 'Anything'}, tempDir.path);
    // Just verify it doesn't crash; result may be "No definitions found"
    expect(result, isA<String>());
  });
}
