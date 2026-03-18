import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class SearchTool implements ProximaTool {
  @override
  String get name => 'search';

  @override
  String get description =>
      'Search for a regex pattern in files within the working directory.';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': 'Regex pattern to search for',
      },
      'path': {
        'type': 'string',
        'description':
            'Directory or file to search in (defaults to working dir)',
      },
      'file_pattern': {
        'type': 'string',
        'description': 'Glob pattern to filter files (e.g., "*.dart")',
      },
      'case_insensitive': {
        'type': 'boolean',
        'description': 'Case-insensitive search (default false)',
      },
      'context_lines': {
        'type': 'integer',
        'description': 'Lines of context around matches (default 2)',
      },
    },
    'required': ['pattern'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final pattern = args['pattern'] as String;
    final relPath = args['path'] as String?;
    final filePattern = args['file_pattern'] as String?;
    final caseInsensitive = args['case_insensitive'] as bool? ?? false;
    final contextLines = args['context_lines'] as int? ?? 2;

    final searchPath = relPath != null
        ? (p.isAbsolute(relPath) ? relPath : p.join(workingDir, relPath))
        : workingDir;

    if (!isSafePath(searchPath, workingDir)) {
      throw ToolError(name, 'Path "$searchPath" is outside working directory.');
    }

    RegExp regex;
    try {
      regex = RegExp(pattern, caseSensitive: !caseInsensitive, multiLine: true);
    } catch (e) {
      throw ToolError(name, 'Invalid regex pattern: $e');
    }

    final fileRegex = filePattern != null ? _globToRegex(filePattern) : null;

    final results = <String>[];
    await _searchPath(
      searchPath,
      regex,
      fileRegex,
      workingDir,
      contextLines,
      results,
    );

    if (results.isEmpty) return 'No matches found for: $pattern';
    return results.join('\n---\n');
  }

  Future<void> _searchPath(
    String searchPath,
    RegExp regex,
    RegExp? fileRegex,
    String workingDir,
    int contextLines,
    List<String> results,
  ) async {
    final entity = await FileSystemEntity.type(searchPath);

    if (entity == FileSystemEntityType.file) {
      await _searchFile(
        File(searchPath),
        regex,
        workingDir,
        contextLines,
        results,
      );
    } else if (entity == FileSystemEntityType.directory) {
      await for (final file in Directory(
        searchPath,
      ).list(recursive: true, followLinks: false)) {
        if (file is! File) continue;
        if (fileRegex != null) {
          final rel = p.relative(file.path, from: workingDir);
          if (!fileRegex.hasMatch(p.basename(rel))) continue;
        }
        await _searchFile(file, regex, workingDir, contextLines, results);
      }
    }
  }

  Future<void> _searchFile(
    File file,
    RegExp regex,
    String workingDir,
    int contextLines,
    List<String> results,
  ) async {
    try {
      final lines = await file.readAsLines();
      final matchedLines = <int>[];

      for (var i = 0; i < lines.length; i++) {
        if (regex.hasMatch(lines[i])) {
          matchedLines.add(i);
        }
      }

      if (matchedLines.isEmpty) return;

      final relPath = p.relative(file.path, from: workingDir);
      final buf = StringBuffer('$relPath:\n');

      // Merge overlapping context windows.
      final printed = <int>{};
      for (final matchLine in matchedLines) {
        final start = (matchLine - contextLines).clamp(0, lines.length - 1);
        final end = (matchLine + contextLines).clamp(0, lines.length - 1);
        for (var i = start; i <= end; i++) {
          if (printed.contains(i)) continue;
          printed.add(i);
          final marker = i == matchLine ? '>' : ' ';
          buf.writeln('  ${i + 1}$marker ${lines[i]}');
        }
      }

      results.add(buf.toString().trimRight());
    } catch (_) {
      // Skip unreadable files.
    }
  }

  RegExp _globToRegex(String pattern) {
    final escaped = pattern
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');
    return RegExp('^$escaped\$');
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final pattern = args['pattern'] as String;
    return DryRunResult(
      preview: 'Would search for: $pattern',
      riskLevel: riskLevel,
    );
  }
}
