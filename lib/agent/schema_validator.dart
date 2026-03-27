import '../core/types.dart';

/// Validates LLM response maps against the 4 known response types.
/// Returns typed [LLMResponseBody] or throws [SchemaViolation].
class SchemaValidator {
  static LLMResponseBody validate(Map<String, dynamic> json) {
    final type = json['type'];
    if (type == null || type is! String) {
      throw SchemaViolation(
        'Missing or invalid "type" field. Expected one of: tool_call, final, clarify, error.',
        raw: json,
      );
    }

    return switch (type) {
      'tool_call' => _validateToolCall(json),
      'final' => _validateFinal(json),
      'clarify' => _validateClarify(json),
      'error' => _validateError(json),
      _ => throw SchemaViolation('Unknown response type "$type".', raw: json),
    };
  }

  static ToolCallResponse _validateToolCall(Map<String, dynamic> json) {
    final tool = json['tool'];
    if (tool == null || tool is! String || tool.isEmpty) {
      throw SchemaViolation(
        'tool_call response missing "tool" field.',
        raw: json,
      );
    }

    final args = json['args'];
    if (args != null && args is! Map) {
      throw SchemaViolation('tool_call "args" must be an object.', raw: json);
    }

    // reasoning is required — inject empty string if missing, log warning.
    final reasoning = json['reasoning'] as String? ?? '';

    return ToolCallResponse(
      ToolCall(
        tool: tool,
        args: args != null ? Map<String, dynamic>.from(args as Map) : {},
        reasoning: reasoning,
        callId: json['call_id'] as String?,
      ),
    );
  }

  static FinalResponse _validateFinal(Map<String, dynamic> json) {
    final text = json['text'];
    if (text == null || text is! String) {
      throw SchemaViolation('final response missing "text" field.', raw: json);
    }
    return FinalResponse(text);
  }

  static ClarifyResponse _validateClarify(Map<String, dynamic> json) {
    final question = json['question'] as String? ?? '';
    if (question.isEmpty) {
      throw SchemaViolation(
        'clarify response missing "question" field.',
        raw: json,
      );
    }
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? rawOptions.whereType<String>().toList()
        : const <String>[];
    return ClarifyResponse(question, options: options);
  }

  static ErrorResponse _validateError(Map<String, dynamic> json) {
    final message = json['message'] as String? ?? 'Unknown error';
    final code = json['code'] as String?;
    return ErrorResponse(message, code: code);
  }
}
