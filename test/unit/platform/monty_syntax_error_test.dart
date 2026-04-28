// Unit tests for MontySyntaxError type hierarchy and routing.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  group('MontySyntaxError type hierarchy', () {
    test('is a MontyScriptError', () {
      const err = MontySyntaxError('bad syntax');
      expect(err, isA<MontyScriptError>());
    });

    test('is a MontyError', () {
      const err = MontySyntaxError('bad syntax');
      expect(err, isA<MontyError>());
    });

    test('is an Exception', () {
      const err = MontySyntaxError('bad syntax');
      expect(err, isA<Exception>());
    });

    test('on MontyScriptError catches MontySyntaxError', () {
      MontySyntaxError? caught;
      try {
        throw const MontySyntaxError('oops', excType: 'SyntaxError');
      } on MontyScriptError catch (e) {
        caught = e as MontySyntaxError;
      }
      expect(caught, isNotNull);
    });

    test('toString contains SyntaxError', () {
      const err = MontySyntaxError('invalid syntax', excType: 'SyntaxError');
      expect(err.toString(), contains('SyntaxError'));
    });

    test('excType is preserved', () {
      const err = MontySyntaxError('bad', excType: 'SyntaxError');
      expect(err.excType, 'SyntaxError');
    });

    test('exception field is accessible', () {
      const exc = MontyException(message: 'parse error');
      const err = MontySyntaxError(
        'parse error',
        excType: 'SyntaxError',
        exception: exc,
      );
      expect(err.exception, exc);
    });
  });

  // -------------------------------------------------------------------------
  group('MontySyntaxError routing', () {
    // Simulate a platform that raises SyntaxError by enqueueing a complete
    // result that carries the error — the session's _safeCall converts
    // MontyScriptError into a MontyComplete with error set. For direct
    // routing tests we call platform.run() and expect the throw.

    test('routing tested via type hierarchy', () {
      // BaseMontyPlatform._throwError routes SyntaxError excType to
      // MontySyntaxError. Here we verify the type properties directly;
      // the actual routing path is an FFI-level concern.
      const err = MontySyntaxError('def foo(', excType: 'SyntaxError');
      expect(err, isA<MontyScriptError>());
      expect(err.excType, 'SyntaxError');
    });

    test('ValueError exc_type does NOT produce MontySyntaxError', () {
      const err = MontyScriptError('oops', excType: 'ValueError');
      expect(err, isNot(isA<MontySyntaxError>()));
    });

    test('MontySyntaxError is caught by `on MontyScriptError`', () async {
      // MontyRepl.feedRun catches MontyScriptError internally (including
      // MontySyntaxError) and returns it via MontyResult.error. Verify
      // the type hierarchy that powers that catch.
      const syntax = MontySyntaxError('bad', excType: 'SyntaxError');
      Object caught = '';
      try {
        throw syntax;
      } on MontyScriptError catch (e) {
        caught = e;
      }
      expect(caught, isA<MontySyntaxError>());
    });
  });

  // -------------------------------------------------------------------------
  group('MontySyntaxError vs MontyScriptError discrimination', () {
    test('catch block ordering works', () {
      // Verify the intended usage pattern compiles and routes correctly.
      MontySyntaxError? syntaxCaught;
      MontyScriptError? scriptCaught;

      void run(MontyScriptError e) {
        try {
          throw e;
        } on MontySyntaxError catch (e) {
          syntaxCaught = e;
        } on MontyScriptError catch (e) {
          scriptCaught = e;
        }
      }

      run(const MontySyntaxError('parse fail', excType: 'SyntaxError'));
      expect(syntaxCaught, isNotNull);
      expect(scriptCaught, isNull);

      syntaxCaught = null;

      run(const MontyScriptError('runtime fail', excType: 'ValueError'));
      expect(syntaxCaught, isNull);
      expect(scriptCaught, isNotNull);
    });
  });
}
