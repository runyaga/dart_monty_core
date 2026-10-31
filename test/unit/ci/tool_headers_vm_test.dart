// The tools that read the upstream pin name the pinned upstream version in
// their header comments: tool/check_oracles.sh,
// tool/check_capability_manifest.py, tool/check_upstream_pin.py,
// tool/generate_fixture_corpus_v1.dart and tool/upstream/requirements.lock.
// A header that names a different version is a false statement about what
// the tool measures against, and the reader of the header has no way to tell
// it apart from the truth: the pin moves when upstream is re-tagged, and the
// headers have to move with it.
//
// The version is read from tool/upstream/upstream-pin.json, so this test
// follows the pin instead of a copy of it. A header comment that names a
// version other than the pinned one fails, whatever that version is.
//
// The test only reads the checkout: it runs no checker, changes no file and
// installs nothing.
//
// VM only: the pin and the headers are repository files, and reading them
// needs dart:io.
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// The repository files whose header comments must name the pinned upstream
/// version: the tools that read the pin, and the lock file they install.
const _headerFiles = [
  'tool/check_oracles.sh',
  'tool/check_capability_manifest.py',
  'tool/check_upstream_pin.py',
  'tool/generate_fixture_corpus_v1.dart',
  'tool/upstream/requirements.lock',
];

/// The pin record: the upstream version everything is measured against.
const _pinPath = 'tool/upstream/upstream-pin.json';

/// A version as a header comment writes it: three numbers, with or without a
/// leading `v`.
final RegExp _version = RegExp(r'\d+\.\d+\.\d+');

void main() {
  test('tool headers name the pinned upstream version', () {
    final root = _repositoryRoot();
    final pinned = _pinnedVersion(root);
    final offenders = <String>[];
    final named = <String>{};
    for (final path in _headerFiles) {
      final source = File('${root.path}/$path').readAsStringSync();
      final header = _headerComment(source);
      for (final match in _version.allMatches(header)) {
        final version = match.group(0);
        if (version == null) {
          continue;
        }
        named.add(version);
        if (version != pinned) {
          offenders.add(
            '$path names upstream version $version, but $_pinPath pins '
            '$pinned',
          );
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a header comment must name the pinned upstream version and no '
          'other: ${offenders.join('; ')}',
    );
    expect(
      named,
      contains(pinned),
      reason:
          'no header names the pinned upstream version $pinned; the headers '
          'name ${named.join(', ')}',
    );
  });
}

/// The upstream version pinned in tool/upstream/upstream-pin.json, read from
/// the checkout at [root].
String _pinnedVersion(Directory root) {
  final file = File('${root.path}/$_pinPath');
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('$_pinPath does not hold a JSON object');
  }
  final version = decoded['version'];
  if (version is! String) {
    fail('$_pinPath holds no "version" string');
  }

  return version;
}

/// The header comment of [source]: the comment block that opens the file. A
/// Python module docstring is part of it, and the first line of code ends
/// it.
String _headerComment(String source) {
  final header = <String>[];
  final lines = source.split('\n').iterator;
  while (lines.moveNext()) {
    final line = lines.current;
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    if (trimmed.startsWith('"""')) {
      header.add(line);
      if (_closesDocstring(trimmed)) {
        break;
      }
      while (lines.moveNext()) {
        final docLine = lines.current;
        header.add(docLine);
        if (docLine.trim().contains('"""')) {
          break;
        }
      }
      break;
    }
    if (trimmed.startsWith('#') || trimmed.startsWith('//')) {
      header.add(line);
      continue;
    }
    break;
  }

  return header.join('\n');
}

/// Whether the Python docstring opening on [line] is closed on the same
/// line.
bool _closesDocstring(String line) => '"""'.allMatches(line).length > 1;

/// The repository root: the checkout that holds the pin record. It is found
/// through the package's own library, which does not move with the working
/// directory, and falls back to the nearest ancestor of the working
/// directory.
Directory _repositoryRoot() {
  final packageUri = Isolate.resolvePackageUriSync(
    Uri.parse('package:dart_monty_core/dart_monty_core.dart'),
  );
  if (packageUri != null) {
    final root = File.fromUri(packageUri).parent.parent;
    if (_isRepositoryRoot(root)) {
      return root;
    }
  }
  var directory = Directory.current.absolute;
  while (true) {
    if (_isRepositoryRoot(directory)) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      fail(
        'no repository root above ${Directory.current.path}: '
        '$_pinPath not found',
      );
    }
    directory = parent;
  }
}

/// Whether [directory] is the repository root: the checkout that holds the
/// pin record.
bool _isRepositoryRoot(Directory directory) =>
    File('${directory.path}/$_pinPath').existsSync();
