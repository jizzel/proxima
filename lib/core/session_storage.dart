import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'session.dart';

/// Persists and loads sessions from `~/.proxima/sessions/<id>.json`.
class SessionStorage {
  final String sessionsDir;

  SessionStorage(String homeDir)
    : sessionsDir = p.join(homeDir, '.proxima', 'sessions');

  static SessionStorage forCurrentUser() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return SessionStorage(home);
  }

  Future<void> save(ProximaSession session) async {
    final dir = Directory(sessionsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(sessionsDir, '${session.id}.json'));
    await file.writeAsString(session.toJsonString());
  }

  Future<ProximaSession?> load(String sessionId) async {
    final file = File(p.join(sessionsDir, '$sessionId.json'));
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return ProximaSession.fromJson(json);
    } catch (e) {
      // Corrupted or incompatible session file — log and return null.
      stderr.writeln(
        '[proxima] Warning: could not load session $sessionId: $e',
      );
      return null;
    }
  }

  Future<List<String>> listSessionIds() async {
    final dir = Directory(sessionsDir);
    if (!await dir.exists()) return [];
    final entities = await dir.list().toList();
    return entities
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toList()
      ..sort();
  }

  Future<ProximaSession?> loadLatest() async {
    final ids = await listSessionIds();
    if (ids.isEmpty) return null;
    return load(ids.last);
  }
}
