// Catching StateError is the assertion here: a closed session raises it.
// ignore_for_file: avoid_catching_errors
// Session-boundary behaviour pinned to upstream pydantic-monty 1.1.0's
// outcomes (limits, restore bytes, type-check deadlines, OS-call paths),
// run on a real pool. Shared by the VM harness
// (test/integration/worker/pool_session_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases. Expected values were recorded from upstream's AsyncMonty.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

typedef _Start = Future<Monty> Function(PoolOptions);

/// An idle dump's header: `MONTY\0` then the version, little-endian.
const _headerLength = 8;

/// The dump format version upstream 1.1.0 writes and reads.
const _dumpVersion = 13;

const _rec = 'def rec(n):\n    return n if n == 0 else rec(n - 1)\n';

void boundarySessionTests(
  String label,
  Future<Monty> Function(PoolOptions) start,
) {
  _memoryLimits(label, start);
  _timeLimits(label, start);
  _dumpBytes(label, start);
  _dumpLimits(label, start);
  _osPaths(label, start);
}

Future<Monty> _pool(
  _Start start, {
  int processes = 4,
  PoolOptions? options,
}) async {
  final pool = await start(options ?? PoolOptions(maxProcesses: processes));
  addTearDown(pool.close);

  return pool;
}

Future<MontySession> _open(
  Monty pool, [
  SessionConfig config = const SessionConfig(),
]) async {
  final session = await pool.checkoutWith(config);
  addTearDown(session.close);

  return session;
}

/// The control: a fresh checkout on [pool] still computes.
Future<void> _controlRuns(Monty pool) async {
  final session = await pool.checkoutWith();
  try {
    expect(await session.feedRun('1 + 1'), const MontyInt(2));
  } finally {
    await session.close();
  }
}

Matcher _runtimeError(String type, [String? message]) =>
    isA<MontyRuntimeError>()
        .having((e) => e.exception.excType, 'excType', type)
        .having(
          (e) => e.toString(),
          'message',
          message == null ? anything : contains(message),
        );

void _memoryLimits(String label, _Start start) {
  const cap = SessionConfig(limits: ResourceLimits(maxMemory: 1000000));

  test('memory limit is aggregate: many small objects raise MemoryError '
      'and the session survives ($label)', () async {
    final pool = await _pool(start);
    final session = await _open(pool, cap);
    await expectLater(
      session.feedRun(
        "l = []\nfor i in range(200000):\n    l.append('x' * 100 + str(i))\n"
        'len(l)',
      ),
      throwsA(_runtimeError('MemoryError', 'memory limit exceeded')),
    );
    // The session survives: once the list is dropped it runs on. Measured:
    // on the web a feed that allocates before the drop raises MemoryError
    // again, which the VM does not.
    expect(await session.feedRun('l = None'), const MontyNone());
    expect(await session.feedRun('1 + 1'), const MontyInt(2));
  });

  test('a large input is charged to the memory limit: MemoryError, '
      'the worker is replaced ($label)', () async {
    final pool = await _pool(start, processes: 1);
    final session = await _open(pool, cap);
    await expectLater(
      session.feedRun(
        'len(x)',
        inputs: {'x': MontyString('a' * 5000000)},
      ),
      throwsA(
        _runtimeError(
          'MemoryError',
          'the worker exceeded its memory limit and was terminated',
        ),
      ),
    );
    await expectLater(session.feedRun('1 + 1'), throwsStateError);
    await session.close();
    await _controlRuns(pool);
  });
}

void _timeLimits(String label, _Start start) {
  const spin = 'while True:\n    pass';

  for (final (name, limits) in <(String, ResourceLimits)>[
    (
      'feed',
      const ResourceLimits(maxFeedDuration: Duration(milliseconds: 200)),
    ),
    (
      'turn',
      const ResourceLimits(maxTurnDuration: Duration(milliseconds: 200)),
    ),
  ]) {
    test('a $name limit ends an endless loop in-sandbox within '
        'limit plus grace, and the session survives ($label)', () async {
      final pool = await _pool(start);
      final session = await _open(pool, SessionConfig(limits: limits));
      final watch = Stopwatch()..start();
      await expectLater(
        session.feedRun(spin),
        throwsA(_runtimeError('TimeoutError', '$name time limit exceeded')),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(await session.feedRun('1 + 1'), const MontyInt(2));
    });
  }

  test('the feed deadline covers the type-check phase: the worker is '
      'killed and replaced ($label)', () async {
    final pool = await _pool(start, processes: 1);
    final session = await _open(
      pool,
      const SessionConfig(
        typeCheck: true,
        limits: ResourceLimits(maxFeedDuration: Duration(seconds: 2)),
      ),
    );
    final watch = Stopwatch()..start();
    // Upstream kills at the limit plus its 1 s grace: "monty worker killed
    // after exceeding request timeout of 3s". Never an unbounded wait.
    await expectLater(
      session.feedRun('[' * 250),
      throwsA(
        isA<MontyCrashedError>()
            .having((e) => e.timedOut, 'timedOut', true)
            .having(
              (e) => e.toString(),
              'message',
              contains('killed after exceeding request timeout of 3s'),
            ),
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
    await session.close();
    await _controlRuns(pool);
  });
}

/// An idle session's dump, with two globals and a function defined.
Future<Uint8List> _idleDump(Monty pool) async {
  final session = await pool.checkoutWith();
  try {
    await session.feedRun(
      'x = [1, 2, 3]\ny = {"a": "b"}\ndef f(a):\n    return a + 1\n',
    );

    return await session.dump();
  } finally {
    await session.close();
  }
}

Uint8List _withVersion(Uint8List dump, int version) => Uint8List.fromList(dump)
  ..[6] = version & 0xff
  ..[7] = (version >> 8) & 0xff;

void _dumpBytes(String label, _Start start) {
  Future<void> expectRefused(
    Monty pool,
    Uint8List bytes,
    String message,
  ) async {
    final session = await pool.checkoutWith();
    addTearDown(session.close);
    await expectLater(
      session.loadSession(bytes),
      throwsA(
        _runtimeError(
          'RuntimeError',
          'protocol violation: failed to load session: $message',
        ),
      ),
    );
    // The session runs on, still unloaded.
    expect(await session.feedRun('1 + 1'), const MontyInt(2));
    await session.close();
  }

  test('a dump of another format version or a broken dump is refused with '
      "upstream's message ($label)", () async {
    final pool = await _pool(start);
    final dump = await _idleDump(pool);
    final header = ByteData.sublistView(dump, 0, _headerLength);
    expect(dump.sublist(0, 6), 'MONTY\u0000'.codeUnits);
    expect(header.getUint16(6, Endian.little), _dumpVersion);
    await expectRefused(
      pool,
      _withVersion(dump, _dumpVersion - 1),
      'dump format version 12 is older than 13, the oldest this build reads',
    );
    await expectRefused(
      pool,
      _withVersion(dump, _dumpVersion + 1),
      'dump format version 14 is newer than 13, the newest this build reads',
    );
    await expectRefused(
      pool,
      _withVersion(dump, 8),
      'dump format version 8 is older than 13, the oldest this build reads',
    );
    await expectRefused(
      pool,
      dump.sublist(0, dump.length ~/ 2),
      'malformed dump payload: end of input bytes',
    );
    await expectRefused(
      pool,
      dump.sublist(0, _headerLength),
      'malformed dump payload: end of input bytes',
    );
    await expectRefused(pool, Uint8List(0), 'not a monty dump');
    await expectRefused(pool, dump.sublist(0, 5), 'not a monty dump');
  });

  test('modified dumps never leave the pool unusable: each load is a typed '
      'outcome and a clean session then runs ($label)', () async {
    final pool = await _pool(start, processes: 1);
    final dump = await _idleDump(pool);
    // A fixed pseudo-random walk over the payload (not the header). MINSTD
    // keeps every product below 2^53, so dart2js walks the same bytes.
    var seed = 7;
    int next(int bound) {
      seed = (seed * 48271) % 2147483647;

      return seed % bound;
    }

    const deadline = Duration(seconds: 30);
    final outcomes = <String>[];
    for (var i = 0; i < 300; i++) {
      final mutated = Uint8List.fromList(dump);
      final at = _headerLength + next(dump.length - _headerLength);
      final bytes = ByteData.sublistView(mutated);
      bytes.setUint8(at, bytes.getUint8(at) ^ (1 << next(8)));
      final session = await pool.checkoutWith();
      addTearDown(session.close);
      try {
        await session.loadSession(mutated).timeout(deadline);
        // A load that succeeded must still answer without hanging.
        await session.feedRun('1 + 1').timeout(deadline);
        outcomes.add('loaded');
      } on MontyCrashedError {
        outcomes.add('crashed');
      } on MontyRuntimeError {
        outcomes.add('raised');
      } on StateError {
        outcomes.add('finished');
      } finally {
        await session.close();
      }
      await _controlRuns(pool);
    }
    // Every load ended in one typed outcome, and the single worker served a
    // clean session after each.
    expect(outcomes, hasLength(300));
    expect(outcomes, contains('loaded'));
    expect(outcomes, contains('raised'));
  });
}

SessionConfig _depth(int depth) =>
    SessionConfig(limits: ResourceLimits(maxRecursionDepth: depth));

void _dumpLimits(String label, _Start start) {
  // Upstream's rule (docs/snapshots.md: the dump carries its own
  // configuration): a restored session runs under the limits the dump was
  // taken with, whatever the loader asked for.
  test("a restored dump keeps its own limits; the loading session's do not "
      'replace them ($label)', () async {
    final pool = await _pool(start);
    // A dump taken under one depth limit, restored under the other.
    for (final (taken, loader, rec100) in <(int, int, Matcher)>[
      (30, 1000, throwsA(_runtimeError('RecursionError'))),
      (1000, 30, completion(const MontyInt(0))),
    ]) {
      final source = await _open(pool, _depth(taken));
      await source.feedRun(_rec);
      final restored = await _open(pool, _depth(loader));
      await restored.loadSession(await source.dump());
      await expectLater(restored.feedRun('rec(100)'), rec100);
    }
  });
}

/// A path or string argument as its text.
Object _shown(MontyValue arg) => switch (arg) {
  MontyPath(:final value) || MontyString(:final value) => value,
  _ => arg,
};

void _osPaths(String label, _Start start) {
  Future<(String, List<String>)> viaHandler(Monty pool, String code) async {
    final seen = <String>[];
    final session = await _open(pool);
    String outcome;
    try {
      final value = await session.feedRun(
        'from pathlib import Path\n$code',
        os: (name, args, kwargs) {
          seen.add(
            '$name ${args.map(_shown).join(',')}',
          );
          throw const OsCallNotHandledException();
        },
      );
      outcome = 'value: $value';
    } on MontyRuntimeError catch (e) {
      outcome = '${e.exception.excType}: ${e.exception.message}';
    } finally {
      await session.close();
    }

    return (outcome, seen);
  }

  test('a host OS handler is given the normalised path, not the raw one '
      '($label)', () async {
    final pool = await _pool(start);
    final (traverse, seenTraverse) = await viaHandler(
      pool,
      "Path('/data/../etc/hosts').read_text()",
    );
    expect(traverse, "PermissionError: Permission denied: '/etc/hosts'");
    expect(seenTraverse, ['Path.read_text /etc/hosts']);
    final (write, seenWrite) = await viaHandler(
      pool,
      "Path('/data/sub/../../escape.txt').write_text('x')",
    );
    expect(write, "PermissionError: Permission denied: '/escape.txt'");
    expect(seenWrite, ['Path.write_text /escape.txt,x']);
    final (exists, seenExists) = await viaHandler(
      pool,
      "Path('/data/..').exists()",
    );
    expect(exists, "PermissionError: Permission denied: '/'");
    expect(seenExists, ['Path.exists /']);
    final (dots, seenDots) = await viaHandler(
      pool,
      "Path('/a/./b//c/../d').exists()",
    );
    expect(dots, "PermissionError: Permission denied: '/a/b/d'");
    expect(seenDots, ['Path.exists /a/b/d']);
  });

  test('an in-memory filesystem is one namespace: dotdot stays inside it, '
      "as upstream's ($label)", () async {
    final pool = await _pool(start);
    final session = await _open(pool);
    final fs = OSAccess(files: [MemoryFile('/data/a.txt', 'hello')]);
    expect(
      await session.feedRun(
        "from pathlib import Path\nPath('/data/sub/../../escape.txt').write_text('x')",
        os: fs.call,
      ),
      const MontyInt(1),
    );
    expect(
      await session.feedRun("Path('/data/..').exists()", os: fs.call),
      const MontyBool(true),
    );
  });
}
