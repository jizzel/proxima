import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/tool_registry.dart';
import 'package:proxima/tools/file/read_file_tool.dart';
import 'package:proxima/tools/file/write_file_tool.dart';
import 'package:proxima/tools/file/list_files_tool.dart';
import 'package:proxima/tools/shell/run_command_tool.dart';
import 'package:proxima/permissions/risk_classifier.dart';

void main() {
  late ToolRegistry registry;
  late RiskClassifier classifier;

  setUp(() {
    registry = ToolRegistry();
    registry.register(ReadFileTool());
    registry.register(WriteFileTool());
    registry.register(ListFilesTool());
    registry.register(RunCommandTool());
    classifier = RiskClassifier(registry);
  });

  ToolCall call(String tool, [Map<String, dynamic> args = const {}]) =>
      ToolCall(tool: tool, args: args, reasoning: 'test');

  group('RiskClassifier', () {
    test('read_file is safe', () {
      expect(
        classifier.classify(call('read_file', {'path': 'lib/main.dart'})),
        RiskLevel.safe,
      );
    });

    test('list_files is safe', () {
      expect(classifier.classify(call('list_files')), RiskLevel.safe);
    });

    test('write_file is confirm', () {
      expect(
        classifier.classify(
          call('write_file', {'path': 'a.dart', 'content': ''}),
        ),
        RiskLevel.confirm,
      );
    });

    test('run_command is confirm for safe commands', () {
      expect(
        classifier.classify(call('run_command', {'command': 'dart analyze'})),
        RiskLevel.confirm,
      );
    });

    test('run_command with sudo is blocked', () {
      expect(
        classifier.classify(call('run_command', {'command': 'sudo rm file'})),
        RiskLevel.blocked,
      );
    });

    test('run_command with rm -rf / is blocked', () {
      expect(
        classifier.classify(call('run_command', {'command': 'rm -rf /'})),
        RiskLevel.blocked,
      );
    });

    test('unknown tool is blocked', () {
      expect(classifier.classify(call('unknown_tool')), RiskLevel.blocked);
    });
  });
}
