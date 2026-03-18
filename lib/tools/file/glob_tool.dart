import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class GlobTool implements ProximaTool {
  @override
  String get name => 'glob';

  @override
  String get description =>
      'Find files matching a glob pattern within the working directory.';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': 'Glob pattern like "**/*.dart" or "src/*.ts"',
      },
      'base': {
        'type': 'string',
        'description': 'Base directory for pattern (defaults to working dir)',
      },
    },
    'required': ['pattern'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final pattern = args['pattern'] as String;
    final base = args['base'] as String?;

    final baseDir = base != null
        ? (p.isAbsolute(base) ? base : p.join(workingDir, base))
        : workingDir;

    if (!isSafePath(baseDir, workingDir)) {
      throw ToolError(
        name,
        'Base path "$baseDir" is outside working directory.',
      );
    }

    final matches = await _glob(baseDir, pattern, workingDir);

    if (matches.isEmpty) return 'No files match: $pattern';
    return matches.join('\n');
  }

  Future<List<String>> _glob(
    String baseDir,
    String pattern,
    String workingDir,
  ) async {
    final dir = Directory(baseDir);
    if (!await dir.exists()) return [];

    final regexPattern = _globToRegex(pattern);
    final regex = RegExp(regexPattern);

    final results = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final rel = p.relative(entity.path, from: baseDir);
        if (regex.hasMatch(rel)) {
          results.add(p.relative(entity.path, from: workingDir));
        }
      }
    }

    results.sort();
    return results;
  }

  String _globToRegex(String pattern) {
    final buf = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == '*' && i + 1 < pattern.length && pattern[i + 1] == '*') {
        buf.write('.*');
        i++; // Skip next *.
        if (i + 1 < pattern.length && pattern[i + 1] == '/') i++; // Skip slash.
      } else if (c == '*') {
        buf.write('[^/]*');
      } else if (c == '?') {
        buf.write('[^/]');
      } else if (c == '.') {
        buf.write(r'\.');
      } else if (c == '/') {
        buf.write('/');
      } else {
        buf.write(RegExp.escape(c));
      }
    }
    buf.write(r'$');
    return buf.toString();
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final pattern = args['pattern'] as String;
    return DryRunResult(preview: 'Would glob: $pattern', riskLevel: riskLevel);
  }
}
