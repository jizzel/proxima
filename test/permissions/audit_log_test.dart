import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/permissions/audit_log.dart';

void main() {
  late Directory tempDir;
  late AuditLog auditLog;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_audit_');
    auditLog = AuditLog(tempDir.path);
  });

  tearDown(() async {
    await auditLog.close();
    await tempDir.delete(recursive: true);
  });

  /// Reads back the single JSONL entry written to the log.
  Future<Map<String, dynamic>> readEntry() async {
    await auditLog.close();
    final file = File(p.join(tempDir.path, '.proxima', 'audit.jsonl'));
    final lines = await file.readAsLines();
    return jsonDecode(lines.single) as Map<String, dynamic>;
  }

  group('AuditLog', () {
    test('records a decision with its fields', () async {
      await auditLog.record(
        sessionId: 'sess-1',
        tool: 'read_file',
        args: {'path': 'lib/main.dart'},
        riskLevel: RiskLevel.safe,
        decision: 'auto_allowed',
        reason: 'Safe risk level',
      );

      final entry = await readEntry();
      expect(entry['session_id'], equals('sess-1'));
      expect(entry['tool'], equals('read_file'));
      expect(entry['risk_level'], equals('safe'));
      expect(entry['decision'], equals('auto_allowed'));
      expect(entry['reason'], equals('Safe risk level'));
      expect((entry['args'] as Map)['path'], equals('lib/main.dart'));
    });

    test('masks a secret embedded in a run_command argument', () async {
      await auditLog.record(
        sessionId: 'sess-2',
        tool: 'run_command',
        args: {
          'command':
              'curl -H "Authorization: Bearer sk-ant-AbCdEfGhIjKlMnOpQrStUv"',
        },
        riskLevel: RiskLevel.confirm,
        decision: 'user_approved',
      );

      final entry = await readEntry();
      final command = (entry['args'] as Map)['command'] as String;
      expect(command, isNot(contains('sk-ant-')));
      expect(command, contains('***'));
      // The non-secret part of the command is preserved for auditability.
      expect(command, contains('curl'));
    });

    test('masks a value whose argument name is sensitive', () async {
      await auditLog.record(
        sessionId: 'sess-3',
        tool: 'some_plugin',
        args: {'api_key': 'anything-at-all', 'query': 'proxima'},
        riskLevel: RiskLevel.confirm,
        decision: 'user_approved',
      );

      final entry = await readEntry();
      final args = entry['args'] as Map;
      expect(args['api_key'], equals('***'));
      expect(args['query'], equals('proxima'));
    });

    test('raw secret never appears anywhere in the log file', () async {
      const secret = 'sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789';
      await auditLog.record(
        sessionId: 'sess-4',
        tool: 'run_command',
        args: {'command': 'echo $secret'},
        riskLevel: RiskLevel.confirm,
        decision: 'user_approved',
      );

      await auditLog.close();
      final raw = await File(
        p.join(tempDir.path, '.proxima', 'audit.jsonl'),
      ).readAsString();
      expect(raw, isNot(contains(secret)));
      expect(raw, contains('***'));
    });

    test('appends successive entries', () async {
      await auditLog.record(
        sessionId: 'sess-5',
        tool: 'read_file',
        args: {'path': 'a.dart'},
        riskLevel: RiskLevel.safe,
        decision: 'auto_allowed',
      );
      await auditLog.record(
        sessionId: 'sess-5',
        tool: 'read_file',
        args: {'path': 'b.dart'},
        riskLevel: RiskLevel.safe,
        decision: 'auto_allowed',
      );

      await auditLog.close();
      final lines = await File(
        p.join(tempDir.path, '.proxima', 'audit.jsonl'),
      ).readAsLines();
      expect(lines.length, equals(2));
    });
  });
}
