import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class ReadFileTool implements ProximaTool {
  @override
  String get name => 'read_file';

  @override
  String get description =>
      'Read the contents of a file. Path must be relative to the working directory.';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Relative path to the file'},
      'start_line': {
        'type': 'integer',
        'description': 'Optional: 1-based line to start reading from',
      },
      'end_line': {
        'type': 'integer',
        'description': 'Optional: 1-based line to stop reading at (inclusive)',
      },
    },
    'required': ['path'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final path = args['path'] as String;
    if (!isSafePath(path, workingDir)) {
      throw ToolError(name, 'Path "$path" is outside working directory.');
    }

    final fullPath = p.isAbsolute(path) ? path : p.join(workingDir, path);
    final file = File(fullPath);

    if (!await file.exists()) {
      throw ToolError(name, 'File not found: $path');
    }

    final lines = await file.readAsLines();
    final startLine = args['start_line'] as int?;
    final endLine = args['end_line'] as int?;

    if (startLine != null || endLine != null) {
      final start = (startLine ?? 1) - 1;
      final end = endLine ?? lines.length;
      final slice = lines.skip(start).take(end - start).toList();
      return slice
          .asMap()
          .entries
          .map((e) => '${start + e.key + 1}: ${e.value}')
          .join('\n');
    }

    return lines
        .asMap()
        .entries
        .map((e) => '${e.key + 1}: ${e.value}')
        .join('\n');
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final path = args['path'] as String;
    return DryRunResult(
      preview: 'Would read file: $path',
      riskLevel: riskLevel,
    );
  }
}
