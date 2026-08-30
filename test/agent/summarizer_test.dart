import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/providers/provider_interface.dart';
import 'package:proxima/agent/subagent_runner.dart';

/// Returns a canned body and records the request it was given.
class StubProvider implements LLMProvider {
  final LLMResponseBody _body;
  final bool throws;
  CompletionRequest? lastRequest;

  StubProvider(this._body, {this.throws = false});

  @override
  String get name => 'stub';
  @override
  String get model => 'stub-model';
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: false,
    streaming: false,
    contextWindow: 8192,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    lastRequest = request;
    if (throws) throw LLMError(LLMErrorKind.network, 'boom');
    return LLMResponse(
      body: _body,
      usage: const TokenUsage(
        inputTokens: 120,
        outputTokens: 30,
        totalTokens: 150,
      ),
    );
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) async* {}
  @override
  Future<List<String>> listModels() async => [];
}

void main() {
  List<Message> sampleHistory() => [
    Message(role: MessageRole.user, content: 'add a retry to the client'),
    Message(
      role: MessageRole.assistant,
      content: 'reading the file',
      toolName: 'read_file',
      toolCallId: 'c1',
      toolInput: {'path': 'lib/client.dart'},
    ),
    Message(
      role: MessageRole.tool,
      content: 'class Client {}',
      toolName: 'read_file',
      toolCallId: 'c1',
    ),
  ];

  group('SubagentRunner.runSummarizer', () {
    test('returns the summary text', () async {
      final provider = StubProvider(
        FinalResponse('- read lib/client.dart\n- added retry logic'),
      );

      final summary = await SubagentRunner(
        provider: provider,
      ).runSummarizer(messages: sampleHistory(), model: 'm');

      expect(summary!.text, contains('lib/client.dart'));
      expect(summary.text, contains('retry'));
      expect(summary.usage, isNotNull, reason: 'usage must be reported');
    });

    test('sends no tools and a bounded max_tokens', () async {
      final provider = StubProvider(FinalResponse('- x'));

      await SubagentRunner(
        provider: provider,
      ).runSummarizer(messages: sampleHistory(), model: 'm', maxTokens: 256);

      expect(provider.lastRequest!.tools, isEmpty);
      expect(provider.lastRequest!.maxTokens, equals(256));
      expect(provider.lastRequest!.stream, isFalse);
    });

    test('includes each role and the tool name in the transcript', () async {
      final provider = StubProvider(FinalResponse('- x'));

      await SubagentRunner(
        provider: provider,
      ).runSummarizer(messages: sampleHistory(), model: 'm');

      final sent = provider.lastRequest!.messages.single.content;
      expect(sent, contains('User:'));
      expect(sent, contains('Assistant:'));
      expect(sent, contains('Tool(read_file)'));
    });

    test(
      'caps an oversized message so one result cannot crowd out the rest',
      () async {
        final provider = StubProvider(FinalResponse('- x'));
        final huge = Message(
          role: MessageRole.tool,
          content: 'z' * 10000,
          toolName: 'read_file',
        );

        await SubagentRunner(
          provider: provider,
        ).runSummarizer(messages: [huge], model: 'm');

        final sent = provider.lastRequest!.messages.single.content;
        expect(sent.length, lessThan(3000));
        expect(sent, contains('…'));
      },
    );

    test('bounds the whole transcript, not just each message', () async {
      // Regression: capping each message at 2000 chars still let a session
      // that drops hundreds of messages build an unbounded transcript — busting
      // the context window exactly when summarising matters most.
      final provider = StubProvider(FinalResponse('- x'));
      final many = [
        for (var i = 0; i < 500; i++)
          Message(role: MessageRole.user, content: 'message $i ${"w" * 1500}'),
      ];

      await SubagentRunner(
        provider: provider,
      ).runSummarizer(messages: many, model: 'm', maxTranscriptChars: 8000);

      final sent = provider.lastRequest!.messages.single.content;
      expect(sent.length, lessThanOrEqualTo(9000));
    });

    test('keeps the newest messages when it must drop some', () async {
      final provider = StubProvider(FinalResponse('- x'));
      final many = [
        for (var i = 0; i < 50; i++)
          Message(role: MessageRole.user, content: 'MARK$i ${"w" * 1500}'),
      ];

      await SubagentRunner(
        provider: provider,
      ).runSummarizer(messages: many, model: 'm', maxTranscriptChars: 6000);

      final sent = provider.lastRequest!.messages.single.content;
      expect(sent, contains('MARK49'), reason: 'newest kept');
      expect(sent, isNot(contains('MARK0')), reason: 'oldest dropped');
    });

    test('always sends at least one message', () async {
      final provider = StubProvider(FinalResponse('- x'));
      await SubagentRunner(provider: provider).runSummarizer(
        messages: [Message(role: MessageRole.user, content: 'q' * 5000)],
        model: 'm',
        maxTranscriptChars: 10,
      );
      expect(provider.lastRequest, isNotNull);
    });

    test('reports the tokens the summary cost', () async {
      // Regression: usage was discarded, so every summarisation request was
      // missing from the session's token and cost totals.
      final summary = await SubagentRunner(
        provider: StubProvider(FinalResponse('- x')),
      ).runSummarizer(messages: sampleHistory(), model: 'm');

      expect(summary!.usage.totalTokens, equals(150));
    });

    test('includes tool arguments so files can be named', () async {
      // Regression: an assistant tool-call message keeps its path in toolInput
      // and often has empty content, and a read_file *result* is numbered file
      // text with no path — so the transcript could not identify files read.
      final provider = StubProvider(FinalResponse('- x'));
      await SubagentRunner(
        provider: provider,
      ).runSummarizer(messages: sampleHistory(), model: 'm');

      expect(
        provider.lastRequest!.messages.single.content,
        contains('lib/client.dart'),
      );
    });

    test('masks secrets in tool arguments', () async {
      final provider = StubProvider(FinalResponse('- x'));
      await SubagentRunner(provider: provider).runSummarizer(
        messages: [
          Message(
            role: MessageRole.assistant,
            content: '',
            toolName: 'run_command',
            toolInput: {
              'command':
                  'curl -H "Authorization: Bearer sk-ant-AbCdEfGhIjKlMnOpQrSt"',
            },
          ),
        ],
        model: 'm',
      );

      final sent = provider.lastRequest!.messages.single.content;
      expect(sent, isNot(contains('sk-ant-')));
      expect(sent, contains('***'));
    });

    test('returns null on a provider error', () async {
      final summary = await SubagentRunner(
        provider: StubProvider(FinalResponse('unused'), throws: true),
      ).runSummarizer(messages: sampleHistory(), model: 'm');

      expect(summary, isNull);
    });

    test('returns null for a non-final response body', () async {
      final summary = await SubagentRunner(
        provider: StubProvider(
          ToolCallResponse(ToolCall(tool: 'x', args: const {}, reasoning: '')),
        ),
      ).runSummarizer(messages: sampleHistory(), model: 'm');

      expect(summary, isNull);
    });

    test('returns null for an empty summary', () async {
      final summary = await SubagentRunner(
        provider: StubProvider(FinalResponse('   ')),
      ).runSummarizer(messages: sampleHistory(), model: 'm');

      expect(summary, isNull);
    });

    test('returns null without calling the provider for empty input', () async {
      final provider = StubProvider(FinalResponse('- x'));
      final summary = await SubagentRunner(
        provider: provider,
      ).runSummarizer(messages: const [], model: 'm');

      expect(summary, isNull);
      expect(provider.lastRequest, isNull);
    });
  });
}
