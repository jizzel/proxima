import 'dart:io';
import 'package:path/path.dart' as p;

/// Returns true if [inputPath] resolves to a location within [workingDir].
/// Guards against path traversal attacks including symlink escapes.
bool isSafePath(String inputPath, String workingDir) {
  final canonicalWorking = p.canonicalize(workingDir);

  // Resolve against workingDir if relative.
  final joined = p.isAbsolute(inputPath)
      ? inputPath
      : p.join(workingDir, inputPath);

  // Canonicalize (resolves .., . etc. but not symlinks).
  final canonical = p.canonicalize(joined);

  // Primary check: path must be within working dir.
  if (!canonical.startsWith(canonicalWorking + p.separator) &&
      canonical != canonicalWorking) {
    return false;
  }

  // Symlink check: if path exists and is a symlink, check its resolved target.
  try {
    final type = FileSystemEntity.typeSync(canonical, followLinks: false);
    if (type == FileSystemEntityType.link) {
      final resolved = Link(canonical).resolveSymbolicLinksSync();
      final canonicalResolved = p.canonicalize(resolved);
      if (!canonicalResolved.startsWith(canonicalWorking + p.separator) &&
          canonicalResolved != canonicalWorking) {
        return false;
      }
    }
  } on FileSystemException catch (e) {
    // ENOENT (no such file) is fine — new file creation; canonical check suffices.
    // Any other error (e.g. permission denied on stat) → deny for safety.
    final isNotFound =
        e.osError?.errorCode == 2 || // ENOENT on POSIX
        e.message.contains('No such file');
    if (!isNotFound) return false;
  }

  return true;
}
