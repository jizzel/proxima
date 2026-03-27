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
  });
}
