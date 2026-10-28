// The core dump fixture (test/unit/worker/_core_dump_fixture.g.dart)
// records the worker sources its dump was made from:
// coreIdleDumpWorkerSources is the worker_source_sha256 that
// tool/record_core_dump_fixture.dart read out of tool/wasm-provenance.json
// when it rewrote the fixture. The upstream oracle job ('Oracle files match
// upstream', .github/workflows/ci.yaml) runs tool/generate_dump_oracle.py
// --check, which refuses a fixture whose stamp no longer equals the file's
// ('recorded != current'). This test pins that relation inside the package:
// once the native and browser builds have produced the worker and its
// derived provenance, both stamps must be valid SHA-256 digests and equal,
// so a completed build cannot leave behind a dump fixture recorded from
// other worker sources. It fails today, and keeps failing after the builds:
// the provenance the completed build derives and the fixture record
// different worker sources -- the same drift --check rejects -- so it goes
// green only when the fixture is re-recorded from the completed worker.
//
// The test only reads the checkout: it rebuilds no artifact, records no
// dump and rewrites no stamp.
//
// VM only: the provenance file is development knowledge that lives in the
// repository, not in the published package, and reading it needs dart:io.
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import '../worker/_core_dump_fixture.g.dart';

/// The provenance of the completed worker build, relative to the repository
/// root: the file tool/record_core_dump_fixture.dart reads the recorded
/// stamp from and tool/generate_dump_oracle.py compares against.
const _provenancePath = 'tool/wasm-provenance.json';

/// A stamp as the recorder and the checker write them: a SHA-256 digest,
/// 64 lowercase hex digits.
final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');

void main() {
  test('core dump fixture matches the completed worker source provenance', () {
    const recorded = coreIdleDumpWorkerSources;
    final completed = _workerSourceSha256();
    expect(
      _sha256.hasMatch(recorded),
      isTrue,
      reason:
          'coreIdleDumpWorkerSources must be a SHA-256 digest, 64 lowercase '
          'hex digits: it is the stamp tool/record_core_dump_fixture.dart '
          "writes into the fixture. Got '$recorded'.",
    );
    expect(
      _sha256.hasMatch(completed),
      isTrue,
      reason:
          'worker_source_sha256 in tool/wasm-provenance.json must be a '
          'SHA-256 digest, 64 lowercase hex digits. '
          "Got '$completed'.",
    );
    expect(
      completed,
      recorded,
      reason:
          'the core dump fixture was recorded from worker sources other '
          'than the ones tool/wasm-provenance.json records for the '
          'completed build; tool/generate_dump_oracle.py --check rejects '
          'the same drift',
    );
  });
}

/// The worker_source_sha256 that tool/wasm-provenance.json records for the
/// completed worker build: the same field tool/record_core_dump_fixture.dart
/// reads when it rewrites the fixture and tool/generate_dump_oracle.py
/// compares when it checks it.
String _workerSourceSha256() {
  final root = _repositoryRoot();
  final file = File('${root.path}/$_provenancePath');
  final decoded = jsonDecode(file.readAsStringSync());
  final provenance = decoded as Map<String, Object?>;

  return provenance['worker_source_sha256'] as String? ?? '';
}

/// The repository root: the checkout that holds the provenance file. It is
/// found through the package's own library, which does not move with the
/// working directory, and falls back to the nearest ancestor of the working
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
        '$_provenancePath not found',
      );
    }
    directory = parent;
  }
}

/// Whether [directory] is the repository root: the checkout that holds the
/// provenance file.
bool _isRepositoryRoot(Directory directory) =>
    File('${directory.path}/$_provenancePath').existsSync();
