import 'ansi_helpers.dart';

/// Renders unified diff text with +/- coloring.
class DiffRenderer {
  static String render(String diffText) {
    final lines = diffText.split('\n');
    final buf = StringBuffer();

    for (final line in lines) {
      if (line.startsWith('+') && !line.startsWith('+++')) {
        buf.writeln(green(line));
      } else if (line.startsWith('-') && !line.startsWith('---')) {
        buf.writeln(red(line));
      } else if (line.startsWith('@@')) {
        buf.writeln(cyan(line));
      } else if (line.startsWith('---') || line.startsWith('+++')) {
        buf.writeln(bold(line));
      } else {
        buf.writeln(dim(line));
      }
    }

    return buf.toString().trimRight();
  }
}
