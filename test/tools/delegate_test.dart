import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/tools/agent/delegate_tool.dart';
import 'package:proxima/agent/subagent_runner.dart' show SubagentType;

void main() {
  late DelegateToSubagentTool tool;

  setUp(() => tool = DelegateToSubagentTool());

  group('DelegateToSubagentTool', () {
    test('every advertised agent is one SubagentRunner accepts', () {
      // The schema enum and SubagentType.fromString are maintained separately;
      // if they drift, the model is offered an agent that throws at dispatch.
      final advertised =
          (tool.inputSchema['properties'] as Map)['agent']['enum'] as List;

      expect(advertised, isNotEmpty);
      for (final agent in advertised) {
        expect(
          () => SubagentType.fromString(agent as String),
          returnsNormally,
          reason: '$agent is offered to the model but not accepted',
        );
      }
    });

    test('does not advertise critic — it is internal to write review', () {
      final advertised =
          (tool.inputSchema['properties'] as Map)['agent']['enum'] as List;
      expect(advertised, isNot(contains('critic')));
    });

    test('requires agent, task, and context', () {
      expect(
        tool.inputSchema['required'],
        containsAll(['agent', 'task', 'context']),
      );
    });

    test('execute always throws — the loop must intercept it first', () async {
      // This tool is a schema carrier, not an implementation: reaching
      // execute() means the agent loop failed to route the call.
      // Thrown synchronously, so wrap the call itself rather than the future
      // it would otherwise have returned.
      expect(
        () => tool.execute({
          'agent': 'code_analyzer',
          'task': 't',
          'context': 'c',
        }, '/tmp'),
        throwsA(isA<ToolError>()),
      );
    });

    test('is classified safe — it never touches the filesystem', () {
      expect(tool.riskLevel, equals(RiskLevel.safe));
    });

    test('dryRun previews the delegation', () async {
      final result = await tool.dryRun({
        'agent': 'refactor',
        'task': 'extract a helper',
        'context': 'x',
      }, '/tmp');
      expect(result.preview, contains('refactor'));
      expect(result.preview, contains('extract a helper'));
    });

    test('dryRun tolerates missing args', () async {
      final result = await tool.dryRun({}, '/tmp');
      expect(result.preview, isNotEmpty);
    });
  });
}
