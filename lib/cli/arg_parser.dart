import 'package:args/args.dart';

const String proximaVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

ArgParser buildArgParser() {
  return ArgParser()
    ..addOption('task', abbr: 't', help: 'Run a one-shot task and exit.')
    ..addOption(
      'dir',
      abbr: 'd',
      help: 'Working directory (defaults to current directory).',
    )
    ..addOption(
      'model',
      abbr: 'm',
      help:
          'Model to use, e.g. anthropic/claude-sonnet-4-6 or ollama/qwen2.5-coder:32b.',
    )
    ..addOption(
      'mode',
      help: 'Permission mode: safe, confirm (default), or auto.',
      allowed: ['safe', 'confirm', 'auto'],
    )
    ..addOption('resume', abbr: 'r', help: 'Resume a previous session by ID.')
    ..addFlag(
      'debug',
      negatable: false,
      help: 'Show debug output (tool args, token counts).',
    )
    ..addFlag(
      'dry-run',
      negatable: false,
      help: 'Preview all tool calls without executing destructive ones.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print usage information.',
    )
    ..addFlag('version', negatable: false, help: 'Print version.');
}

void printUsage(ArgParser parser) {
  print('Usage: proxima [options] [task]');
  print('');
  print('A terminal-native, model-agnostic coding agent.');
  print('');
  print(parser.usage);
  print('');
  print('Examples:');
  print(
    '  proxima                                      # Start interactive REPL',
  );
  print('  proxima "list the files in this project"     # One-shot task');
  print('  proxima --model ollama/qwen2.5-coder:32b     # Use local model');
  print('  proxima --dry-run "refactor the auth module" # Preview changes');
}
