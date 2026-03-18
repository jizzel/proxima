import 'dart:convert';
import '../core/types.dart';

/// Detects when the agent is stuck (repeating identical tool calls).
class StuckDetector {
  static const _defaultWindow = 3;

  /// Returns true if the last [window] entries in [toolLog] are all identical.
  static bool isStuck(List<ToolCall> toolLog, {int window = _defaultWindow}) {
    if (toolLog.length < window) return false;

    final recent = toolLog.sublist(toolLog.length - window);
    final first = _fingerprint(recent.first);

    return recent.every((call) => _fingerprint(call) == first);
  }

  /// Create a canonical fingerprint for a tool call (tool name + sorted args).
  static String _fingerprint(ToolCall call) {
    final sortedArgs = Map.fromEntries(
      call.args.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return '${call.tool}:${jsonEncode(sortedArgs)}';
  }
}
