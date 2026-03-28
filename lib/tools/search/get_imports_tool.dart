import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

/// Import graph extractor for a single file.
class GetImportsTool implements ProximaTool {
  @override
  String get name => 'get_imports';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  String get description =>
      'List all imports/requires in a file, categorised by type. '
      'Supports Dart, JS/TS, Python, and Go.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'File path to parse imports from',
      },
      'resolve_paths': {
        'type': 'boolean',
        'description':
            'Expand local imports to absolute paths (default: false)',
      },
    },
    'required': ['path'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final relPath = args['path'] as String;
    final resolvePaths = args['resolve_paths'] as bool? ?? false;

    final absPath = p.isAbsolute(relPath)
        ? relPath
        : p.join(workingDir, relPath);

    if (!isSafePath(absPath, workingDir)) {
      throw ToolError(
        name,
        'Path "$absPath" is outside working directory.',
        errorCode: ToolErrorCode.pathViolation,
      );
    }

    final file = File(absPath);
    if (!await file.exists()) {
      throw ToolError(
        name,
        'File not found: $relPath',
        errorCode: ToolErrorCode.notFound,
      );
    }

    List<String> lines;
    try {
      lines = await file.readAsLines();
    } on FormatException {
      throw ToolError(
        name,
        'Cannot parse file (binary or invalid encoding): $relPath',
        errorCode: ToolErrorCode.parseError,
      );
    }

    final ext = p.extension(absPath).toLowerCase();
    final lang = _detectLanguage(ext);
    if (lang == null) {
      throw ToolError(
        name,
        'Unsupported file type: $ext',
        errorCode: ToolErrorCode.parseError,
      );
    }

    final imports = _parseImports(lines, lang);
    if (imports.isEmpty) {
      return '$relPath — 0 imports\n\n(no imports found)';
    }

    final fileDir = p.dirname(absPath);
    return _format(relPath, imports, resolvePaths, fileDir, workingDir);
  }

  String? _detectLanguage(String ext) => switch (ext) {
    '.dart' => 'dart',
    '.js' || '.ts' || '.jsx' || '.tsx' || '.mjs' || '.cjs' => 'js',
    '.py' => 'python',
    '.go' => 'go',
    _ => null,
  };

  /// Each import: (category, specifier).
  List<(String, String)> _parseImports(List<String> lines, String lang) {
    return switch (lang) {
      'dart' => _parseDart(lines),
      'js' => _parseJs(lines),
      'python' => _parsePython(lines),
      'go' => _parseGo(lines),
      _ => [],
    };
  }

  List<(String, String)> _parseDart(List<String> lines) {
    final results = <(String, String)>[];
    // import 'pkg'; / import "pkg"; / export 'pkg'; / part 'pkg';
    final re = RegExp(r'''^\s*(?:import|export|part)\s+['"](.*?)['"]''');
    for (final line in lines) {
      final m = re.firstMatch(line);
      if (m == null) continue;
      final spec = m.group(1)!;
      final cat = spec.startsWith('dart:')
          ? '[dart]'
          : spec.startsWith('package:')
          ? '[package]'
          : '[local]';
      results.add((cat, spec));
    }
    return results;
  }

  List<(String, String)> _parseJs(List<String> lines) {
    final results = <(String, String)>[];
    // import ... from '...' or import '...'
    final importFrom = RegExp(r'''^\s*import\s+.*?from\s+['"](.*?)['"]''');
    final importBare = RegExp(r'''^\s*import\s+['"](.*?)['"]''');
    // require('...')
    final require = RegExp(r'''require\s*\(\s*['"](.*?)['"]\s*\)''');

    for (final line in lines) {
      RegExpMatch? m =
          importFrom.firstMatch(line) ?? importBare.firstMatch(line);
      if (m != null) {
        final spec = m.group(1)!;
        final cat = (spec.startsWith('./') || spec.startsWith('../'))
            ? '[local]'
            : '[node]';
        results.add((cat, spec));
        continue;
      }
      m = require.firstMatch(line);
      if (m != null) {
        final spec = m.group(1)!;
        final cat = (spec.startsWith('./') || spec.startsWith('../'))
            ? '[local]'
            : '[node]';
        results.add((cat, spec));
      }
    }
    return results;
  }

  List<(String, String)> _parsePython(List<String> lines) {
    final results = <(String, String)>[];
    // from x import y  /  import x
    final fromImport = RegExp(r'''^\s*from\s+(\S+)\s+import''');
    final bareImport = RegExp(r'''^\s*import\s+(\S+)''');

    for (final line in lines) {
      RegExpMatch? m = fromImport.firstMatch(line);
      if (m != null) {
        final spec = m.group(1)!;
        final cat = spec.startsWith('.') ? '[local]' : '[stdlib]';
        results.add((cat, spec));
        continue;
      }
      m = bareImport.firstMatch(line);
      if (m != null) {
        final spec = m.group(1)!;
        final cat = spec.startsWith('.') ? '[local]' : '[stdlib]';
        results.add((cat, spec));
      }
    }
    return results;
  }

  List<(String, String)> _parseGo(List<String> lines) {
    final results = <(String, String)>[];
    // Single-line: import "pkg"
    final single = RegExp(r'''^\s*import\s+"([^"]+)"''');
    // Multi-line block: import ( "pkg" ... )
    bool inBlock = false;
    final blockEntry = RegExp(r'''^\s+"([^"]+)"''');
    final blockEntryAliased = RegExp(r'''^\s+\w+\s+"([^"]+)"''');

    for (final line in lines) {
      if (!inBlock) {
        final m = single.firstMatch(line);
        if (m != null) {
          final spec = m.group(1)!;
          final cat = spec.contains('.') ? '[external]' : '[stdlib]';
          results.add((cat, spec));
          continue;
        }
        if (line.trim().startsWith('import (')) {
          inBlock = true;
          continue;
        }
      } else {
        if (line.trim() == ')') {
          inBlock = false;
          continue;
        }
        RegExpMatch? m =
            blockEntryAliased.firstMatch(line) ?? blockEntry.firstMatch(line);
        if (m != null) {
          final spec = m.group(1)!;
          final cat = spec.contains('.') ? '[external]' : '[stdlib]';
          results.add((cat, spec));
        }
      }
    }
    return results;
  }

  String _format(
    String filePath,
    List<(String, String)> imports,
    bool resolvePaths,
    String fileDir,
    String workingDir,
  ) {
    // Group by category preserving order.
    final grouped = <String, List<String>>{};
    for (final (cat, spec) in imports) {
      grouped.putIfAbsent(cat, () => []).add(spec);
    }

    final buf = StringBuffer();
    buf.writeln(
      '$filePath — ${imports.length} import${imports.length == 1 ? '' : 's'}',
    );

    for (final cat in grouped.keys) {
      buf.writeln('');
      buf.writeln(cat);
      for (final spec in grouped[cat]!) {
        if (resolvePaths && (cat == '[local]')) {
          final resolved = p.normalize(p.join(fileDir, spec));
          // Always use forward slashes in output regardless of host OS.
          final rel = p.relative(resolved, from: workingDir)
              .replaceAll(r'\', '/');
          buf.writeln('  $spec  →  $rel   (resolved)');
        } else {
          buf.writeln('  $spec');
        }
      }
    }

    return buf.toString().trimRight();
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final path = args['path'] as String;
    return DryRunResult(
      preview: 'Will parse imports from "$path".',
      riskLevel: riskLevel,
    );
  }
}
