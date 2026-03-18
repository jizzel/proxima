import 'dart:io';
import '../core/types.dart';
import '../core/session.dart';
import 'ansi_helpers.dart';

/// Renders task failure summaries and stuck dialogs.
class TaskSummaryRenderer {
  static void renderFailure(String reason, List<TaskRecord>? tasks) {
    stdout.writeln('');
    stdout.writeln(boldRed('✗ Task failed'));
    stdout.writeln(red('  Reason: $reason'));
    if (tasks != null && tasks.isNotEmpty) {
      stdout.writeln(dim('  Actions taken:'));
      for (final task in tasks) {
        final status = task.success ? green('✓') : red('✗');
        stdout.writeln(dim('    $status ${task.toolName}(${task.args})'));
      }
    }
  }

  static void renderStuck(List<ToolCall> recentCalls) {
    stdout.writeln('');
    stdout.writeln(boldYellow('⚠  Agent appears stuck'));
    stdout.writeln(yellow('   Repeated tool calls detected:'));
    for (final call in recentCalls) {
      stdout.writeln(dim('   → ${call.tool}(${call.args})'));
    }
    stdout.writeln(yellow('   Stopping to avoid infinite loop.'));
    stdout.writeln(dim('   Try rephrasing your request or using /clear'));
  }

  static void renderMaxIterations(int max) {
    stdout.writeln('');
    stdout.writeln(yellow('⚠  Reached maximum iterations ($max)'));
    stdout.writeln(
      dim('   The task may be incomplete. Try /undo to revert changes.'),
    );
  }

  static void renderSuccess(String summary) {
    stdout.writeln('');
    stdout.writeln(boldGreen('✓ $summary'));
  }
}
