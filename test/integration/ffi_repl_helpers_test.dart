// Two whole public MontyRepl surfaces that nothing executed, plus the
// feed-loop branch for an external the caller never supplied a handler for.
//
// Picked off the gate's own coverage/honest.info rather than by guessing:
// monty_repl.dart 389-398 (`detectContinuation`), 459-465 (`clearState`) and
// 508-513 (the no-handler resume) were uncovered. The first two are public
// API a REPL UI is expected to call.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  late MontyRepl repl;

  setUp(() => repl = MontyRepl());
  tearDown(() => repl.dispose());

  group('detectContinuation classifies what a prompt must do next', () {
    // THREE DISTINCT RETURNS, not one. The method maps engine codes 1 and 2
    // onto two different enum values and everything else onto `complete`, so
    // a test that only checked "complete" would pass against a method that
    // returned `complete` unconditionally -- and a REPL UI would then never
    // show a `...` prompt.
    test('a finished expression is complete', () async {
      expect(
        await repl.detectContinuation('1 + 1'),
        ReplContinuationMode.complete,
      );
    });

    test('an unclosed bracket is an IMPLICIT continuation', () async {
      expect(
        await repl.detectContinuation('x = [1, 2,'),
        ReplContinuationMode.incompleteImplicit,
      );
    });

    test('an opened block is a BLOCK continuation', () async {
      // Distinct from the bracket case above: the engine reports a different
      // code, and a UI renders it the same way but exits it on a blank line
      // rather than on a closing bracket.
      expect(
        await repl.detectContinuation('if True:'),
        ReplContinuationMode.incompleteBlock,
      );
    });
  });

  group('clearState', () {
    test('forgets names defined before it', () async {
      await repl.feedRun('kept = 41');
      expect((await repl.feedRun('kept')).value, const MontyInt(41));

      await repl.clearState();

      // A fresh engine handle: the binding is disposed and recreated, so the
      // name must be gone. If clearState only reset bookkeeping the name
      // would survive and this reads 41 again.
      final after = await repl.feedRun('kept');
      expect(
        after.ok,
        isFalse,
        reason: 'the name must not survive a state clear',
      );
    });

    test('the REPL still works after a clear', () async {
      // The handle is recreated lazily; if that never happened, every later
      // call would fail on a disposed binding rather than on the clear itself.
      await repl.clearState();
      expect((await repl.feedRun('2 + 3')).value, const MontyInt(5));
    });

    test('refuses mid-execution rather than pulling the handle away', () async {
      // A paused feedStart/resume loop holds engine state. Clearing under it
      // would free the handle the pending call is going to resume into.
      final pending = await repl.feedStart(
        'need_me()',
        externalFunctions: ['need_me'],
      );
      expect(pending, isA<MontyPending>());

      await expectLater(
        repl.clearState(),
        throwsA(isA<StateError>()),
        reason: 'clearState must refuse while a resume is outstanding',
      );
    });
  });

  test('an external with no handler fails by name, not silently', () async {
    // feedRun DECLARES externals by supplying callbacks. Asking the engine for
    // one the caller never supplied is the mismatch case, and the message has
    // to name the function or the caller cannot tell which one they forgot.
    // No externalFunctions argument at all -- the default is already empty,
    // and passing `const {}` explicitly is the same call.
    final result = await repl.feedRun('missing_tool()');

    expect(result.ok, isFalse);
    expect(
      '${result.error}',
      contains('missing_tool'),
      reason: 'the unhandled function name must reach the caller',
    );
  });
}
