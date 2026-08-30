import 'dart:convert';
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/core/session.dart';
import 'package:proxima/core/config.dart';

void main() {
  group('ProximaSession', () {
    late ProximaConfig config;

    setUp(() {
      config = ProximaConfig.defaults();
    });

    test('creates with unique ID', () {
      final s1 = ProximaSession.create(config);
      final s2 = ProximaSession.create(config);
      expect(s1.id, isNot(s2.id));
    });

    test('addMessage appends and updates timestamp', () {
      final session = ProximaSession.create(config);
      final before = session.updatedAt;
      session.addMessage(Message(role: MessageRole.user, content: 'hello'));
      expect(session.history.length, 1);
      expect(
        session.updatedAt.isAfter(before) || session.updatedAt == before,
        isTrue,
      );
    });

    test('recordUsage accumulates tokens', () {
      final session = ProximaSession.create(config);
      session.recordUsage(
        TokenUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15),
      );
      session.recordUsage(
        TokenUsage(inputTokens: 20, outputTokens: 10, totalTokens: 30),
      );
      expect(session.cumulativeUsage.inputTokens, 30);
      expect(session.cumulativeUsage.outputTokens, 15);
      expect(session.cumulativeUsage.totalTokens, 45);
    });

    test('serializes to and from JSON', () {
      final session = ProximaSession.create(config);
      session.addMessage(
        Message(role: MessageRole.user, content: 'test message'),
      );

      final json = jsonDecode(session.toJsonString()) as Map<String, dynamic>;
      final restored = ProximaSession.fromJson(json);

      expect(restored.id, session.id);
      expect(restored.history.length, 1);
      expect(restored.history[0].content, 'test message');
      expect(restored.model, session.model);
    });

    test('permissions can be updated', () {
      final session = ProximaSession.create(config);
      expect(session.permissions.allowedTools, isEmpty);
      session.permissions = session.permissions.withAllowedTool('read_file');
      expect(session.permissions.allowedTools, contains('read_file'));
    });

    test('recordCost accumulates', () {
      final session = ProximaSession.create(config);
      session.recordCost(0.001);
      session.recordCost(0.002);
      expect(session.cumulativeCost, closeTo(0.003, 0.000001));
    });

    test('toJson includes cumulative_cost', () {
      final session = ProximaSession.create(config);
      session.recordCost(1.5);
      final json = jsonDecode(session.toJsonString()) as Map<String, dynamic>;
      expect(json.containsKey('cumulative_cost'), isTrue);
      expect(
        (json['cumulative_cost'] as num).toDouble(),
        closeTo(1.5, 0.000001),
      );
    });

    test('fromJson missing cumulative_cost defaults to 0.0', () {
      final session = ProximaSession.create(config);
      final json = jsonDecode(session.toJsonString()) as Map<String, dynamic>;
      json.remove('cumulative_cost');
      final restored = ProximaSession.fromJson(json);
      expect(restored.cumulativeCost, 0.0);
    });

    test('JSON round-trip preserves cumulative_cost', () {
      final session = ProximaSession.create(config);
      session.recordCost(0.0042);
      final json = jsonDecode(session.toJsonString()) as Map<String, dynamic>;
      final restored = ProximaSession.fromJson(json);
      expect(restored.cumulativeCost, closeTo(0.0042, 0.000001));
    });
    test('masks secrets in tool_input when serialising', () {
      final session = ProximaSession.create(config);
      session.addMessage(
        Message(
          role: MessageRole.assistant,
          content: 'running the command',
          toolName: 'run_command',
          toolCallId: 'call_1',
          toolInput: {
            'command':
                'curl -H "Authorization: Bearer sk-ant-AbCdEfGhIjKlMnOpQrStUv"',
          },
        ),
      );

      final raw = session.toJsonString();
      expect(raw, isNot(contains('sk-ant-')));
      expect(raw, contains('***'));
    });

    test('masks secrets in task_history args when serialising', () {
      final session = ProximaSession.create(config);
      session.addTaskRecord(
        TaskRecord(
          toolName: 'some_plugin',
          args: {'api_key': 'anything-at-all', 'query': 'proxima'},
          timestamp: DateTime.now(),
          success: true,
        ),
      );

      final json = session.toJson();
      final args = (json['task_history'] as List).single['args'] as Map;
      expect(args['api_key'], equals('***'));
      expect(args['query'], equals('proxima'));
    });

    test('does not mask tool result content', () {
      // Tool results are replayed to the model on --resume; masking them would
      // feed *** back and likely cause the tool to be re-run.
      final session = ProximaSession.create(config);
      session.addMessage(
        Message(
          role: MessageRole.tool,
          content: 'total 24\ndrwxr-xr-x  lib',
          toolName: 'run_command',
          toolCallId: 'call_1',
        ),
      );

      final json = session.toJson();
      final msg = (json['history'] as List).single as Map;
      expect(msg['content'], equals('total 24\ndrwxr-xr-x  lib'));
    });

    test('does not mutate the live session when serialising', () {
      // Masking must happen at the serialisation boundary only: the in-memory
      // toolInput is sent to the provider API and read by Compaction.
      final session = ProximaSession.create(config);
      session.addMessage(
        Message(
          role: MessageRole.assistant,
          content: 'reading',
          toolName: 'read_file',
          toolCallId: 'call_1',
          toolInput: {'path': 'lib/main.dart', 'token': 'sk-ant-AbCdEfGhIjKl'},
        ),
      );

      session.toJsonString();

      expect(
        session.history.single.toolInput!['path'],
        equals('lib/main.dart'),
      );
      expect(
        session.history.single.toolInput!['token'],
        equals('sk-ant-AbCdEfGhIjKl'),
      );
    });
  });
  group('TaskStatus persistence', () {
    test('every status round-trips through JSON', () {
      for (final status in TaskStatus.values) {
        final session = ProximaSession.create(ProximaConfig.defaults())
          ..status = status;
        final restored = ProximaSession.fromJson(
          jsonDecode(session.toJsonString()) as Map<String, dynamic>,
        );
        expect(restored.status, equals(status), reason: status.name);
      }
    });

    test('an unrecognised status falls back rather than throwing', () {
      // A session written by a newer build must still load — byName would
      // throw and make the file unreadable.
      final session = ProximaSession.create(ProximaConfig.defaults());
      final json = jsonDecode(session.toJsonString()) as Map<String, dynamic>;
      json['status'] = 'someFutureStatus';

      expect(ProximaSession.fromJson(json).status, equals(TaskStatus.running));
    });
  });
  group('secret masking in message content', () {
    const key = 'sk-ant-FAKE0123456789abcdefGHIJ';

    test('masks a credential pasted into a user prompt', () {
      // Regression: found by testing the shipped binary — masking covered tool
      // *arguments*, so a key typed into a prompt sat verbatim in the session
      // file. A prompt is a plausible place for someone to paste one.
      final session = ProximaSession.create(ProximaConfig.defaults())
        ..addMessage(
          Message(role: MessageRole.user, content: 'use Bearer $key please'),
        );

      final json = session.toJsonString();
      expect(json, isNot(contains(key)));
      expect(json, contains('***'));
    });

    test('leaves tool results verbatim so --resume replays them', () {
      // Deliberate: masking a file's contents would make a resumed session
      // re-run the tools it had already run.
      final session = ProximaSession.create(ProximaConfig.defaults())
        ..addMessage(
          Message(
            role: MessageRole.tool,
            toolName: 'read_file',
            toolCallId: 'c1',
            content: 'const realFileContents = 42;',
          ),
        );

      expect(session.toJsonString(), contains('realFileContents = 42'));
    });

    test('does not touch ordinary prose', () {
      final session = ProximaSession.create(ProximaConfig.defaults())
        ..addMessage(
          Message(role: MessageRole.user, content: 'summarize this codebase'),
        );

      expect(session.toJsonString(), contains('summarize this codebase'));
    });

    test('never masks the live in-memory session', () {
      // Providers send Message.content to the API and Compaction reads it;
      // masking in memory would corrupt both.
      final session = ProximaSession.create(ProximaConfig.defaults())
        ..addMessage(Message(role: MessageRole.user, content: 'Bearer $key'));

      session.toJsonString();
      expect(session.history.single.content, contains(key));
    });
  });
}
