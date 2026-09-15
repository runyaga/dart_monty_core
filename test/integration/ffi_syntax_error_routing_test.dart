// A real SyntaxError from the engine must arrive as `MontySyntaxError`, not as
// the `MontyScriptError` everything else becomes.
//
// `BaseMontyPlatform._throwError` (base_monty_platform.dart:496-514) routes by
// `excType`:
//
//     if (e.excType == 'SyntaxError') { throw MontySyntaxError(...); }
//     throw MontyScriptError(...);
//
// Found by the disabled-guard mutation family: rewriting that condition to
// `false` sends every syntax error out as a plain MontyScriptError, and the
// whole suite stayed green.
//
// WHY THE EXISTING FILE DID NOT COVER IT. `monty_syntax_error_test.dart` builds
// the error by hand -- `const MontySyntaxError('bad syntax')` -- and asserts
// its type hierarchy. That is the echo chamber: the test constructs the thing
// it asserts about, so it holds whatever the ROUTING does. Nothing anywhere
// provoked a syntax error through the engine and checked which subtype came
// back.
//
// MEASURED, and the call matters. `run()` does NOT reach this code: a Python
// SyntaxError returns `ok` with `error`/`excType` populated, so `run()` hands
// back a MontyResult rather than throwing (probed: "def (", "x = = 1", "1 +"
// all return error.excType == SyntaxError). `_throwError` fires only when the
// core reports NOT-ok, which is what `compileCode` does. `typeCheck` does not
// throw at all.
//
// Falsifier: rewrite that condition to `false`; only this test fails.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('SyntaxError routing, from the engine', () {
    test('compileCode on bad syntax throws MontySyntaxError', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      await expectLater(
        m.compileCode('def ('),
        throwsA(isA<MontySyntaxError>()),
      );
    });

    test('and it is still catchable as its supertype', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      // The subtype must not break `on MontyScriptError` handlers. Asserting
      // BOTH directions is the point: the routing has to be more specific
      // without being incompatible.
      Object? caught;
      try {
        await m.compileCode('x = = 1');
      } on MontyScriptError catch (e) {
        caught = e;
      }
      expect(caught, isA<MontySyntaxError>());
    });

    // DELIBERATELY ABSENT: "a NON-syntax failure still routes to
    // MontyScriptError". Measured -- I could not construct one through this
    // path. `compileCode` on `break` and on `def (` BOTH yield
    // MontySyntaxError (both are syntax errors), and `return 1` raises an
    // unrelated StateError before reaching the routing. A first attempt
    // asserted `r.error` from `run()` was not a MontySyntaxError, which is
    // meaningless: `r.error` is a MontyException, a different hierarchy
    // entirely from the thrown MontyError. Left out rather than kept as an
    // assertion that cannot fail.
  });
}
