import '../core/types.dart';
import 'risk_classifier.dart';
import 'audit_log.dart';

/// Decision returned by the permission gate.
enum GateDecision { allow, deny, skip }

class PermissionResult {
  final GateDecision decision;
  final String? reason;
  const PermissionResult(this.decision, {this.reason});
}

/// Evaluates every tool call through the permission gate.
/// Flow: blocked → allowlist → mode → prompt (confirm/high_risk)
class PermissionGate {
  final RiskClassifier _classifier;
  final AuditLog _auditLog;
  SessionMode mode;
  final Set<String> _allowedTools;
  final PromptCallback _prompt;

  PermissionGate({
    required RiskClassifier classifier,
    required AuditLog auditLog,
    required this.mode,
    required Set<String> allowedTools,
    required PromptCallback prompt,
  }) : _classifier = classifier,
       _auditLog = auditLog,
       _allowedTools = allowedTools,
       _prompt = prompt;

  /// Evaluate whether [toolCall] can execute.
  /// [sessionId] is used for audit logging.
  /// [deniedTools] is the session-level deny list populated via /deny.
  Future<PermissionResult> evaluate(
    ToolCall toolCall,
    String sessionId, {
    Set<String> deniedTools = const {},
  }) async {
    // 0. Session deny list — belt-and-suspenders check for /deny.
    if (deniedTools.contains(toolCall.tool)) {
      await _auditLog.record(
        sessionId: sessionId,
        tool: toolCall.tool,
        args: toolCall.args,
        riskLevel: RiskLevel.blocked,
        decision: 'denied_by_session',
        reason: 'Tool denied via /deny',
      );
      return const PermissionResult(
        GateDecision.deny,
        reason: 'Tool denied for this session (/deny)',
      );
    }

    final riskLevel = _classifier.classify(toolCall);

    // 1. Blocked — hard reject, no prompt.
    if (riskLevel == RiskLevel.blocked) {
      await _auditLog.record(
        sessionId: sessionId,
        tool: toolCall.tool,
        args: toolCall.args,
        riskLevel: riskLevel,
        decision: 'blocked',
        reason: 'Matched blocked pattern',
      );
      return const PermissionResult(
        GateDecision.deny,
        reason: 'Blocked by security policy',
      );
    }

    // 2. Allow-list — tool was previously allowed this session.
    if (_allowedTools.contains(toolCall.tool)) {
      await _auditLog.record(
        sessionId: sessionId,
        tool: toolCall.tool,
        args: toolCall.args,
        riskLevel: riskLevel,
        decision: 'allowed_via_allowlist',
      );
      return const PermissionResult(
        GateDecision.allow,
        reason: 'In session allowlist',
      );
    }

    // 3. Safe risk level — auto-execute.
    if (riskLevel == RiskLevel.safe) {
      await _auditLog.record(
        sessionId: sessionId,
        tool: toolCall.tool,
        args: toolCall.args,
        riskLevel: riskLevel,
        decision: 'auto_allowed',
        reason: 'Safe risk level',
      );
      return const PermissionResult(GateDecision.allow);
    }

    // 4. Auto mode — execute confirm-level tools without prompt.
    if (mode == SessionMode.auto && riskLevel == RiskLevel.confirm) {
      await _auditLog.record(
        sessionId: sessionId,
        tool: toolCall.tool,
        args: toolCall.args,
        riskLevel: riskLevel,
        decision: 'auto_mode_allowed',
        reason: 'Auto mode',
      );
      return const PermissionResult(GateDecision.allow);
    }

    // 5. Prompt the user.
    final userDecision = await _prompt(toolCall, riskLevel);
    final decision = userDecision ? 'user_approved' : 'user_denied';

    await _auditLog.record(
      sessionId: sessionId,
      tool: toolCall.tool,
      args: toolCall.args,
      riskLevel: riskLevel,
      decision: decision,
    );

    return PermissionResult(
      userDecision ? GateDecision.allow : GateDecision.deny,
      reason: userDecision ? 'User approved' : 'User denied',
    );
  }

  /// Flush and close the underlying audit log. Call on clean exit.
  Future<void> close() => _auditLog.close();
}

/// Callback used by PermissionGate to prompt the user.
typedef PromptCallback =
    Future<bool> Function(ToolCall toolCall, RiskLevel riskLevel);
