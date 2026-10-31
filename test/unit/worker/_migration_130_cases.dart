// The cases the 1.3.0 migration turns on: what the worker answers that
// 1.2.0 answered differently. Shared by the VM runner
// (test/integration/worker/migration_130_io_test.dart) and by any browser
// runner that registers the same cases, so every backend runs them alike;
// [label] names the backend.
//
// (1) A type-checked feed nested past the parser's nesting limit is
// rejected as a syntax error, at once. On 1.2.0 the type check walked the
// deep AST instead and the feed ran into its deadline: the worker was killed
// after the limit plus its grace (finding 39).
//
// (2) The type of a cached function reaches the host as the builtin type
// proxy it names. On 1.2.0 `functools` had no `cache` at all, so the feed
// raised AttributeError (finding 21).
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_dump_120_fixture.g.dart';

/// Starts the pool a case runs in.
typedef MigrationStart = Future<Monty> Function(PoolOptions);

/// A source nested past the parser's nesting limit: upstream's limit is
/// 200, so 250 open brackets are over it.
String _deepNesting() => '[' * 250;

/// The feed whose answer is the type of a cached function.
const _cachedType =
    'import functools\n'
    'def f(x):\n'
    '    return x\n'
    'type(functools.cache(f))';

/// The type the host must see for a cached function.
const _cachedTypeName = 'functools._lru_cache_wrapper';

/// A feed that populates an `lru_cache` wrapper in globals.
const _cachedGlobals =
    'import functools\n'
    'def sq(n):\n'
    '    return n * n\n'
    'sq = functools.lru_cache(maxsize=4)(sq)\n'
    'sq(3)\n';

/// Reads a cached hit, a fresh miss, and the hit count after restore.
const _cacheProbe = 'sq(3) + sq(4) + sq.cache_info().hits';

/// Reads the globals (`x`, `y`, `f`) from the 1.2.0 idle dump fixture.
const _idle120Probe = 'f(41) + len(x) + len(y)';

/// The 8-byte header of a Monty dump: `MONTY\0` plus little-endian version 13.
const _dumpHeaderLength = 8;

/// The header bytes for `DUMP_VERSION` 13 (`0x000d` little-endian).
const _dumpVersion13Header = [0x4d, 0x4f, 0x4e, 0x54, 0x59, 0, 13, 0];

/// The refusal message when an external call suspends in a sync context.
const _syncRefusalMessage =
    "external function 'ext' cannot suspend in this synchronous context";

const _reduceSuspendCode =
    'import functools\n'
    'functools.reduce(lambda a, b: a + ext(b), [1, 2, 3], 0)';

const _iterSuspendCode =
    'class It:\n'
    '    def __iter__(self):\n'
    '        ext(1)\n'
    '        return iter([7, 8])\n'
    'list(iter(It()))';

const _nextDefaultSuspendCode =
    'class N:\n'
    '    def __iter__(self):\n'
    '        return self\n'
    '    def __next__(self):\n'
    '        ext(2)\n'
    '        raise StopIteration\n'
    'next(N(), "dflt")';

const _cacheMissSuspendCode =
    'import functools\n'
    'def g(x):\n'
    '    return ext(x) * 10\n'
    'g = functools.cache(g)\n'
    'g(4) + g(4)';

const _forLoopNextRefusalCode =
    'class F:\n'
    '    def __iter__(self):\n'
    '        return self\n'
    '    def __next__(self):\n'
    '        ext(3)\n'
    '        raise StopIteration\n'
    'for _ in F():\n'
    '    pass\n'
    '"done"';

const _sortedKeyRefusalCode = 'sorted([3, 1, 2], key=lambda v: ext(v))';

Uint8List _unhex(String hex) => Uint8List.fromList([
  for (var index = 0; index < hex.length; index += 2)
    int.parse(hex.substring(index, index + 2), radix: 16),
]);

/// The outcome of a feed: the value it answered, or the error it raised.
///
/// The error is a value here, so the expectation below fails on it rather
/// than the test failing on an exception that escaped.
Future<Object?> _outcome(Future<MontyValue> feed) async {
  try {
    return await feed;
  } on MontyError catch (error) {
    return error;
  }
}

/// Registers the 1.3.0 migration cases for the backend [label].
void migration130SessionTests(String label, MigrationStart start) {
  _deepNestingCase(label, start);
  _cachedTypeCase(label, start);
  _cachedDumpRoundTripCase(label, start);
  _idleDump120RestoresCase(label, start);
  _suspensionCases(label, start);
}

/// The feed nested past the parser's limit is rejected at once.
void _deepNestingCase(String label, MigrationStart start) {
  test(
    'a type-checked feed nested past the parser limit is rejected promptly '
    '($label)',
    () async {
      final pool = await start(const PoolOptions(maxProcesses: 1));
      addTearDown(pool.close);
      final session = await pool.checkoutWith(
        const SessionConfig(
          typeCheck: true,
          limits: ResourceLimits(maxFeedDuration: Duration(seconds: 2)),
        ),
      );
      addTearDown(session.close);

      final watch = Stopwatch()..start();
      await expectLater(
        session.feedRun(_deepNesting()),
        throwsA(
          isA<MontySyntaxError>().having(
            (error) => error.toString(),
            'message',
            contains('Source is too deeply nested'),
          ),
        ),
        reason: 'a source nested past the parser limit is a syntax error',
      );
      // The answer comes at once: the feed never reaches its deadline.
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 1)),
        reason: 'the feed is rejected before its deadline, not after it',
      );
    },
  );
}

/// The type of a cached function reaches the host, and the session runs on.
void _cachedTypeCase(String label, MigrationStart start) {
  test(
    "a cached function's type reaches the host and the session stays usable "
    '($label)',
    () async {
      final pool = await start(const PoolOptions(maxProcesses: 1));
      addTearDown(pool.close);
      final session = await pool.checkoutWith();
      addTearDown(session.close);

      await expectLater(
        _outcome(session.feedRun(_cachedType)),
        completion(
          isA<MontyStdTypeProxy>()
              .having((proxy) => proxy.kind, 'kind', 'type')
              .having((proxy) => proxy.name, 'name', _cachedTypeName),
        ),
        reason: 'the type of a cached function reaches the host as its type',
      );
      // The session runs on after the answer.
      expect(
        await session.feedRun('1 + 1'),
        const MontyInt(2),
        reason: 'the session is still usable after the answer',
      );
    },
  );
}

/// An idle dump holding a cached function restores with its cache intact.
void _cachedDumpRoundTripCase(String label, MigrationStart start) {
  test(
    'an idle dump holding a cached function restores with its cache intact '
    '($label)',
    () async {
      final pool = await start(const PoolOptions(maxProcesses: 1));
      addTearDown(pool.close);

      final checkout = pool.checkoutWith;
      final source = await checkout();
      final Uint8List dump;
      try {
        await source.feedRun(_cachedGlobals);
        dump = await source.dump();
      } finally {
        await source.close();
      }

      final restored = await checkout();
      addTearDown(restored.close);
      await restored.loadSession(dump);
      expect(
        await restored.feedRun(_cacheProbe),
        const MontyInt(26),
        reason: 'sq(3) hits cache (9 + 1 hit) and sq(4) computes 16',
      );
    },
  );
}

/// An idle dump from 1.2.0 restores on 1.3.0 under DUMP_VERSION 13.
void _idleDump120RestoresCase(String label, MigrationStart start) {
  test(
    'an idle dump from 1.2.0 restores on 1.3.0 with its globals intact '
    '($label)',
    () async {
      final dump = _unhex(idleDump120Hex);
      expect(
        dump.sublist(0, _dumpHeaderLength),
        _dumpVersion13Header,
        reason: 'the 1.2.0 fixture carries DUMP_VERSION 13 in its header',
      );

      final pool = await start(const PoolOptions(maxProcesses: 1));
      addTearDown(pool.close);
      final session = await pool.checkoutWith();
      addTearDown(session.close);

      await session.loadSession(dump);
      expect(
        await session.feedRun(_idle120Probe),
        const MontyInt(46),
        reason: 'f(41) is 42, len(x) is 3, and len(y) is 1',
      );
      // Both releases write DUMP_VERSION 13 in the dump header.
      final freshDump = await session.dump();
      expect(
        freshDump.sublist(0, _dumpHeaderLength),
        _dumpVersion13Header,
        reason: 'this worker also writes DUMP_VERSION 13',
      );
    },
  );
}

/// Registers the six 1.3.0 suspension boundary cases for [label].
void _suspensionCases(String label, MigrationStart start) {
  _suspensionAllowCase(
    label,
    start,
    name: 'reduce callback',
    code: _reduceSuspendCode,
    expectedArgs: const [1, 2, 3],
    output: const MontyInt(306),
  );
  _suspensionAllowCase(
    label,
    start,
    name: 'iter method',
    code: _iterSuspendCode,
    expectedArgs: const [1],
    output: const MontyList([MontyInt(7), MontyInt(8)]),
  );
  _suspensionAllowCase(
    label,
    start,
    name: 'next with default',
    code: _nextDefaultSuspendCode,
    expectedArgs: const [2],
    output: const MontyString('dflt'),
  );
  _suspensionAllowCase(
    label,
    start,
    name: 'cache miss',
    code: _cacheMissSuspendCode,
    expectedArgs: const [4],
    output: const MontyInt(2080),
  );
  _suspensionRefusalCase(
    label,
    start,
    name: 'for loop next refusal',
    code: _forLoopNextRefusalCode,
  );
  _suspensionRefusalCase(
    label,
    start,
    name: 'sorted key refusal',
    code: _sortedKeyRefusalCode,
  );
}

/// Runs [code] through `feedStart`, answering each `ext(n)` call with
/// `n + 100`.
Future<(List<int>, MontyValue)> _driveExtCalls(
  MontySession session,
  String code,
) async {
  final seenArgs = <int>[];
  var snapshot = await session.feedStart(code);
  while (snapshot is FunctionSnapshot) {
    expect(snapshot.functionName, 'ext');
    if (snapshot.args case [final MontyInt argument]) {
      final number = argument.value;
      seenArgs.add(number);
      snapshot = await snapshot.resume(
        ExternalReturnValue(MontyInt(number + 100)),
      );
    } else {
      fail('expected a single MontyInt argument, got ${snapshot.args}');
    }
  }
  if (snapshot is! MontyComplete) {
    fail('expected MontyComplete, got $snapshot');
  }

  return (seenArgs, snapshot.output);
}

/// Registers a test that verifies [code] suspends on `ext` and returns
/// [output].
void _suspensionAllowCase(
  String label,
  MigrationStart start, {
  required String name,
  required String code,
  required List<int> expectedArgs,
  required MontyValue output,
}) {
  test('suspension: $name ($label)', () async {
    final pool = await start(const PoolOptions(maxProcesses: 1));
    addTearDown(pool.close);
    final session = await pool.checkoutWith();
    addTearDown(session.close);

    final (seenArgs, actualOutput) = await _driveExtCalls(session, code);
    expect(seenArgs, expectedArgs);
    expect(actualOutput, output);
    expect(await session.feedRun('1 + 1'), const MontyInt(2));
  });
}

/// Registers a test that verifies [code] refuses to suspend in a sync context.
void _suspensionRefusalCase(
  String label,
  MigrationStart start, {
  required String name,
  required String code,
}) {
  test('suspension: $name ($label)', () async {
    final pool = await start(const PoolOptions(maxProcesses: 1));
    addTearDown(pool.close);
    final session = await pool.checkoutWith();
    addTearDown(session.close);

    await expectLater(
      session.feedStart(code),
      throwsA(
        isA<MontyRuntimeError>()
            .having(
              (error) => error.exception.excType,
              'excType',
              'NotImplementedError',
            )
            .having(
              (error) => error.exception.message,
              'message',
              contains(_syncRefusalMessage),
            ),
      ),
    );
    expect(await session.feedRun('1 + 1'), const MontyInt(2));
  });
}
