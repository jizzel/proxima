import 'dart:io';
import '../core/types.dart';
import '../core/session.dart';
import 'ansi_helpers.dart';
import 'picker_widget.dart';

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

  /// Shows the stuck dialog and returns true if the user wants to continue,
  /// false to abort.
  static bool renderStuck(List<ToolCall> recentCalls) {
    stdout.writeln('');
    stdout.writeln(boldYellow('⚠  Agent appears stuck'));
    stdout.writeln(yellow('   Repeated tool calls detected:'));
    for (final call in recentCalls) {
      stdout.writeln(dim('   → ${call.tool}(${call.args})'));
    }
    stdout.writeln('');
    final idx = PickerWidget.pick(
      options: ['Continue', 'Abort'],
      hints: ['let the agent try again', 'stop and return to prompt'],
      defaultIndex: 1,
    );
    stdout.writeln('');
    return idx == 0;
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
