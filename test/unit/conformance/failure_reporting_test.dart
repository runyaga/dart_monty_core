// A harness that hides the diagnosis is not a diagnostic (core#145).
//
// A failing fixture used to report exactly this, and nothing else:
//
//     oracle_ffi_ext datetime__core.py [E]
//       unexpected error in datetime__core.py
//
// while the actual failure was `AssertionError` at line 17 on
// `assert now_utc.tzinfo is datetime.timezone.utc`. The error carried the
// type, the message and a traceback with the line and its source, and every
// one was discarded to print the word "unexpected".
//
// This matters past developer time. The package exists so an LLM can generate
// Monty Python and RETRY when it fails; "unexpected error" gives a model
// nothing to act on — it cannot localise the fault or tell a syntax problem
// from a runtime one. The exception type, message and line are what make a
// retry informed rather than a guess.
@Tags(['unit'])
library;

import 'package:dart_monty_core/src/worker/monty_error.dart' show raisedError;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

void main() {
  group('a fixture failure reports what actually failed (core#145)', () {
    test('describeFixtureFailure names type, message and line', () {
      const e = FixtureFailure(
        excType: 'AssertionError',
        message: 'assertion failed',
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

    test("a worker error's innermost frame gives the line and source", () {
      final error = raisedError(
        pb.RaisedException(
          excType: 'AssertionError',
          message: 'assertion failed',
          traceback: [
            pb.StackFrame(
              filename: 'datetime__core.py',
              start: pb.CodeLoc(line: 3, column: 1),
              end: pb.CodeLoc(line: 3, column: 4),
              frameName: '<module>',
              previewLine: 'f()',
            ),
            pb.StackFrame(
              filename: 'datetime__core.py',
              start: pb.CodeLoc(line: 17, column: 5),
              end: pb.CodeLoc(line: 17, column: 52),
              frameName: 'f',
              previewLine: '    assert now_utc.tzinfo is datetime.timezone.utc',
            ),
          ],
        ),
      );

      final failure = FixtureFailure.fromError(error);
      expect(failure.excType, 'AssertionError');
      expect(failure.message, 'assertion failed');
      expect(failure.lineNumber, 17);
      expect(
        describeFixtureFailure('datetime__core.py', failure),
        'datetime__core.py:17 — AssertionError: assertion failed\n'
        '    assert now_utc.tzinfo is datetime.timezone.utc',
      );
    });

    test('it degrades honestly when the engine gave no detail', () {
      final described = describeFixtureFailure('x.py', null);

      expect(described, contains('x.py'));
      // No line to report is a fact worth stating, not a blank.
      expect(described, contains('no exception detail'));
    });
  });
}
