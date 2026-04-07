import 'dart:convert';
import '../core/types.dart';

/// Detects when the agent is stuck (repeating identical tool calls) or
/// spinning (only making read-only calls without any progress).
class StuckDetector {
  static const _defaultWindow = 3;
  static const _spinWindow = 6;

  /// Exposed for callers that need to slice the log for display.
  static const spinWindow = _spinWindow;

  /// Read-only tools that produce no observable side effects.
  static const _readOnlyTools = {
    'read_file',
    'list_files',
    'glob',
    'search',
    'search_symbol',
    'find_references',
    'get_imports',
    'git_status',
    'git_diff',
    'git_log',
  };

  /// Returns true if the last [window] entries in [toolLog] are all identical.
  static bool isStuck(List<ToolCall> toolLog, {int window = _defaultWindow}) {
    if (toolLog.length < window) return false;

    final recent = toolLog.sublist(toolLog.length - window);
    final first = _fingerprint(recent.first);

    return recent.every((call) => _fingerprint(call) == first);
  }

  /// Returns true if the last [window] entries in [toolLog] are all read-only
  /// tools (no writes, commands, or other mutations). This catches models that
  /// keep reading without ever committing to an action.
  static bool isSpinning(List<ToolCall> toolLog, {int window = _spinWindow}) {
    if (toolLog.length < window) return false;

    final recent = toolLog.sublist(toolLog.length - window);
    return recent.every((call) => _readOnlyTools.contains(call.tool));
  }

  /// Create a canonical fingerprint for a tool call (tool name + sorted args).
  static String _fingerprint(ToolCall call) {
    final sortedArgs = Map.fromEntries(
      call.args.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return '${call.tool}:${jsonEncode(sortedArgs)}';
  }
}
