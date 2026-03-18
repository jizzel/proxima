import 'dart:io';
import 'ansi_helpers.dart';

/// Renders the REPL header bar, fitting the terminal width.
class ReplHeader {
  static String render({
    required String model,
    required String workingDir,
    required String version,
  }) {
    final termWidth = stdout.terminalColumns.clamp(40, 120);

    // Provider icon.
    final provider = model.startsWith('ollama/') ? '🦙' : '✦';
    final modelLabel = model.startsWith('ollama/')
        ? model.substring('ollama/'.length)
        : model.startsWith('anthropic/')
            ? model.substring('anthropic/'.length)
            : model;

    // Shorten workingDir to just the last 2 path segments if too long.
    final dirParts = workingDir.replaceAll('\\', '/').split('/');
    final shortDir = dirParts.length > 2
        ? '…/${dirParts.sublist(dirParts.length - 2).join('/')}'
        : workingDir;

    final titleLine = ' proxima $version ';
    final bar = '─' * ((termWidth - titleLine.length).clamp(0, termWidth));
    final halfBar = bar.substring(0, bar.length ~/ 2);
    final halfBar2 = bar.substring(bar.length ~/ 2);

    final buf = StringBuffer();
    buf.writeln(boldCyan('$halfBar$titleLine$halfBar2'));
    buf.writeln(
      '  $provider ${cyan(modelLabel)}  ${dim("in")} ${blue(shortDir)}',
    );
    buf.writeln(dim('─' * termWidth));
    return buf.toString();
  }
}
