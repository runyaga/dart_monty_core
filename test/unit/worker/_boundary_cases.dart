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

import '_core_dump_fixture.g.dart';
import '_dump_oracle.g.dart';

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
  _crossBinding(label, start);
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
  // Upstream's rule (up/crates/monty-proto/src/worker.rs:955,
  // `tighten_limits`): a restored session runs under the tighter of the
  // limits the dump was taken with and the limits the loader asked for, so
  // a loader can tighten a dump but never loosen it.
  test("a restored dump keeps the tighter limit; the loading session's do not "
      'loosen it ($label)', () async {
    final pool = await _pool(start);
    // A dump taken under one depth limit, restored under the other: either
    // way the restored session runs under the tighter of the two.
    for (final (taken, loader) in <(int, int)>[
      (30, 1000),
      (1000, 30),
    ]) {
      final source = await _open(pool, _depth(taken));
      await source.feedRun(_rec);
      final saved = await source.dump();
      await source.close();
      final restored = await _open(pool, _depth(loader));
      try {
        await restored.loadSession(saved);
        await expectLater(
          restored.feedRun('rec(100)'),
          throwsA(_runtimeError('RecursionError')),
        );
      } finally {
        await restored.close();
      }
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

Uint8List _unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

void _crossBinding(String label, _Start start) {
  Future<MontyValue> continued(Monty pool, Uint8List dump) async {
    final session = await _open(pool);
    await session.loadSession(dump);

    return session.feedRun(dumpContinuationCode);
  }

  // Same-version idle dumps move between bindings both ways: upstream's
  // (recorded by tool/generate_dump_oracle.py) loads here, and the dump from
  // core's worker (_core_dump_fixture.g.dart) loads in upstream
  // (`generate_dump_oracle.py --check`) and here.
  test('an idle dump made by upstream loads and continues; so does a dump '
      'made by this worker ($label)', () async {
    final pool = await _pool(start);
    const expected = MontyString(dumpContinuationExpected);
    expect(await continued(pool, _unhex(upstreamIdleDumpHex)), expected);
    expect(await continued(pool, _unhex(coreIdleDumpHex)), expected);
    final made = await _idleDump(pool);
    expect(
      made.sublist(0, _headerLength),
      _unhex(upstreamIdleDumpHex).sublist(0, _headerLength),
    );
    expect(await continued(pool, made), expected);
  });
}

// ===========================================================================
// A restored session runs under the tighter of the dump's limits and the
// destination's (upstream's `ResourceTracker::tighten_limits`): a dump may
// keep a stricter limit of its own, never a looser one.
// ===========================================================================

/// The code that spends 12 MiB, past a 10 MiB ceiling.
const _memoryProbe = "large = b'a' * (12 * 1024 * 1024)\nlen(large)";

/// The host call a suspended case stops at.
const _pauseName = 'migration_pause';

/// The host function the suspended cases bind. It never runs: the call is
/// answered by hand, with [ExternalReturnValue].
MontyValue _pauseCall(
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) => const MontyInt(1);

/// What a restore case checks.
enum _RestoreLimitKind { recursion, memory }

/// One restore case: the limits the source session runs under, the limits
/// the destination session asks for, the code that must fail in the
/// restored session, and whether the dump is taken while the source is
/// suspended.
final class _RestoreLimitCase {
  const _RestoreLimitCase({
    required this.name,
    required this.kind,
    required this.source,
    required this.destination,
    required this.setup,
    required this.control,
    required this.controlValue,
    required this.probe,
    required this.expected,
    required this.suspended,
    this.fresh = false,
  });

  /// The case's name, in the failure messages.
  final String name;

  /// What the case checks.
  final _RestoreLimitKind kind;

  /// The source session's configuration.
  final SessionConfig source;

  /// The destination session's configuration.
  final SessionConfig destination;

  /// The code the source session runs before it dumps; empty runs none.
  final String setup;

  /// The small positive control, and the value it must return.
  final String control;
  final MontyValue controlValue;

  /// The code that must fail in the restored session.
  final String probe;

  /// The exception type the probe must raise.
  final String expected;

  /// Whether the dump is taken while the source is suspended.
  final bool suspended;

  /// Whether the case is a fresh session, with no dump at all.
  final bool fresh;
}

/// A session's memory ceiling, in MiB; null leaves it unlimited.
SessionConfig _memory(int? mebibytes) => SessionConfig(
  limits: ResourceLimits(
    maxMemory: mebibytes == null ? null : mebibytes * 1024 * 1024,
  ),
);

/// A recursion case: a dump taken under one depth, restored under the
/// other.
_RestoreLimitCase _recursionCase(
  int source,
  int destination,
  bool suspended,
) => _RestoreLimitCase(
  name:
      'recursion $source->$destination '
      '${suspended ? 'suspended' : 'idle'}',
  kind: _RestoreLimitKind.recursion,
  source: _depth(source),
  destination: _depth(destination),
  setup: _rec,
  control: 'rec(10)',
  controlValue: const MontyInt(0),
  probe: 'rec(100)',
  expected: 'RecursionError',
  suspended: suspended,
);

/// A memory case: a dump taken under one ceiling, restored under the other.
_RestoreLimitCase _memoryCase(
  int? source,
  int destination,
  bool suspended,
) => _RestoreLimitCase(
  name:
      'memory ${source ?? 'unlimited'}->$destination '
      '${suspended ? 'suspended' : 'idle'}',
  kind: _RestoreLimitKind.memory,
  source: _memory(source),
  destination: _memory(destination),
  setup: 'x = 42',
  control: '6 * 7',
  controlValue: const MontyInt(42),
  probe: _memoryProbe,
  expected: 'MemoryError',
  suspended: suspended,
);

/// The fresh control: a session under the 10 MiB ceiling that never saw a
/// dump.
_RestoreLimitCase _freshMemoryCase() => _RestoreLimitCase(
  name: 'fresh 10 MiB control',
  kind: _RestoreLimitKind.memory,
  source: _memory(10),
  destination: _memory(10),
  setup: '',
  control: '6 * 7',
  controlValue: const MontyInt(42),
  probe: _memoryProbe,
  expected: 'MemoryError',
  suspended: false,
  fresh: true,
);

/// The eleven cases: four recursion, six memory and the fresh control.
List<_RestoreLimitCase> _restoreLimitCases() => [
  for (final (source, destination) in <(int, int)>[(1000, 30), (30, 1000)])
    for (final suspended in [false, true])
      _recursionCase(source, destination, suspended),
  for (final (source, destination) in <(int?, int)>[
    (64, 10),
    (null, 10),
    (8, 64),
  ])
    for (final suspended in [false, true])
      _memoryCase(source, destination, suspended),
  _freshMemoryCase(),
];

/// Records [error] under [name] and [phase], keeping the earlier ones.
void _record(List<String> failures, String name, String phase, Object error) {
  failures.add('$name ($phase): $error');
}

/// Runs [body] and records any error under [name] and [phase]. The errors
/// already collected stay.
Future<void> _collect(
  List<String> failures,
  String name,
  String phase,
  Future<void> Function() body,
) async {
  try {
    await body();
  } on Object catch (error) {
    _record(failures, name, phase, error);
  }
}

/// Runs [body] and records any error under [name] and [phase], which then
/// yields null. The errors already collected stay.
Future<T?> _collecting<T>(
  List<String> failures,
  String name,
  String phase,
  Future<T> Function() body,
) async {
  try {
    return await body();
  } on Object catch (error) {
    _record(failures, name, phase, error);

    return null;
  }
}

/// The outcome of the probe: the error it raised, or the value it returned.
Future<String> _probeOutcome(Future<Object?> Function() probe) async {
  try {
    final value = await probe();

    return 'the probe completed with $value';
  } on MontyRuntimeError catch (error) {
    return 'the probe raised ${error.exception.excType}';
  }
}

/// The suspension on the host call: the migration pause, with no arguments.
FunctionSnapshot _requireFunctionSnapshot(MontySnapshot snapshot) {
  expect(snapshot, isA<FunctionSnapshot>());
  final call = snapshot as FunctionSnapshot;
  expect(call.functionName, _pauseName);
  expect(call.args, isEmpty);
  expect(call.kwargs, isEmpty);

  return call;
}

/// The dump the destination restores: the source's own bytes, taken while
/// it is idle or while it is suspended on the host call.
///
/// The source runs its setup and its small positive control to completion
/// first, so a dump is only taken from a session that works.
Future<Uint8List?> _dumpSource(
  _RestoreLimitCase descriptor,
  Monty pool,
  List<String> failures,
) async {
  final name = descriptor.name;
  final source = await _collecting(
    failures,
    name,
    'setup',
    () => pool.checkoutWith(descriptor.source),
  );
  if (source == null) return null;
  try {
    return await _collecting(failures, name, 'setup', () async {
      if (descriptor.setup.isNotEmpty) {
        await source.feedRun(descriptor.setup);
      }
      expect(await source.feedRun(descriptor.control), descriptor.controlValue);
      if (descriptor.suspended) {
        final snapshot = await source.feedStart(
          '$_pauseName()\n${descriptor.probe}',
          inputs: {_pauseName: const MontyHostFunction(_pauseName, _pauseCall)},
        );
        _requireFunctionSnapshot(snapshot);
      }

      return source.dump();
    });
  } finally {
    await _collect(failures, name, 'cleanup', source.close);
  }
}

/// Restores [dump] in [destination] and runs the probe there: a suspended
/// dump answers the host call first, an idle one feeds the probe.
Future<void> _loadAndProbe(
  _RestoreLimitCase descriptor,
  MontySession destination,
  Uint8List dump,
) async {
  if (descriptor.suspended) {
    final restored = _requireFunctionSnapshot(
      await destination.loadSnapshot(dump),
    );
    expect(
      await _probeOutcome(
        () => restored.resume(const ExternalReturnValue(MontyInt(1))),
      ),
      'the probe raised ${descriptor.expected}',
    );

    return;
  }
  await destination.loadSession(dump);
  expect(
    await _probeOutcome(() => destination.feedRun(descriptor.probe)),
    'the probe raised ${descriptor.expected}',
  );
}

/// The fresh control: a session under the 10 MiB ceiling that never saw a
/// dump computes, refuses the allocation, and computes again.
Future<void> _expectFreshMemoryControl(
  _RestoreLimitCase descriptor,
  MontySession session,
) async {
  final feed = session.feedRun;
  final control = descriptor.control;
  final value = descriptor.controlValue;
  expect(await feed(control), value);
  expect(
    await _probeOutcome(() => session.feedRun(descriptor.probe)),
    'the probe raised ${descriptor.expected}',
  );
  expect(await feed(control), value);
}

/// The case's body: the fresh control, or the source's dump and the
/// restored session that must refuse the probe.
Future<void> _runCase(
  _RestoreLimitCase descriptor,
  Monty pool,
  List<String> failures,
) async {
  final name = descriptor.name;
  if (descriptor.fresh) {
    final session = await pool.checkoutWith(descriptor.destination);
    try {
      await _expectFreshMemoryControl(descriptor, session);
    } finally {
      await _collect(failures, name, 'cleanup', session.close);
    }

    return;
  }
  final dump = await _dumpSource(descriptor, pool, failures);
  if (dump == null) return;
  final destination = await pool.checkoutWith(descriptor.destination);
  try {
    await _loadAndProbe(descriptor, destination, dump);
    expect(
      await destination.feedRun(descriptor.control),
      descriptor.controlValue,
    );
  } finally {
    await _collect(failures, name, 'cleanup', destination.close);
  }
}

/// Runs one case: its own pool, its own sessions, and the probe that must
/// fail in the restored session. Every error is collected under the case's
/// name, so one case cannot hide the others.
Future<void> _withRestoredCase(
  _RestoreLimitCase descriptor,
  _Start start,
  List<String> failures,
) async {
  final name = descriptor.name;
  final pool = await _collecting(
    failures,
    name,
    'setup',
    () => start(const PoolOptions(maxProcesses: 2)),
  );
  if (pool == null) return;
  try {
    await _collect(
      failures,
      name,
      'body',
      () => _runCase(descriptor, pool, failures),
    );
  } finally {
    await _collect(failures, name, 'cleanup', pool.close);
  }
}

/// The failures of the recursion cases: a restored session runs under the
/// tighter of the dump's depth and the destination's.
Future<List<String>> _expectRestoredRecursion(_Start start) async {
  final failures = <String>[];
  for (final descriptor in _restoreLimitCases()) {
    if (descriptor.kind != _RestoreLimitKind.recursion) continue;
    await _withRestoredCase(descriptor, start, failures);
  }

  return failures;
}

/// The failures of the memory cases, with the fresh control: a restored
/// session runs under the tighter of the dump's ceiling and the
/// destination's.
Future<List<String>> _expectRestoredMemory(_Start start) async {
  final failures = <String>[];
  for (final descriptor in _restoreLimitCases()) {
    if (descriptor.kind != _RestoreLimitKind.memory) continue;
    await _withRestoredCase(descriptor, start, failures);
  }

  return failures;
}

/// Registers the restore-limit cases: a restored session runs under the
/// tighter of the dump's limits and the destination's.
void restoreLimitSessionTests(
  String label,
  Future<Monty> Function(PoolOptions) start,
) {
  test(
    'a restored session runs under the tighter recursion depth ($label)',
    () async {
      final failures = await _expectRestoredRecursion(start);
      expect(failures, isEmpty, reason: 'the restored recursion depths');
    },
  );

  test(
    'a restored session runs under the tighter memory limit ($label)',
    () async {
      final failures = await _expectRestoredMemory(start);
      expect(failures, isEmpty, reason: 'the restored memory ceilings');
    },
  );
}

/// Runs every restore-limit case and returns the failures, after the
/// cleanup of each.
Future<List<String>> expectRestoredSessionLimits(
  Future<Monty> Function(PoolOptions) start,
) async {
  final failures = <String>[];
  for (final descriptor in _restoreLimitCases()) {
    await _withRestoredCase(descriptor, start, failures);
  }

  return failures;
}
