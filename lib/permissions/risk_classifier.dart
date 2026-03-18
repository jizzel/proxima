import '../core/types.dart';
import '../tools/tool_registry.dart';
import 'blocked_patterns.dart';

/// Classifies a tool call's risk level.
class RiskClassifier {
  final ToolRegistry _registry;

  RiskClassifier(this._registry);

  /// Returns the risk level for executing [toolCall].
  RiskLevel classify(ToolCall toolCall) {
    // Check blocked shell commands first.
    if (toolCall.tool == 'run_command') {
      final command = toolCall.args['command'] as String? ?? '';
      if (isBlockedCommand(command)) return RiskLevel.blocked;
    }

    // Check blocked path patterns.
    for (final argKey in ['path', 'old_str', 'new_str']) {
      final val = toolCall.args[argKey] as String?;
      if (val != null && isBlockedPath(val)) return RiskLevel.blocked;
    }

    // Look up the tool's declared risk level.
    final tool = _registry.lookup(toolCall.tool);
    if (tool == null) return RiskLevel.blocked; // Unknown tool = blocked.

    return tool.riskLevel;
  }
}
