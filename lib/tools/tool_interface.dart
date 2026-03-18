import '../core/types.dart';

/// Result of a dry-run (preview without side effects).
class DryRunResult {
  final String preview;
  final RiskLevel riskLevel;
  final String? diffText;

  const DryRunResult({
    required this.preview,
    required this.riskLevel,
    this.diffText,
  });
}

/// Abstract base for all Proxima tools.
abstract class ProximaTool {
  /// Unique tool name (snake_case).
  String get name;

  /// Human-readable description shown to the LLM.
  String get description;

  /// Risk level used by the permission gate.
  RiskLevel get riskLevel;

  /// JSON Schema for the tool's input parameters.
  Map<String, dynamic> get inputSchema;

  /// Execute the tool with validated [args] in [workingDir].
  /// Throws [ToolError] on failure.
  Future<String> execute(Map<String, dynamic> args, String workingDir);

  /// Preview what the tool would do without side effects.
  Future<DryRunResult> dryRun(Map<String, dynamic> args, String workingDir);
}

/// Thrown when a tool encounters an error.
class ToolError implements Exception {
  final String tool;
  final String message;
  final bool retryable;

  const ToolError(this.tool, this.message, {this.retryable = false});

  @override
  String toString() => 'ToolError($tool): $message';
}
