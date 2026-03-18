import 'dart:io';
import '../providers/provider_interface.dart';

/// Renders streaming LLM chunks token-by-token to stdout.
class StreamingRenderer {
  /// Stream chunks from [stream] to stdout, return accumulated text.
  static Future<String> render(Stream<LLMChunk> stream) async {
    final buf = StringBuffer();
    bool started = false;

    await for (final chunk in stream) {
      if (chunk.isDone) break;
      if (!started) {
        stdout.write('\n');
        started = true;
      }
      stdout.write(chunk.text);
      buf.write(chunk.text);
    }

    if (started) stdout.write('\n\n');
    return buf.toString();
  }
}
