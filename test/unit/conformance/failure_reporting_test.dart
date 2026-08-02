// A harness that hides the diagnosis is not a diagnostic (core#145).
//
// A failing fixture used to report exactly this, and nothing else:
//
//     oracle_ffi_ext datetime__core.py [E]
//       unexpected error in datetime__core.py
//
// while the actual failure was `AssertionError` at line 17 on
// `assert now_utc.tzinfo is datetime.timezone.utc`. `MontyException` carries
// message, excType, lineNumber, columnNumber, sourceCode and traceback, and
// every one was discarded to print the word "unexpected".
//
// This matters past developer time. The package exists so an LLM can generate
// Monty Python and RETRY when it fails; "unexpected error" gives a model
// nothing to act on — it cannot localise the fault or tell a syntax problem
// from a runtime one. The exception type, message and line are what make a
// retry informed rather than a guess.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

void main() {
  group('a fixture failure reports what actually failed (core#145)', () {
    test('describeFixtureFailure names type, message and line', () {
      const e = MontyException(
        message: 'assertion failed',
        excType: 'AssertionError',
        lineNumber: 17,
        sourceCode: 'assert now_utc.tzinfo is datetime.timezone.utc',
      );

      final described = describeFixtureFailure('datetime__core.py', e);

      expect(described, contains('datetime__core.py'));
      expect(described, contains('AssertionError'));
      expect(described, contains('17'));
      expect(described, contains('assert now_utc.tzinfo'));
      // The word that used to be the entire report.
      expect(
        described.toLowerCase(),
        isNot(contains('unexpected')),
        reason:
            'the description must say what happened, not that something did',
      );
    });

    test('it degrades honestly when the engine gave no detail', () {
      final described = describeFixtureFailure('x.py', null);

      expect(described, contains('x.py'));
      // No line to report is a fact worth stating, not a blank.
      expect(described, contains('no exception detail'));
    });

    test('DispatchOutcome carries the exception, not just its type', () {
      const e = MontyException(
        message: 'boom',
        excType: 'ValueError',
        lineNumber: 3,
      );
      const o = DispatchOutcome(excType: 'ValueError', exception: e);

      expect(o.exception?.lineNumber, 3);
      expect(o.exception?.message, 'boom');
    });
  });
}
