import 'dart:io';
import '../tools/plugin/plugin_installer.dart';

/// Handles `proxima plugin ...` before the REPL starts.
///
/// Intercepted ahead of flag parsing because the main parser treats the first
/// positional as a natural-language task — without this, `proxima plugin
/// install word-count` would be sent to the model as a prompt and fail
/// plausibly rather than loudly.
///
/// Returns the process exit code.
Future<int> runPluginCommand(
  List<String> args, {
  PluginInstaller? installer,
  void Function(String) out = print,
}) async {
  final inst = installer ?? PluginInstaller();

  if (args.isEmpty || args.first == 'help' || args.first == '--help') {
    _printUsage(out);
    return args.isEmpty ? 1 : 0;
  }

  final subcommand = args.first;
  final rest = args.skip(1).toList();

  switch (subcommand) {
    case 'list':
      return _list(inst, out, installedOnly: rest.contains('--installed'));
    case 'install':
      return _install(inst, out, rest);
    case 'remove':
      return _remove(inst, out, rest);
    case 'update':
      return _update(inst, out);
    default:
      out('Unknown plugin command: $subcommand');
      _printUsage(out);
      return 1;
  }
}

Future<int> _list(
  PluginInstaller installer,
  void Function(String) out, {
  required bool installedOnly,
}) async {
  final installed = await installer.listInstalled();

  if (installedOnly) {
    if (installed.isEmpty) {
      out('No plugins installed.');
    } else {
      out('Installed plugins:');
      for (final name in installed) {
        out('  $name');
      }
    }
    return 0;
  }

  final catalog = await installer.fetchCatalog();
  if (catalog == null) {
    // Offline is not an error for `list` — show what the user actually has.
    if (installed.isEmpty) {
      out('No plugins installed.  (catalogue unavailable)');
    } else {
      out('Installed plugins:  (catalogue unavailable)');
      for (final name in installed) {
        out('  $name');
      }
    }
    return 0;
  }

  if (catalog.isEmpty) {
    out('No plugins in the catalogue.');
    return 0;
  }

  out('Available plugins:');
  for (final entry in catalog) {
    final mark = installed.contains(entry.name) ? '✓' : ' ';
    out('  $mark ${entry.name.padRight(18)} ${entry.description}');
  }
  return 0;
}

Future<int> _install(
  PluginInstaller installer,
  void Function(String) out,
  List<String> rest,
) async {
  if (rest.isEmpty) {
    out('Usage: proxima plugin install <name>');
    return 1;
  }
  try {
    final entry = await installer.install(rest.first);
    out('Installed ${entry.name} ${entry.version} → ${installer.installRoot}');
    return 0;
  } on PluginInstallError catch (e) {
    out(e.message);
    return 1;
  }
}

Future<int> _remove(
  PluginInstaller installer,
  void Function(String) out,
  List<String> rest,
) async {
  if (rest.isEmpty) {
    out('Usage: proxima plugin remove <name>');
    return 1;
  }
  final removed = await installer.remove(rest.first);
  if (removed) {
    out('Removed ${rest.first}');
    return 0;
  }
  out('Plugin "${rest.first}" is not installed.');
  return 1;
}

Future<int> _update(
  PluginInstaller installer,
  void Function(String) out,
) async {
  final installed = await installer.listInstalled();
  if (installed.isEmpty) {
    out('No plugins installed.');
    return 0;
  }

  var failures = 0;
  for (final name in installed) {
    try {
      final entry = await installer.install(name);
      out('Updated ${entry.name} → ${entry.version}');
    } on PluginInstallError catch (e) {
      // One failure must not abandon the rest.
      out('Could not update $name: ${e.message}');
      failures++;
    }
  }
  return failures == 0 ? 0 : 1;
}

void _printUsage(void Function(String) out) {
  out('');
  out('Usage: proxima plugin <command>');
  out('');
  out('  list                 list plugins from the official catalogue');
  out('  list --installed     list locally installed plugins');
  out('  install <name>       download and install a plugin');
  out('  remove <name>        remove an installed plugin');
  out('  update               update all installed plugins');
  out('');
}

/// Convenience for `bin/proxima.dart`.
Future<Never> runPluginCommandAndExit(List<String> args) async {
  exit(await runPluginCommand(args));
}
