import 'dart:io';
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/tool_registry.dart';
import 'package:proxima/tools/file/read_file_tool.dart';
import 'package:proxima/tools/file/write_file_tool.dart';
import 'package:proxima/tools/shell/run_command_tool.dart';
import 'package:proxima/permissions/risk_classifier.dart';
import 'package:proxima/permissions/audit_log.dart';
import 'package:proxima/permissions/permission_gate.dart';

void main() {
  late Directory tempDir;
  late ToolRegistry registry;
  late RiskClassifier classifier;
  late AuditLog auditLog;
  bool promptCalled = false;
  bool promptResult = true;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_gate_');
    registry = ToolRegistry();
    registry.register(ReadFileTool());
    registry.register(WriteFileTool());
    registry.register(RunCommandTool());
    classifier = RiskClassifier(registry);
    auditLog = AuditLog(tempDir.path);
    promptCalled = false;
    promptResult = true;
  });

  tearDown(() async {
    await auditLog.close();
    await tempDir.delete(recursive: true);
  });

  PermissionGate makeGate({
    SessionMode mode = SessionMode.confirm,
    Set<String> allowedTools = const {},
  }) => PermissionGate(
    classifier: classifier,
    auditLog: auditLog,
    mode: mode,
    allowedTools: allowedTools,
    prompt: (toolCall, riskLevel, {criticResult}) async {
      promptCalled = true;
      return promptResult;
    },
  );

  ToolCall call(String tool, [Map<String, dynamic> args = const {}]) =>
      ToolCall(tool: tool, args: args, reasoning: '');

  group('PermissionGate', () {
    test('auto-allows safe tools without prompt', () async {
      final gate = makeGate();
      final result = await gate.evaluate(
        call('read_file', {'path': 'a.dart'}),
        'sess1',
      );
      expect(result.decision, GateDecision.allow);
      expect(promptCalled, isFalse);
    });

    test('prompts for confirm-level tools in confirm mode', () async {
      promptResult = true;
      final gate = makeGate(mode: SessionMode.confirm);
      final result = await gate.evaluate(
        call('write_file', {'path': 'a.dart', 'content': ''}),
        'sess1',
      );
      expect(result.decision, GateDecision.allow);
      expect(promptCalled, isTrue);
    });

    test('denies when user says no at prompt', () async {
      promptResult = false;
      final gate = makeGate(mode: SessionMode.confirm);
      final result = await gate.evaluate(
        call('write_file', {'path': 'a.dart', 'content': ''}),
        'sess1',
      );
      expect(result.decision, GateDecision.deny);
    });

    test('auto-allows confirm tools in auto mode without prompt', () async {
      final gate = makeGate(mode: SessionMode.auto);
      final result = await gate.evaluate(
        call('write_file', {'path': 'a.dart', 'content': ''}),
        'sess1',
      );
      expect(result.decision, GateDecision.allow);
      expect(promptCalled, isFalse);
    });

    test('blocks blocked commands without prompt', () async {
      final gate = makeGate();
      final result = await gate.evaluate(
        call('run_command', {'command': 'sudo rm -rf /'}),
        'sess1',
      );
      expect(result.decision, GateDecision.deny);
      expect(promptCalled, isFalse);
    });

    test('allows tools in allowlist without prompt', () async {
      final gate = makeGate(allowedTools: {'write_file'});
      final result = await gate.evaluate(
        call('write_file', {'path': 'a.dart', 'content': ''}),
        'sess1',
      );
      expect(result.decision, GateDecision.allow);
      expect(promptCalled, isFalse);
    });

    test('safe mode blocks confirm-level tools without prompt', () async {
      final gate = makeGate(mode: SessionMode.safe);
      final result = await gate.evaluate(
        call('write_file', {'path': 'a.dart', 'content': ''}),
        'sess1',
      );
      expect(result.decision, GateDecision.deny);
      expect(promptCalled, isFalse);
      expect(result.reason, contains('safe'));
    });

    test('safe mode still allows safe-level tools', () async {
      final gate = makeGate(mode: SessionMode.safe);
      final result = await gate.evaluate(
        call('read_file', {'path': 'a.dart'}),
        'sess1',
      );
      expect(result.decision, GateDecision.allow);
      expect(promptCalled, isFalse);
    });

    test('denied tool is rejected before risk classification', () async {
      final gate = makeGate();
      final result = await gate.evaluate(
        call('read_file', {'path': 'a.dart'}),
        'sess1',
        deniedTools: {'read_file'},
      );
      expect(result.decision, GateDecision.deny);
      expect(promptCalled, isFalse);
    });
  });
}
