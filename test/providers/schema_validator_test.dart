import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/agent/schema_validator.dart';

void main() {
  group('SchemaValidator.validate', () {
    test('validates tool_call response', () {
      final json = {
        'type': 'tool_call',
        'tool': 'read_file',
        'args': {'path': 'lib/main.dart'},
        'reasoning': 'I need to see the file',
      };
      final result = SchemaValidator.validate(json);
      expect(result, isA<ToolCallResponse>());
      final tc = (result as ToolCallResponse).toolCall;
      expect(tc.tool, 'read_file');
      expect(tc.reasoning, 'I need to see the file');
    });

    test('validates final response', () {
      final json = {'type': 'final', 'text': 'Here is the answer.'};
      final result = SchemaValidator.validate(json);
      expect(result, isA<FinalResponse>());
      expect((result as FinalResponse).text, 'Here is the answer.');
    });

    test('validates clarify response', () {
      final json = {'type': 'clarify', 'question': 'Which file do you mean?'};
      final result = SchemaValidator.validate(json);
      expect(result, isA<ClarifyResponse>());
      expect((result as ClarifyResponse).question, 'Which file do you mean?');
    });

    test('validates error response', () {
      final json = {
        'type': 'error',
        'message': 'Something went wrong',
        'code': 'E001',
      };
      final result = SchemaValidator.validate(json);
      expect(result, isA<ErrorResponse>());
      expect((result as ErrorResponse).message, 'Something went wrong');
      expect(result.code, 'E001');
    });

    test('throws SchemaViolation for missing type', () {
      expect(
        () => SchemaValidator.validate({'tool': 'read_file'}),
        throwsA(isA<SchemaViolation>()),
      );
    });

    test('throws SchemaViolation for unknown type', () {
      expect(
        () => SchemaValidator.validate({'type': 'unknown'}),
        throwsA(isA<SchemaViolation>()),
      );
    });

    test('throws SchemaViolation for tool_call missing tool', () {
      expect(
        () => SchemaValidator.validate({'type': 'tool_call', 'args': {}}),
        throwsA(isA<SchemaViolation>()),
      );
    });

    test('throws SchemaViolation for final missing text', () {
      expect(
        () => SchemaValidator.validate({'type': 'final'}),
        throwsA(isA<SchemaViolation>()),
      );
    });

    test('injects empty reasoning if missing from tool_call', () {
      final json = {'type': 'tool_call', 'tool': 'list_files', 'args': {}};
      final result = SchemaValidator.validate(json);
      expect((result as ToolCallResponse).toolCall.reasoning, '');
    });
  });
}
