import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/types.dart';

/// Append-only audit log for all permission decisions.
/// Written to ~/.proxima/audit.jsonl
class AuditLog {
  final String logPath;
  IOSink? _sink;

  AuditLog(String homeDir)
    : logPath = p.join(homeDir, '.proxima', 'audit.jsonl');

  static AuditLog forCurrentUser() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return AuditLog(home);
  }

  Future<void> _ensureOpen() async {
    if (_sink != null) return;
    final file = File(logPath);
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _sink = file.openWrite(mode: FileMode.append);
  }

  Future<void> record({
    required String sessionId,
    required String tool,
    required Map<String, dynamic> args,
    required RiskLevel riskLevel,
    required String decision,
    String? reason,
  }) async {
    await _ensureOpen();
    final entry = {
      'timestamp': DateTime.now().toIso8601String(),
      'session_id': sessionId,
      'tool': tool,
      'args': args,
      'risk_level': riskLevel.name,
      'decision': decision,
      'reason': reason,
    };
    _sink!.writeln(jsonEncode(entry));
    await _sink!.flush();
  }

  Future<void> close() async {
    await _sink?.close();
    _sink = null;
  }
}
