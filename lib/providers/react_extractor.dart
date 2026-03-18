import 'dart:convert';
import '../core/types.dart';

/// Parses ReAct-style `<tool_call>...</tool_call>` blocks from raw LLM text.
class ReActExtractor {
  static final _toolCallPattern = RegExp(
    r'<tool_call>(.*?)</tool_call>',
    dotAll: true,
    caseSensitive: false,
  );

  /// Extract a ToolCall from raw text.
  /// Returns null if no tool_call block found.
  /// Throws [SchemaViolation] if block found but malformed.
  static ToolCall? extract(String text) {
    final match = _toolCallPattern.firstMatch(text);
    if (match == null) return null;

    final inner = match.group(1)?.trim() ?? '';
    try {
      final json = jsonDecode(inner) as Map<String, dynamic>;
      return _validate(json, inner);
    } catch (e) {
      if (e is SchemaViolation) rethrow;
      throw SchemaViolation(
        'Invalid JSON in <tool_call>: $e',
        raw: {'text': inner},
      );
    }
  }

  static ToolCall _validate(Map<String, dynamic> json, String raw) {
    final tool = json['tool'];
    if (tool == null || tool is! String || tool.isEmpty) {
      throw SchemaViolation(
        'Missing or invalid "tool" field in tool_call',
        raw: json,
      );
    }

    final args = json['args'];
    if (args != null && args is! Map) {
      throw SchemaViolation('"args" must be a map', raw: json);
    }

    final reasoning = json['reasoning'] as String? ?? '';

    return ToolCall(
      tool: tool,
      args: args != null ? Map<String, dynamic>.from(args as Map) : {},
      reasoning: reasoning,
    );
  }

  /// Build a re-prompt instruction for when extraction failed.
  static String repromptInstruction(String error) =>
      'Your previous response could not be parsed. $error\n\n'
      'Output ONLY a valid <tool_call> block like:\n'
      '<tool_call>{"tool": "tool_name", "args": {}, "reasoning": "why"}</tool_call>';
}
