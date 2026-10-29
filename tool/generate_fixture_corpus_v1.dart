// Generates packages/monty_conformance/lib/src/fixture_corpus_v1.dart from a
// checkout of upstream's pinned test_cases (the corpus the worker runs).
//
//   dart tool/generate_fixture_corpus_v1.dart <upstream-checkout> [--check]
//
// The checkout is read, never written. Its HEAD must be the commit pinned in
// tool/upstream/upstream-pin.json and its `crates/monty/test_cases` git tree
// must equal the recorded tree hash: a git tree hash is a content hash of
// every file under the path, so a corpus that was edited or re-tagged is
// refused before anything is generated.
//
// With --check nothing is written: the generated text must equal the committed
// file, or the exit code is 1 (CI's `corpus-worker` job runs this).

import 'dart:convert';
import 'dart:io' show Process, exitCode, stderr;

import 'package:file/file.dart';
import 'package:file/local.dart';

const _outPath = 'packages/monty_conformance/lib/src/fixture_corpus_v1.dart';
const _corpusPath = 'crates/monty/test_cases';

void main(List<String> args) {
  const fs = LocalFileSystem();
  final check = args.contains('--check');
  final paths = args.where((a) => !a.startsWith('--')).toList();
  if (paths.length != 1) {
    _fail(
      'usage: dart tool/generate_fixture_corpus_v1.dart '
      '<upstream-checkout> [--check]',
    );

    return;
  }
  // ignore: avoid-unsafe-collection-methods, the guard above pins the count.
  final checkout = paths.single;

  final pin =
      jsonDecode(fs.file('tool/upstream/upstream-pin.json').readAsStringSync())
          as Map<String, Object?>;
  final tree = (pin['trees']! as List<Object?>)
      .cast<Map<String, Object?>>()
      // ignore: avoid-unsafe-collection-methods, one tree record per path.
      .singleWhere((t) => t['path'] == _corpusPath);

  final head = _git(checkout, ['rev-parse', 'HEAD']);
  final gitTree = _git(checkout, ['rev-parse', 'HEAD:$_corpusPath']);
  if (head != pin['commit'] || gitTree != tree['git_tree']) {
    _fail(
      'checkout is not the pin: HEAD $head (want ${pin['commit']}), '
      'tree $gitTree (want ${tree['git_tree']})',
    );

    return;
  }

  // The hashes above name the committed tree; the files are read from the
  // working tree, so it must have no edit, deletion or stray file in it.
  final dirty = _git(checkout, [
    'status',
    '--porcelain',
    '--untracked-files=all',
    '--',
    _corpusPath,
  ]);
  if (dirty.isNotEmpty) {
    _fail("the checkout's $_corpusPath differs from its commit:\n$dirty");

    return;
  }

  final dir = fs.directory('$checkout/$_corpusPath');
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.py'))
          .toList()
        ..sort((a, b) => a.basename.compareTo(b.basename));
  if (files.length != tree['files']) {
    _fail('${files.length} files, the pin records ${tree['files']}');

    return;
  }

  final buf = StringBuffer()
    ..writeln('// GENERATED — do not edit.')
    ..writeln('// Run: dart tool/generate_fixture_corpus_v1.dart <checkout>')
    ..writeln(
      '// ignore_for_file: lines_longer_than_80_chars, '
      'prefer_single_quotes, avoid_escaping_inner_quotes',
    )
    ..writeln()
    ..writeln("/// pydantic/monty ${pin['tag']}'s `$_corpusPath`, embedded.")
    ..writeln('///')
    ..writeln('/// Commit ${pin['commit']}, git tree ${tree['git_tree']}.')
    ..writeln('/// Keys are fixture file names; values are source text.')
    ..writeln('const Map<String, String> fixtureCorpusV1 = {');
  for (final file in files) {
    // json.encode is a valid Dart string literal once `$` is escaped.
    final literal = json
        .encode(file.readAsStringSync())
        .replaceAll(r'$', r'\$');
    // As `dart format` lays it out, so the committed file survives the
    // formatter: one line when it fits in 80 columns, else the value on its
    // own line.
    final entry = "  '${file.basename}': $literal,";
    if (entry.length <= 80) {
      buf.writeln(entry);
    } else {
      buf
        ..writeln("  '${file.basename}':")
        ..writeln('      $literal,');
    }
  }
  buf.writeln('};');

  final out = fs.file(_outPath);
  final text = buf.toString();
  if (check) {
    if (!out.existsSync() || out.readAsStringSync() != text) {
      _fail('$_outPath differs from the pinned corpus; regenerate it');
    }

    return;
  }
  out.writeAsStringSync(text);
  stderr.writeln('Generated $_outPath with ${files.length} fixtures.');
}

String _git(String checkout, List<String> args) {
  final r = Process.runSync('git', ['-C', checkout, ...args]);
  if (r.exitCode != 0) {
    _fail('git ${args.join(' ')} failed: ${r.stderr}');

    return '';
  }

  return (r.stdout as String).trim();
}

void _fail(String message) {
  stderr.writeln('FAIL: $message');
  exitCode = 1;
}
