import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class ListFilesTool implements ProximaTool {
  @override
  String get name => 'list_files';

  @override
  String get description =>
      'List files and directories in a path (defaults to working directory).';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Relative path to list (defaults to ".")',
      },
      'recursive': {
        'type': 'boolean',
        'description': 'List recursively (default false)',
      },
    },
    'required': [],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final relPath = args['path'] as String? ?? '.';
    final recursive = args['recursive'] as bool? ?? false;

    if (!isSafePath(relPath, workingDir)) {
      throw ToolError(name, 'Path "$relPath" is outside working directory.');
    }

    final fullPath = p.isAbsolute(relPath)
        ? relPath
        : p.join(workingDir, relPath);
    final dir = Directory(fullPath);

    if (!await dir.exists()) {
      throw ToolError(name, 'Directory not found: $relPath');
    }

    final entities = await dir.list(recursive: recursive).toList();
    entities.sort((a, b) => a.path.compareTo(b.path));

    final lines = entities.map((e) {
      final rel = p.relative(e.path, from: workingDir);
      final type = e is Directory ? '/' : '';
      return '$rel$type';
    }).toList();

    return lines.isEmpty ? '(empty)' : lines.join('\n');
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final path = args['path'] as String? ?? '.';
    return DryRunResult(
      preview: 'Would list files in: $path',
      riskLevel: riskLevel,
    );
  }
}
