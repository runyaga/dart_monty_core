// Generates test/integration/_fixture_corpus.dart from the .py fixture files.
//
// Run from the package root:
//   dart tool/generate_fixture_corpus.dart
//
// Re-run whenever the pydantic/monty test_cases corpus is updated.

import 'dart:convert';
import 'dart:io' show exitCode, stderr;

import 'package:file/file.dart';
import 'package:file/local.dart';

void main() {
  const fs = LocalFileSystem();
  final fixtureDir = fs.directory('test/fixtures/test_cases');

  if (!fixtureDir.existsSync()) {
    stderr
      ..writeln('ERROR: test/fixtures/test_cases not found.')
      ..writeln(
        'Create the symlink: '
        'ln -s /path/to/monty/crates/monty/test_cases '
        'test/fixtures/test_cases',
      );
    exitCode = 1;

    return;
  }

  final files =
      fixtureDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.py'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final buf = StringBuffer()
    ..writeln('// GENERATED — do not edit.')
    ..writeln('// Run: dart tool/generate_fixture_corpus.dart')
    ..writeln(
      '// ignore_for_file: lines_longer_than_80_chars, '
      'prefer_single_quotes, avoid_escaping_inner_quotes, '
      'eol_at_end_of_file',
    )
    ..writeln()
    ..writeln('/// Python fixture corpus embedded at compile time.')
    ..writeln('///')
    ..writeln('/// Used by WASM/JS tests where `dart:io` is unavailable.')
    ..writeln(
      '/// Keys are fixture file names; values are source text.',
    )
    ..writeln('const Map<String, String> fixtureCorpus = {');

  for (final file in files) {
    final name = file.basename;
    final content = file.readAsStringSync();
    // json.encode produces a valid Dart string literal (double-quoted, with
    // all control characters and backslashes properly escaped).
    // Escape $ so Dart doesn't attempt string interpolation.
    final dartLiteral = json.encode(content).replaceAll(r'$', r'\$');
    buf.writeln("  '$name': $dartLiteral,");
  }

  buf
    ..writeln('};')
    ..writeln();

  const outPath = 'test/integration/_fixture_corpus.dart';
  fs.file(outPath).writeAsStringSync(buf.toString());
  // This is a CLI tool — print is the intended output mechanism.
  // ignore: avoid_print
  print('Generated $outPath with ${files.length} fixtures.');
}
