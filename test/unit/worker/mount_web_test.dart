@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/worker_conformance.dart' show WorkerFixtureOs;
import 'package:test/test.dart';

import '../../corpus/_corpus_common.dart' show upstreamOpenFsV120;
import '_mount_cwd_cases.dart';
import '_mount_sleep_cases.dart';

/// The backend this file runs on: `dart2js` or `dart2wasm`.
const _backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';

/// The regression groups the shared open source ends with, named at
/// upstream's own markers (monty v1.2.0,
/// `up/crates/monty/test_cases/open__fs.py:656-820`): the newline
/// argument's validation and its ordering, the newline read modes, the
/// newline write modes and the file iteration.
const Map<String, String> _openGroups = {
  'the newline argument': '# === newline argument ===',
  'the newline read modes': '# Reading: None translates',
  'the newline write modes': r"# Writing: only '\r' and '\r\n' translate",
  'the file iteration': '# === Iteration ===',
};

/// The prints a fixture makes are not part of its outcome.
void _discardPrint(String stream, String text) {
  return;
}

/// The shared open source, split at upstream's markers: the text before the
/// first group (which writes the files the groups read) and the four groups,
/// each the upstream text, unchanged.
({String preamble, List<({String name, String source})> groups})
_splitOpenSource() {
  final groups = <({String name, String source})>[];
  var preambleAt = -1;
  var previousAt = -1;
  var previousName = '';
  for (final MapEntry(:key, :value) in _openGroups.entries) {
    final at = upstreamOpenFsV120.indexOf(value);
    if (at < 0) {
      throw StateError('the shared open source has no $value');
    }
    if (preambleAt < 0) {
      preambleAt = at;
    } else {
      groups.add((
        name: previousName,
        source: upstreamOpenFsV120.substring(previousAt, at),
      ));
    }
    previousAt = at;
    previousName = key;
  }
  groups.add((
    name: previousName,
    source: upstreamOpenFsV120.substring(previousAt),
  ));

  return (
    preamble: upstreamOpenFsV120.substring(0, preambleAt),
    groups: groups,
  );
}

/// The failure [body] raised, or null: the groups are upstream's Python, so
/// a failure is the group's own error, named in the message.
Future<Object?> _failureOf(Future<void> Function() body) async {
  try {
    await body();

    return null;
  } on Object catch (error) {
    return error;
  }
}

/// The shared open source on the browser worker: the preamble, then each of
/// the four regression groups in its own feed, so a failure names the group
/// it came from.
Future<void> _runTheOpenGroups() async {
  final source = _splitOpenSource();
  await Monty.withPool((pool) async {
    final session = await pool.checkout(
      scriptName: 'open__fs.py',
      limits: const ResourceLimits(
        maxMemory: 256 * 1024 * 1024,
        maxRecursionDepth: 50,
      ),
    );
    try {
      final os = WorkerFixtureOs.mounted();
      Future<MontyValue> feed(String code) => session.feedRun(
        code,
        cwd: '/mnt',
        os: os.call,
        externalLookup: {'root': MontyPath('/mnt')},
        printCallback: _discardPrint,
      );
      Future<void> group(String name, Future<MontyValue> Function() run) async {
        try {
          await run();
        } on Object catch (error) {
          throw StateError('the group "$name" failed: $error');
        }
      }

      await group('the shared open source', () => feed(source.preamble));
      for (final openGroup in source.groups) {
        await group(openGroup.name, () => feed(openGroup.source));
      }
    } finally {
      await session.close();
    }
  }, maxProcesses: 1);
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

  test('browser worker supports newline modes and file iteration', () async {
    // The shared open source, its four regression groups included: the
    // newline argument's validation and its ordering, the newline read
    // modes, the newline write modes and the file iteration.
    final failure = await _failureOf(_runTheOpenGroups);
    expect(
      failure,
      isNull,
      reason:
          'the browser worker must run the shared open source, all four of '
          'its groups included ($_backend): $failure',
    );
  });

  mountSleepTests();
  mountCwdTests();
}
