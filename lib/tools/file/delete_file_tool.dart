import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class DeleteFileTool implements ProximaTool {
  @override
  String get name => 'delete_file';

  @override
  String get description =>
      'Permanently delete a file. Creates a .proxima_bak backup first. '
      'Requires explicit confirmation. No directory deletion.';

  @override
  RiskLevel get riskLevel => RiskLevel.highRisk;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Relative path to the file to delete',
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
    final type = await FileSystemEntity.type(fullPath);

    if (type == FileSystemEntityType.directory) {
      throw ToolError(name, 'Cannot delete directories: $path');
    }

    if (type == FileSystemEntityType.notFound) {
      throw ToolError(name, 'File not found: $path');
    }

    final file = File(fullPath);

    // Backup before delete — same pattern as write_file/patch_file (enables /undo).
    final backupPath = '$fullPath.proxima_bak';
    await file.copy(backupPath);
    await file.delete();

    return 'Deleted: $path\nBACKUP_PATH:$backupPath';
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final path = args['path'] as String;
    return DryRunResult(
      preview: '[HIGH RISK] Would delete: $path',
      riskLevel: riskLevel,
    );
  }
}
