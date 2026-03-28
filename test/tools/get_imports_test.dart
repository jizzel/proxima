import 'dart:io';
import 'package:test/test.dart';
import 'package:proxima/tools/search/get_imports_tool.dart';
import 'package:proxima/tools/tool_interface.dart';

void main() {
  late Directory tempDir;
  late GetImportsTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_imports_');
    tool = GetImportsTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<void> writeFile(String name, String content) async {
    final file = File('${tempDir.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  // ── Dart ────────────────────────────────────────────────────────────────────

  test('parses Dart dart:, package:, and local imports', () async {
    await writeFile('lib/foo.dart', '''
import 'dart:io';
import 'dart:convert';
import 'package:collection/collection.dart';
import '../core/types.dart';
''');
    final result = await tool.execute({'path': 'lib/foo.dart'}, tempDir.path);
    expect(result, contains('[dart]'));
    expect(result, contains('dart:io'));
    expect(result, contains('[package]'));
    expect(result, contains('package:collection/collection.dart'));
    expect(result, contains('[local]'));
    expect(result, contains('../core/types.dart'));
  });

  test('parses Dart export and part directives', () async {
    await writeFile('lib/barrel.dart', '''
export 'src/a.dart';
part 'src/b.dart';
''');
    final result = await tool.execute({
      'path': 'lib/barrel.dart',
    }, tempDir.path);
    expect(result, contains('src/a.dart'));
    expect(result, contains('src/b.dart'));
  });

  test('shows import count in header', () async {
    await writeFile('lib/foo.dart', '''
import 'dart:io';
import 'dart:convert';
''');
    final result = await tool.execute({'path': 'lib/foo.dart'}, tempDir.path);
    expect(result, contains('2 imports'));
  });

  // ── JavaScript/TypeScript ──────────────────────────────────────────────────

  test('parses JS import from and require', () async {
    await writeFile('src/index.js', '''
import React from 'react';
import { useState } from 'react';
const fs = require('fs');
import utils from './utils';
const local = require('./helpers');
''');
    final result = await tool.execute({'path': 'src/index.js'}, tempDir.path);
    expect(result, contains('[node]'));
    expect(result, contains('react'));
    expect(result, contains('fs'));
    expect(result, contains('[local]'));
    expect(result, contains('./utils'));
    expect(result, contains('./helpers'));
  });

  // ── Python ─────────────────────────────────────────────────────────────────

  test('parses Python import and from-import', () async {
    await writeFile('src/main.py', '''
import os
import sys
from pathlib import Path
from .utils import helper
from ..core import base
''');
    final result = await tool.execute({'path': 'src/main.py'}, tempDir.path);
    expect(result, contains('[stdlib]'));
    expect(result, contains('os'));
    expect(result, contains('pathlib'));
    expect(result, contains('[local]'));
    expect(result, contains('.utils'));
    expect(result, contains('..core'));
  });

  // ── Go ─────────────────────────────────────────────────────────────────────

  test('parses Go single-line and multi-line imports', () async {
    await writeFile('main.go', '''
package main

import "fmt"

import (
  "os"
  "github.com/user/repo"
  log "log/slog"
)
''');
    final result = await tool.execute({'path': 'main.go'}, tempDir.path);
    expect(result, contains('[stdlib]'));
    expect(result, contains('fmt'));
    expect(result, contains('os'));
    expect(result, contains('[external]'));
    expect(result, contains('github.com/user/repo'));
  });

  // ── resolve_paths ──────────────────────────────────────────────────────────

  test('resolve_paths expands local imports', () async {
    await writeFile('lib/foo/bar.dart', '''
import '../core/types.dart';
''');
    final result = await tool.execute({
      'path': 'lib/foo/bar.dart',
      'resolve_paths': true,
    }, tempDir.path);
    expect(result, contains('(resolved)'));
    expect(result, contains('lib/core/types.dart'));
  });

  // ── Error handling ─────────────────────────────────────────────────────────

  test('throws ToolError when file not found', () async {
    expect(
      () => tool.execute({'path': 'nonexistent.dart'}, tempDir.path),
      throwsA(
        isA<ToolError>().having(
          (e) => e.errorCode,
          'errorCode',
          ToolErrorCode.notFound,
        ),
      ),
    );
  });

  test('throws ToolError for path outside workingDir', () async {
    expect(
      () => tool.execute({'path': '/etc/passwd'}, tempDir.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('throws ToolError for unsupported file type', () async {
    await writeFile('data.csv', 'a,b,c');
    expect(
      () => tool.execute({'path': 'data.csv'}, tempDir.path),
      throwsA(
        isA<ToolError>().having(
          (e) => e.errorCode,
          'errorCode',
          ToolErrorCode.parseError,
        ),
      ),
    );
  });

  test('reports 0 imports for file with no imports', () async {
    await writeFile('lib/empty.dart', '''
void main() {
  print('hello');
}
''');
    final result = await tool.execute({'path': 'lib/empty.dart'}, tempDir.path);
    expect(result, contains('0 imports'));
  });

  test('dryRun returns preview without executing', () async {
    final result = await tool.dryRun({'path': 'lib/foo.dart'}, tempDir.path);
    expect(result.preview, contains('lib/foo.dart'));
    expect(result.preview, contains('Will parse imports'));
  });
}
