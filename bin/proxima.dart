import 'dart:io';
import 'package:args/args.dart';
import 'package:proxima/cli/arg_parser.dart';
import 'package:proxima/cli/repl.dart';
import 'package:proxima/core/config.dart';
import 'package:proxima/core/types.dart';

Future<void> main(List<String> arguments) async {
  final argParser = buildArgParser();

  ArgResults results;
  try {
    results = argParser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln('');
    printUsage(argParser);
    exit(1);
  }

  if (results.flag('help')) {
    printUsage(argParser);
    exit(0);
  }

  if (results.flag('version')) {
    print('proxima $proximaVersion');
    exit(0);
  }

  // Load config.
  final workingDir = results.option('dir') ?? Directory.current.path;
  var config = await ProximaConfig.load(workingDir: workingDir);

  // CLI flags override config.
  final model = results.option('model');
  final modeStr = results.option('mode');
  final mode = switch (modeStr) {
    'safe' => SessionMode.safe,
    'auto' => SessionMode.auto,
    _ => null,
  };

  config = config.copyWith(
    model: model,
    mode: mode,
    debug: results.flag('debug') ? true : null,
    dryRun: results.flag('dry-run') ? true : null,
  );

  // Determine task: --task flag or first positional argument.
  final taskFlag = results.option('task');
  final positional = results.rest.join(' ');
  final task = taskFlag ?? (positional.isNotEmpty ? positional : null);

  final resumeId = results.option('resume');

  // Initialize REPL.
  final repl = ProximaRepl(config);
  try {
    await repl.initialize(resumeSessionId: resumeId);
  } catch (e) {
    stderr.writeln('Failed to initialize Proxima: $e');
    exit(1);
  }

  if (task != null) {
    await repl.runTask(task);
  } else {
    await repl.runRepl();
  }
}
