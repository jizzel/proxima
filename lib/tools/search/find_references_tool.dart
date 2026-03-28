import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

/// Cross-file symbol reference finder.
class FindReferencesTool implements ProximaTool {
  @override
  String get name => 'find_references';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  String get description =>
      'Find all usages of a symbol across the codebase. '
      'Supports Dart, JS/TS, Python, Go, Rust, Java, Kotlin.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'symbol': {
        'type': 'string',
        'description': 'Symbol name to find usages of',
      },
      'path': {
        'type': 'string',
        'description': 'Directory to restrict search (default: working dir)',
      },
      'file_extensions': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'File extensions to scan (e.g. [".dart", ".ts"])',
      },
      'exclude_definition': {
        'type': 'boolean',
        'description':
            'Exclude lines that look like the symbol definition (default: false)',
      },
      'max_results': {
        'type': 'integer',
        'description': 'Max results (default: 100)',
      },
    },
    'required': ['symbol'],
  };

  static const _skipDirs = {
    '.git',
    'node_modules',
    'build',
    '.dart_tool',
    '.pub-cache',
  };
  static const _skipSuffixes = ['.g.dart', '.freezed.dart', '.pb.dart'];
  static const _defaultExtensions = {
    '.dart',
    '.ts',
    '.js',
    '.tsx',
    '.jsx',
    '.py',
    '.go',
    '.rs',
    '.java',
    '.kt',
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final symbol = args['symbol'] as String;
    final relPath = args['path'] as String?;
    final rawExts = args['file_extensions'] as List?;
    final extensions = rawExts != null
        ? rawExts.map((e) => e as String).toSet()
        : _defaultExtensions;
    final excludeDefinition = args['exclude_definition'] as bool? ?? false;
    final maxResults = args['max_results'] as int? ?? 100;

    final searchRoot = relPath != null
        ? (p.isAbsolute(relPath) ? relPath : p.join(workingDir, relPath))
        : workingDir;

    if (!isSafePath(searchRoot, workingDir)) {
      throw ToolError(
        name,
        'Path "$searchRoot" is outside working directory.',
        errorCode: ToolErrorCode.pathViolation,
      );
    }

    final hits = <({String file, int line, String content})>[];
    await _walk(
      Directory(searchRoot),
      symbol,
      extensions,
      excludeDefinition,
      workingDir,
      maxResults,
      hits,
    );

    if (hits.isEmpty) return 'No references found for "$symbol".';

    final fileCount = hits.map((h) => h.file).toSet().length;
    final lines = hits
        .map((h) => '${h.file}:${h.line}  ${h.content}')
        .join('\n');
    return '$lines\n\nFound ${hits.length} reference${hits.length == 1 ? '' : 's'} in $fileCount file${fileCount == 1 ? '' : 's'}.';
  }

  Future<void> _walk(
    Directory dir,
    String symbol,
    Set<String> extensions,
    bool excludeDefinition,
    String workingDir,
    int maxResults,
    List<({String file, int line, String content})> hits,
  ) async {
    List<FileSystemEntity> entities;
    try {
      entities = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }

    for (final entity in entities) {
      if (hits.length >= maxResults) return;

      final basename = p.basename(entity.path);

      if (entity is Directory) {
        if (_skipDirs.contains(basename)) continue;
        await _walk(
          entity,
          symbol,
          extensions,
          excludeDefinition,
          workingDir,
          maxResults,
          hits,
        );
      } else if (entity is File) {
        if (_skipSuffixes.any((s) => entity.path.endsWith(s))) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (!extensions.contains(ext)) continue;
        await _searchFile(
          entity,
          symbol,
          excludeDefinition,
          workingDir,
          maxResults,
          hits,
        );
      }
    }
  }

  Future<void> _searchFile(
    File file,
    String symbol,
    bool excludeDefinition,
    String workingDir,
    int maxResults,
    List<({String file, int line, String content})> hits,
  ) async {
    List<String> lines;
    try {
      lines = await file.readAsLines();
    } on FormatException {
      return; // binary file
    } catch (_) {
      return;
    }

    final relPath = p.relative(file.path, from: workingDir);
    final wordBoundary = RegExp(r'\b' + RegExp.escape(symbol) + r'\b');
    final definitionPatterns = _definitionPatterns(symbol);

    for (var i = 0; i < lines.length; i++) {
      if (hits.length >= maxResults) return;
      final line = lines[i];
      if (!wordBoundary.hasMatch(line)) continue;
      if (excludeDefinition && _isDefinition(line, definitionPatterns)) {
        continue;
      }

      final content = line.trim();
      final capped = content.length > 120
          ? '${content.substring(0, 120)}…'
          : content;
      hits.add((file: relPath, line: i + 1, content: capped));
    }
  }

  bool _isDefinition(String line, List<RegExp> patterns) =>
      patterns.any((r) => r.hasMatch(line));

  List<RegExp> _definitionPatterns(String symbol) {
    final esc = RegExp.escape(symbol);
    return [
      // Dart / Java / Kotlin class
      RegExp(
        r'^(?:abstract\s+)?(?:final\s+)?(?:data\s+)?class\s+' + esc + r'\b',
      ),
      // Dart / JS function
      RegExp(r'^(?:[\w<>?,\s]+\s+)?' + esc + r'\s*\([^)]*\)\s*(?:async\s*)?\{'),
      // JS/TS function keyword
      RegExp(r'^(?:export\s+)?(?:async\s+)?function\s+' + esc + r'\b'),
      // Python class / def
      RegExp(r'^class\s+' + esc + r'\b'),
      RegExp(r'^def\s+' + esc + r'\s*\('),
      RegExp(r'^\s+def\s+' + esc + r'\s*\('),
      // Go func / struct
      RegExp(r'^func\s+' + esc + r'\s*\('),
      RegExp(r'^type\s+' + esc + r'\s+struct\b'),
      // Rust fn / struct / enum / trait
      RegExp(r'^(?:pub\s+)?(?:async\s+)?fn\s+' + esc + r'\s*[<(]'),
      RegExp(r'^(?:pub\s+)?(?:struct|enum|trait)\s+' + esc + r'\b'),
      // Variable declarations
      RegExp(
        r'^\s*(?:final|const|var|late)\s+(?:[\w<>?]+\s+)?' + esc + r'\s*[=;]',
      ),
    ];
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final symbol = args['symbol'] as String;
    final relPath = args['path'] as String?;
    final searchRoot = relPath != null
        ? (p.isAbsolute(relPath) ? relPath : p.join(workingDir, relPath))
        : workingDir;

    int fileCount = 0;
    try {
      await for (final _ in Directory(
        searchRoot,
      ).list(recursive: true, followLinks: false)) {
        fileCount++;
      }
    } catch (_) {}

    return DryRunResult(
      preview: 'Will scan $fileCount files for references to "$symbol".',
      riskLevel: riskLevel,
    );
  }
}
