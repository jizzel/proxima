import '../core/types.dart';
import 'provider_interface.dart';
import 'react_extractor.dart';

/// Wraps any provider that lacks native tool use.
/// Injects a ReAct system prompt and extracts `<tool_call>` blocks from responses.
class ReActFallback implements LLMProvider {
  final LLMProvider _inner;

  ReActFallback(this._inner);

  @override
  String get name => _inner.name;

  @override
  String get model => _inner.model;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities(
    nativeToolUse: false,
    streaming: _inner.capabilities.streaming,
    contextWindow: _inner.capabilities.contextWindow,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    final augmented = _augmentRequest(request);
    final response = await _inner.complete(augmented);

    if (response.body is FinalResponse) {
      final text = (response.body as FinalResponse).text;
      final toolCall = ReActExtractor.extract(text);
      if (toolCall != null) {
        return LLMResponse(
          body: ToolCallResponse(toolCall),
          usage: response.usage,
          rawText: text,
        );
      }
    }

    return response;
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) {
    final augmented = _augmentRequest(request);
    return _inner.stream(augmented);
  }

  @override
  Future<List<String>> listModels() => _inner.listModels();

  CompletionRequest _augmentRequest(CompletionRequest request) {
    if (request.tools.isEmpty) return request;

    final toolDocs = request.tools.map((t) {
      final props = t.inputSchema['properties'] as Map? ?? {};
      final required = (t.inputSchema['required'] as List?)?.cast<String>() ?? [];
      final argList = props.entries.map((e) {
        final isReq = required.contains(e.key);
        final type = (e.value as Map?)?['type'] ?? 'string';
        return isReq ? '${e.key}: $type' : '${e.key}?: $type';
      }).join(', ');
      return '  { "name": "${t.name}", "args": {$argList} }  // ${t.description}';
    }).join('\n');

    final toolNames = request.tools.map((t) => '"${t.name}"').join(', ');

    final reactPrompt = '''
You are a coding agent. You can call tools to help the user.

TOOL CALL FORMAT — when you need a tool, output ONLY this block and nothing else:
<tool_call>{"tool": "<exact_tool_name>", "args": {<args>}, "reasoning": "<why>"}</tool_call>

CRITICAL: The "tool" field MUST be one of these exact strings: $toolNames
Do NOT add suffixes like "_tool", do NOT invent names. Copy the name exactly.

Available tools:
$toolDocs

When you have a final answer and need no more tools, respond normally (no <tool_call> block).
NEVER mix a <tool_call> block with other text.
''';

    return CompletionRequest(
      model: request.model,
      systemPrompt: '$reactPrompt\n\n${request.systemPrompt}'.trim(),
      messages: request.messages,
      tools: request.tools,
      maxTokens: request.maxTokens,
      temperature: request.temperature,
      stream: request.stream,
    );
  }
}
