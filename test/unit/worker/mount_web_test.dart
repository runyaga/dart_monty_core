// The browser worker against the shared open() contract: the newline
// argument's validation and its ordering, the newline read modes, the
// newline write modes and the file iteration.
//
//   bash tool/test_worker_web.sh
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_mount_cwd_cases.dart';
import '_mount_sleep_cases.dart';
import '_open_cases.dart';

/// The backend this file runs on: `dart2js` or `dart2wasm`.
const _backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';

/// One shared open() group: the name upstream gives it and the case that
/// runs it.
typedef _OpenGroup = ({
  String name,
  Future<void> Function(OpenCaseRunner) body,
});

/// The regression groups the shared open contract ends with, named at
/// upstream's own markers (monty v1.2.0,
/// `up/crates/monty/test_cases/open__fs.py:656-820`): the newline
/// argument's validation and its ordering, the newline read modes, the
/// newline write modes and the file iteration.
///
/// The cases themselves are the shared ones, unchanged: the browser runs
/// the same contract the VM runner runs.
const List<_OpenGroup> _openGroups = [
  (name: 'the newline argument', body: expectOpenNewline),
  (name: 'the newline read modes', body: expectOpenReadMatrix),
  (name: 'the newline write modes', body: expectOpenWriteMatrix),
  (name: 'the file iteration', body: expectOpenIteration),
];

/// The browser's in-memory host: the session that runs the Python, and the
/// filesystem the Python sees.
///
/// The filesystem is [OSAccess], the handler the package already ships for
/// an in-memory namespace: the browser has no host directory to mount, and
/// the cases only need a tree to read and write. The seed file establishes
/// `/d` as a directory the cases can write into.
final class _BrowserRunner implements OpenCaseRunner {
  const _BrowserRunner(this._session, this._files);

  final MontySession _session;
  final OSAccess _files;

  /// Runs [code] against the filesystem: the cases need `pathlib`, and the
  /// filesystem answers the OS calls.
  @override
  Future<MontyValue> run(String code) => _session.feedRun(
    'from pathlib import Path\n$code',
    os: _files.call,
  );

  /// The bytes the host holds at [path]: the live file's own content, as
  /// bytes or as the UTF-8 encoding of its text.
  ///
  /// A file the host does not hold, or one whose content is neither text
  /// nor bytes, fails the case: the host must hold what the case wrote.
  @override
  List<int> hostBytes(String path) {
    for (final file in _files.files) {
      if (file.path != path) continue;
      final content = file.readContent();

      return switch (content) {
        final Uint8List bytes => bytes,
        final String text => utf8.encode(text),
        _ => throw StateError('unexpected content at $path'),
      };
    }

    throw StateError('the host does not hold $path');
  }
}

/// The failures of the four groups, each labelled with the group and the
/// phase it came from.
///
/// Every group is attempted, so one failure cannot hide another.
Future<List<String>> _runTheOpenGroups() async {
  final failures = <String>[];
  for (final group in _openGroups) {
    await _runOpenGroup(group, failures);
  }

  return failures;
}

/// Runs one group with its own pool, its own session and its own
/// filesystem, and records what failed.
Future<void> _runOpenGroup(_OpenGroup group, List<String> failures) async {
  final name = group.name;
  final files = OSAccess(files: [MemoryFile('/d/.seed', '')]);
  final pool = await _collecting(
    failures,
    name,
    'setup',
    () => Monty.start(maxProcesses: 1),
  );
  if (pool == null) return;
  try {
    final session = await _collecting(
      failures,
      name,
      'setup',
      () => pool.checkout(
        scriptName: 'open__fs.py',
        limits: const ResourceLimits(
          maxMemory: 256 * 1024 * 1024,
          maxRecursionDepth: 50,
        ),
      ),
    );
    if (session == null) return;
    try {
      await _collect(
        failures,
        name,
        'body',
        () => group.body(_BrowserRunner(session, files)),
      );
    } finally {
      await _collect(failures, name, 'cleanup', session.close);
    }
  } finally {
    await _collect(failures, name, 'cleanup', pool.close);
  }
}

/// Runs [body] and records what it raised under [name] and [phase]; the
/// failures already collected stay.
Future<void> _collect(
  List<String> failures,
  String name,
  String phase,
  Future<void> Function() body,
) async {
  try {
    await body();
  } on Object catch (error) {
    failures.add('$name ($phase): $error');
  }
}

/// Runs [body] and records what it raised under [name] and [phase], which
/// then yields null.
Future<T?> _collecting<T>(
  List<String> failures,
  String name,
  String phase,
  Future<T> Function() body,
) async {
  try {
    return await body();
  } on Object catch (error) {
    failures.add('$name ($phase): $error');

    return null;
  }
}

void main() {
  test('MountDir refuses host directories on web (C-1)', () {
    expect(
      () => MountDir(hostPath: '/host', virtualPath: '/d'),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          'MountDir needs a host directory; the browser has none',
        ),
      ),
    );
  });
  test('empty mounts behave as no mounts', () async {
    await Monty.withPool((pool) async {
      await pool.withSession((session) async {
        expect(
          await session.feedRun('42', mount: const []),
          const MontyInt(42),
        );
      });
    }, maxProcesses: 1);
  });

  test(
    'browser worker supports newline modes and file iteration',
    () async {
      // The shared open contract, its four regression groups included: the
      // newline argument's validation and its ordering, the newline read
      // modes, the newline write modes and the file iteration.
      final failures = await _runTheOpenGroups();
      expect(
        failures,
        isEmpty,
        reason:
            'the browser worker must run the shared open() contract, all '
            'four of its groups included ($_backend): ${failures.join('; ')}',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  mountSleepTests();
  mountCwdTests();
}
