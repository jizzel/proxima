import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/providers/react_extractor.dart';

void main() {
  group('ReActExtractor.extract', () {
    test('parses valid tool_call block', () {
      const text = '''
I need to read a file.
<tool_call>{"tool": "read_file", "args": {"path": "lib/main.dart"}, "reasoning": "need to see contents"}</tool_call>
''';
      final result = ReActExtractor.extract(text);
      expect(result, isNotNull);
      expect(result!.tool, 'read_file');
      expect(result.args['path'], 'lib/main.dart');
      expect(result.reasoning, 'need to see contents');
    });

    test('returns null when no tool_call block', () {
      const text = 'Here is my final answer without any tool calls.';
      expect(ReActExtractor.extract(text), isNull);
    });

    test('throws SchemaViolation for invalid JSON', () {
      const text = '<tool_call>not valid json</tool_call>';
      expect(
        () => ReActExtractor.extract(text),
        throwsA(isA<SchemaViolation>()),
      );
    });

    test('throws SchemaViolation for missing tool field', () {
      const text = '<tool_call>{"args": {}, "reasoning": "test"}</tool_call>';
      expect(
        () => ReActExtractor.extract(text),
        throwsA(isA<SchemaViolation>()),
      );
    });

    test('injects empty string for missing reasoning', () {
      const text = '<tool_call>{"tool": "list_files", "args": {}}</tool_call>';
      final result = ReActExtractor.extract(text);
      expect(result, isNotNull);
      expect(result!.reasoning, '');
    });

    test('handles tool_call block with extra text', () {
      const text =
          'Let me check the files. '
          '<tool_call>{"tool": "glob", "args": {"pattern": "**/*.dart"}, "reasoning": "find all dart files"}</tool_call>'
          ' Done thinking.';
      final result = ReActExtractor.extract(text);
      expect(result, isNotNull);
      expect(result!.tool, 'glob');
    });
  });
}
