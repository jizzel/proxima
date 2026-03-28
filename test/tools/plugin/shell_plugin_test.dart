import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:proxima/tools/plugin/shell_plugin_tool.dart';
import 'package:proxima/tools/plugin/plugin_loader.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/tool_interface.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_plugin_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// Returns platform-appropriate script filename and content.
  ///
  /// On Windows: writes a `.bat` file.
  /// On POSIX:   writes a `.sh` file and chmod +x it.
  Future<String> writeScript(
    Directory pluginDir,
    String posixScript, {
    String windowsScript = '@echo off\r\necho hello world',
  }) async {
    if (Platform.isWindows) {
      final f = File('${pluginDir.path}/run.bat');
      await f.writeAsString(windowsScript);
      return 'run.bat';
    } else {
      final f = File('${pluginDir.path}/run.sh');
      await f.writeAsString(posixScript);
      await Process.run('chmod', ['+x', f.path]);
      return 'run.sh';
    }
  }

  /// Creates a plugin in [pluginsRoot]/<name>/ with platform-appropriate script.
  Future<({Directory dir, String execName})> createPlugin(
    Directory pluginsRoot,
    String name, {
    required String posixScript,
    String? windowsScript,
    String riskLevel = 'safe',
    int timeoutSeconds = 10,
    Map<String, dynamic>? inputSchema,
  }) async {
    final pluginDir = Directory('${pluginsRoot.path}/$name');
    await pluginDir.create(recursive: true);

    final execName = await writeScript(
      pluginDir,
      posixScript,
      windowsScript: windowsScript ?? '@echo off\r\necho hello world',
    );

    final descriptor = {
      'name': name,
      'description': 'Test plugin $name',
      'risk_level': riskLevel,
      'timeout_seconds': timeoutSeconds,
      'executable': execName,
      'input_schema':
          inputSchema ??
          {
            'type': 'object',
            'properties': {
              'input': {'type': 'string'},
            },
          },
    };
    await File(
      '${pluginDir.path}/plugin.json',
    ).writeAsString(jsonEncode(descriptor));

    return (dir: pluginDir, execName: execName);
  }

  // ── ShellPluginTool — execution tests (POSIX only) ─────────────────────────
  // Windows cannot run .sh scripts without WSL. The plugin system works on
  // Windows with .bat/.exe plugins; execution is tested manually there.

  group('ShellPluginTool', () {
    test(
      'executes script and returns trimmed stdout',
      () async {
        final pluginsRoot = Directory('${tempDir.path}/plugins');
        final p = await createPlugin(
          pluginsRoot,
          'echo_tool',
          posixScript: '#!/bin/sh\necho "hello world"',
        );

        final tool = ShellPluginTool(
          name: 'echo_tool',
          description: 'echoes',
          riskLevel: RiskLevel.safe,
          inputSchema: {},
          executable: '${p.dir.path}/${p.execName}',
          timeoutSeconds: 10,
        );

        final result = await tool.execute({}, tempDir.path);
        expect(result, 'hello world');
      },
      testOn: '!windows',
    );

    test(
      'passes args as JSON on stdin',
      () async {
        final pluginsRoot = Directory('${tempDir.path}/plugins');
        final p = await createPlugin(
          pluginsRoot,
          'stdin_tool',
          posixScript: '#!/bin/sh\ncat',
        );

        final tool = ShellPluginTool(
          name: 'stdin_tool',
          description: 'reads stdin',
          riskLevel: RiskLevel.safe,
          inputSchema: {},
          executable: '${p.dir.path}/${p.execName}',
          timeoutSeconds: 10,
        );

        final result = await tool.execute({'key': 'value'}, tempDir.path);
        final decoded = jsonDecode(result) as Map;
        expect(decoded['key'], 'value');
      },
      testOn: '!windows',
    );

    test(
      'throws ToolError on non-zero exit code',
      () async {
        final pluginsRoot = Directory('${tempDir.path}/plugins');
        final p = await createPlugin(
          pluginsRoot,
          'fail_tool',
          posixScript: '#!/bin/sh\necho "error msg" >&2\nexit 1',
        );

        final tool = ShellPluginTool(
          name: 'fail_tool',
          description: 'fails',
          riskLevel: RiskLevel.safe,
          inputSchema: {},
          executable: '${p.dir.path}/${p.execName}',
          timeoutSeconds: 10,
        );

        expect(
          () => tool.execute({}, tempDir.path),
          throwsA(isA<ToolError>()),
        );
      },
      testOn: '!windows',
    );

    test('dryRun returns preview with args', () async {
      final tool = ShellPluginTool(
        name: 'my_plugin',
        description: 'd',
        riskLevel: RiskLevel.safe,
        inputSchema: {},
        executable: '/fake/path',
        timeoutSeconds: 10,
      );

      final result = await tool.dryRun({'q': 'hello'}, tempDir.path);
      expect(result.preview, contains('my_plugin'));
      expect(result.preview, contains('hello'));
    });

    test('exposes correct name, riskLevel, inputSchema', () {
      final schema = {
        'type': 'object',
        'properties': {
          'q': {'type': 'string'},
        },
      };
      final tool = ShellPluginTool(
        name: 'my_tool',
        description: 'desc',
        riskLevel: RiskLevel.confirm,
        inputSchema: schema,
        executable: '/path',
        timeoutSeconds: 5,
      );
      expect(tool.name, 'my_tool');
      expect(tool.riskLevel, RiskLevel.confirm);
      expect(tool.inputSchema, schema);
    });
  });

  // ── PluginLoader ────────────────────────────────────────────────────────────

  group('PluginLoader', () {
    test('loads a valid plugin', () async {
      final pluginsRoot = Directory('${tempDir.path}/plugins');
      await createPlugin(
        pluginsRoot,
        'hello',
        posixScript: '#!/bin/sh\necho hi',
        windowsScript: '@echo off\r\necho hi',
      );

      final tools = await PluginLoader.load([pluginsRoot.path], tempDir.path);
      expect(tools.length, 1);
      expect(tools.first.name, 'hello');
      expect(tools.first.riskLevel, RiskLevel.safe);
    });

    test('loads plugin relative to workingDir', () async {
      final pluginsDir = Directory('${tempDir.path}/.proxima/plugins');
      await createPlugin(
        pluginsDir,
        'rel_plugin',
        posixScript: '#!/bin/sh\necho ok',
        windowsScript: '@echo off\r\necho ok',
      );

      final tools = await PluginLoader.load(['.proxima/plugins'], tempDir.path);
      expect(tools.length, 1);
      expect(tools.first.name, 'rel_plugin');
    });

    test('silently skips missing directories', () async {
      final tools = await PluginLoader.load([
        '/nonexistent/path/to/plugins',
      ], tempDir.path);
      expect(tools, isEmpty);
    });

    test(
      'skips plugin with missing required fields and emits warning',
      () async {
        final pluginsRoot = Directory('${tempDir.path}/plugins');
        final pluginDir = Directory('${pluginsRoot.path}/bad');
        await pluginDir.create(recursive: true);
        // Missing 'executable' and 'input_schema'
        await File('${pluginDir.path}/plugin.json').writeAsString(
          jsonEncode({'name': 'bad', 'description': 'incomplete'}),
        );

        final tools = await PluginLoader.load([pluginsRoot.path], tempDir.path);
        expect(tools, isEmpty);
      },
    );

    test('skips plugin with malformed plugin.json', () async {
      final pluginsRoot = Directory('${tempDir.path}/plugins');
      final pluginDir = Directory('${pluginsRoot.path}/broken');
      await pluginDir.create(recursive: true);
      await File(
        '${pluginDir.path}/plugin.json',
      ).writeAsString('not valid json {{{');

      final tools = await PluginLoader.load([pluginsRoot.path], tempDir.path);
      expect(tools, isEmpty);
    });

    test('skips plugin whose executable does not exist', () async {
      final pluginsRoot = Directory('${tempDir.path}/plugins');
      final pluginDir = Directory('${pluginsRoot.path}/noscript');
      await pluginDir.create(recursive: true);
      await File('${pluginDir.path}/plugin.json').writeAsString(
        jsonEncode({
          'name': 'noscript',
          'description': 'missing exec',
          'executable': 'run.sh', // file not created
          'input_schema': {'type': 'object'},
        }),
      );

      final tools = await PluginLoader.load([pluginsRoot.path], tempDir.path);
      expect(tools, isEmpty);
    });

    test('parses risk_level correctly', () async {
      final pluginsRoot = Directory('${tempDir.path}/plugins');
      await createPlugin(
        pluginsRoot,
        'risky',
        posixScript: '#!/bin/sh\necho ok',
        windowsScript: '@echo off\r\necho ok',
        riskLevel: 'high_risk',
      );

      final tools = await PluginLoader.load([pluginsRoot.path], tempDir.path);
      expect(tools.length, 1);
      expect(tools.first.riskLevel, RiskLevel.highRisk);
    });

    test('unknown risk_level defaults to confirm', () async {
      final pluginsRoot = Directory('${tempDir.path}/plugins');
      await createPlugin(
        pluginsRoot,
        'unknown_risk',
        posixScript: '#!/bin/sh\necho ok',
        windowsScript: '@echo off\r\necho ok',
        riskLevel: 'whatever',
      );

      final tools = await PluginLoader.load([pluginsRoot.path], tempDir.path);
      expect(tools.length, 1);
      expect(tools.first.riskLevel, RiskLevel.confirm);
    });

    test('loads from multiple plugin dirs', () async {
      final dir1 = Directory('${tempDir.path}/plugins1');
      final dir2 = Directory('${tempDir.path}/plugins2');
      await createPlugin(
        dir1,
        'plugin_a',
        posixScript: '#!/bin/sh\necho a',
        windowsScript: '@echo off\r\necho a',
      );
      await createPlugin(
        dir2,
        'plugin_b',
        posixScript: '#!/bin/sh\necho b',
        windowsScript: '@echo off\r\necho b',
      );

      final tools = await PluginLoader.load([
        dir1.path,
        dir2.path,
      ], tempDir.path);
      expect(tools.length, 2);
      final names = tools.map((t) => t.name).toSet();
      expect(names, containsAll(['plugin_a', 'plugin_b']));
    });
  });
}
