/// Shared enums, value types, and sealed classes used across all layers.
library;

// ─── Risk & Mode ─────────────────────────────────────────────────────────────

enum RiskLevel { safe, confirm, highRisk, blocked }

enum SessionMode { safe, confirm, auto }

// ─── Task / Agent ────────────────────────────────────────────────────────────

enum TaskStatus { running, completed, failed }

enum ResponseType { toolCall, final_, clarify, error }

// ─── Messages ────────────────────────────────────────────────────────────────

enum MessageRole { system, user, assistant, tool }

class Message {
  final MessageRole role;
  final String content;
  final String? toolName;
  final String? toolCallId;
  final Map<String, dynamic>? toolInput;

  const Message({
    required this.role,
    required this.content,
    this.toolName,
    this.toolCallId,
    this.toolInput,
  });

  Map<String, dynamic> toJson() => {
    'role': role.name,
    'content': content,
    if (toolName != null) 'tool_name': toolName,
    if (toolCallId != null) 'tool_call_id': toolCallId,
    if (toolInput != null) 'tool_input': toolInput,
  };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    role: MessageRole.values.byName(json['role'] as String),
    content: json['content'] as String,
    toolName: json['tool_name'] as String?,
    toolCallId: json['tool_call_id'] as String?,
    toolInput: json['tool_input'] as Map<String, dynamic>?,
  );

  Message copyWith({String? content}) => Message(
    role: role,
    content: content ?? this.content,
    toolName: toolName,
    toolCallId: toolCallId,
    toolInput: toolInput,
  );
}

// ─── LLM Response ────────────────────────────────────────────────────────────

class ToolCall {
  final String tool;
  final Map<String, dynamic> args;
  final String reasoning;
  final String? callId;

  const ToolCall({
    required this.tool,
    required this.args,
    required this.reasoning,
    this.callId,
  });

  Map<String, dynamic> toJson() => {
    'tool': tool,
    'args': args,
    'reasoning': reasoning,
    if (callId != null) 'call_id': callId,
  };

  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
    tool: json['tool'] as String,
    args: Map<String, dynamic>.from(json['args'] as Map? ?? {}),
    reasoning: json['reasoning'] as String? ?? '',
    callId: json['call_id'] as String?,
  );
}

sealed class LLMResponseBody {}

class ToolCallResponse extends LLMResponseBody {
  final ToolCall toolCall;
  ToolCallResponse(this.toolCall);
}

class FinalResponse extends LLMResponseBody {
  final String text;
  FinalResponse(this.text);
}

class ClarifyResponse extends LLMResponseBody {
  final String question;
  final List<String> options;
  ClarifyResponse(this.question, {this.options = const []});
}

class ErrorResponse extends LLMResponseBody {
  final String message;
  final String? code;
  ErrorResponse(this.message, {this.code});
}

// ─── Token Usage ─────────────────────────────────────────────────────────────

class TokenUsage {
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;

  const TokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
  });

  TokenUsage operator +(TokenUsage other) => TokenUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    totalTokens: totalTokens + other.totalTokens,
  );

  Map<String, dynamic> toJson() => {
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'total_tokens': totalTokens,
  };

  factory TokenUsage.fromJson(Map<String, dynamic> json) => TokenUsage(
    inputTokens: json['input_tokens'] as int? ?? 0,
    outputTokens: json['output_tokens'] as int? ?? 0,
    totalTokens: json['total_tokens'] as int? ?? 0,
  );

  static const zero = TokenUsage(
    inputTokens: 0,
    outputTokens: 0,
    totalTokens: 0,
  );
}

// ─── Tool Result ─────────────────────────────────────────────────────────────

class ToolResult {
  final String toolName;
  final String callId;
  final String output;
  final bool isError;

  const ToolResult({
    required this.toolName,
    required this.callId,
    required this.output,
    this.isError = false,
  });
}

// ─── Schema Violation ────────────────────────────────────────────────────────

class SchemaViolation implements Exception {
  final String message;
  final Map<String, dynamic>? raw;
  SchemaViolation(this.message, {this.raw});

  @override
  String toString() => 'SchemaViolation: $message';
}

// ─── LLM Error ───────────────────────────────────────────────────────────────

enum LLMErrorKind {
  network,
  auth,
  rateLimit,
  schemaViolation,
  timeout,
  unknown,
}

class LLMError implements Exception {
  final LLMErrorKind kind;
  final String message;
  const LLMError(this.kind, this.message);

  @override
  String toString() => 'LLMError(${kind.name}): $message';
}
