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
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

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
