import 'dart:convert';
import '../core/types.dart';

/// Detects when the agent is stuck (repeating identical tool calls) or
/// spinning (only making read-only calls without any progress).
class StuckDetector {
  static const _defaultWindow = 3;
  static const _spinWindow = 6;

  /// Exposed for callers that need to slice the log for display.
  static const stuckWindow = _defaultWindow;
  static const spinWindow = _spinWindow;

  // TODO(future): derive this set from ProximaTool metadata (e.g. a
  // `isMutating` property) so new read-only tools are picked up automatically
  // without updating this list.
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

  /// Minimum distinct read-only calls in the window for it to count as
  /// exploration rather than spinning.
  static const _minDistinctReads = 4;

  /// Returns true if the last [window] entries in [toolLog] are all read-only
  /// tools *and* keep revisiting the same targets.
  ///
  /// Read-only-ness alone is not the signal. Reading six different files is how
  /// an agent explores a small codebase before writing — and treating that as
  /// spinning interrupted real work on a six-file project, twice, before the
  /// agent could act. Re-reading the same two files six times is spinning.
  ///
  /// So the window must also be *repetitive*: fewer than [_minDistinctReads]
  /// distinct call fingerprints. Fingerprints include arguments, so reading two
  /// different paths counts as two distinct calls.
  static bool isSpinning(List<ToolCall> toolLog, {int window = _spinWindow}) {
    if (toolLog.length < window) return false;

    final recent = toolLog.sublist(toolLog.length - window);
    if (!recent.every((call) => _readOnlyTools.contains(call.tool))) {
      return false;
    }

    final distinct = recent.map(_fingerprint).toSet().length;
    return distinct < _minDistinctReads;
  }

  /// Create a canonical fingerprint for a tool call (tool name + sorted args).
  static String _fingerprint(ToolCall call) {
    final sortedArgs = Map.fromEntries(
      call.args.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return '${call.tool}:${jsonEncode(sortedArgs)}';
  }
}
