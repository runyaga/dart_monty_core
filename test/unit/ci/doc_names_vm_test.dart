// The documentation pages name only API the package actually exports.
// `tool/check_doc_names.py` scans the README and every page under `docs/`
// for inline-code spans that look like API references and reports the ones
// that are not part of the package's public API. This test runs that
// checker, the same one the docs CI job runs (`bash tool/check_docs.sh`,
// .github/workflows/ci.yaml), so a documentation page cannot name an API
// that the package does not have.
//
// The checker reads the repository it is run in, so it is run from the
// repository root with the working directory it expects. `-B` keeps Python
// from writing `__pycache__` directories into `tool/`: the test reads the
// checkout, it does not change it, and it installs nothing.
//
// VM only: it runs a subprocess and reads the filesystem.
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

void main() {
  test('the documentation pages name only known API', () {
    final root = _repositoryRoot();
    final result = Process.runSync(
      'python3',
      ['-B', 'tool/check_doc_names.py'],
      workingDirectory: root.path,
    );
    expect(
      result.exitCode,
      0,
      reason:
          'python3 -B tool/check_doc_names.py exited with '
          '${result.exitCode}\n'
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
  });
}

/// The repository root: the directory that holds the checker this test runs.
/// The checker resolves the repository from its own working directory, so
/// this is also the directory it is run in. It is found through the package's
/// own library, which does not move with the working directory, and falls
/// back to the nearest ancestor of the working directory.
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
        'tool/check_doc_names.py not found',
      );
    }
    directory = parent;
  }
}

/// Whether [directory] is the repository root: the checkout that holds the
/// documentation checker.
bool _isRepositoryRoot(Directory directory) =>
    File('${directory.path}/tool/check_doc_names.py').existsSync();
