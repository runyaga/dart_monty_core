// What the feed loop does when the HOST's side goes wrong.
//
// Off the gate's own coverage/honest.info: monty_repl.dart 191 (the
// disjointness guard), 559-560 (a sync callback threw), 586-587 (an async
// callback threw) and 59-62 (building the MontyException with its traceback)
// were uncovered. Every one of them is a path a host reaches by making an
// ordinary mistake, which is exactly when the error text has to be good.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  late MontyRepl repl;

  setUp(() => repl = MontyRepl());
  tearDown(() => repl.dispose());

  test('a name in BOTH callback maps is refused, and named', () async {
    // Sync and async handlers for one name are ambiguous: the loop picks the
    // async one (`asyncCb ?? syncCb`), so accepting the call would silently
    // ignore the sync handler the caller also supplied.
    // Hoisted so the `async` can carry its own note: it is what makes this an
    // ASYNC handler, which is the whole conflict being refused.
    // ignore: avoid-unnecessary-futures
    Future<Object?> asyncX(List<Object?> _, Map<String, Object?>? _) async => 2;

    await expectLater(
      repl.feedRun(
        'x()',
        externalFunctions: {'x': (a, k) => 1},
        externalAsyncFunctions: {'x': asyncX},
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('disjoint'), contains('x')),
        ),
      ),
      reason: 'the overlapping key must be named, not just the rule',
    );
  });

  test('a SYNC callback that throws surfaces its message in Python', () async {
    // The loop catches the Dart throw and resumes the engine with an error, so
    // Python raises at the call site. Losing this makes a host bug look like
    // an engine bug.
    final result = await repl.feedRun(
      'tool()',
      externalFunctions: {
        'tool': (args, kwargs) => throw StateError('host tool exploded'),
      },
    );

    expect(result.ok, isFalse);
    expect('${result.error}', contains('host tool exploded'));
  });

  test('an AWAITED async callback that throws is reported', () async {
    // A different branch from the sync case: the future is registered first
    // and only fails when awaited, so the error travels back through
    // resolveFutures' error map rather than through resumeWithError.
    final result = await repl.feedRun(
      'await tool()',
      externalAsyncFunctions: {
        // THE `async` IS LOAD-BEARING, not noise. Dropping it makes the
        // throw SYNCHRONOUS at the call site, which is a different path
        // entirely -- the future is never registered, so resolveFutures'
        // error map is never reached and these tests would silently stop
        // covering the branch they exist for.
        // ignore: avoid-unnecessary-futures
        'tool': (args, kwargs) async => throw StateError('async tool failed'),
      },
    );

    expect(result.ok, isFalse);
    expect('${result.error}', contains('async tool failed'));
  });

  test('an UN-awaited async callback never runs, so it cannot fail', () async {
    // Python semantics, and a trap worth stating outright: `tool()` on an
    // async external builds a coroutine and does not call it, so the host
    // callback is never invoked and its throw cannot surface. Measured: the
    // run COMPLETES and the value is the coroutine object.
    //
    // This case exists because the obvious way to test the branch above is to
    // write `tool()` and expect a failure. I did exactly that, got ok == true,
    // and it reads as an error swallowed by the engine. It is not.
    final result = await repl.feedRun(
      'tool()',
      externalAsyncFunctions: {
        // THE `async` IS LOAD-BEARING, not noise. Dropping it makes the
        // throw SYNCHRONOUS at the call site, which is a different path
        // entirely -- the future is never registered, so resolveFutures'
        // error map is never reached and these tests would silently stop
        // covering the branch they exist for.
        // ignore: avoid-unnecessary-futures
        'tool': (args, kwargs) async => throw StateError('never reached'),
      },
    );

    expect(result.ok, isTrue);
    expect('${result.value}', contains('coroutine'));
  });

  test(
    'a raising script comes back with a typed exception and frames',
    () async {
      // MontyException is built only when the result carries an error, and its
      // traceback is decoded from the wire. A result that reported the message
      // but dropped the frames would still look fine to `ok == false`.
      final result = await repl.feedRun(
        'def inner():\n'
        '    raise ValueError("deliberate")\n'
        'inner()\n',
      );

      expect(result.ok, isFalse);
      // `MontyResult.error` IS the MontyException, not a string -- `ok`
      // is defined as `error == null`.
      final exception = result.error;
      if (exception == null) {
        fail('a raise must produce an exception, got ok=${result.ok}');
      }
      expect(exception.excType, 'ValueError');
      expect(exception.message, contains('deliberate'));
      expect(
        exception.traceback,
        isNotEmpty,
        reason: 'the frames are what make this debuggable',
      );
    },
  );
}
