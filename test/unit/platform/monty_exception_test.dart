// Unit tests for MontyException and the MontyError subclasses that aren't
// already covered (MontyPanicError, MontyCrashError, MontyDisposedError,
// MontyResourceError, MontySuspensionBudgetExceeded).
//
// Existing coverage skipped to avoid duplication:
//   - MontySyntaxError hierarchy  → monty_syntax_error_test.dart
//   - MontyTypingError            → monty_typing_error_test.dart
//
// Pure value-level tests: no interpreter, no FFI, no WASM.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  // ------------------------------------------------------------------
  // MontyException
  // ------------------------------------------------------------------

  group('MontyException equality + hashCode', () {
    test('identical fields compare equal', () {
      const a = MontyException(
        message: 'm',
        filename: 'f.py',
        lineNumber: 1,
        columnNumber: 2,
        sourceCode: 'x',
        excType: 'ValueError',
      );
      const b = MontyException(
        message: 'm',
        filename: 'f.py',
        lineNumber: 1,
        columnNumber: 2,
        sourceCode: 'x',
        excType: 'ValueError',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different excType is not equal', () {
      expect(
        const MontyException(message: 'x', excType: 'ValueError'),
        isNot(const MontyException(message: 'x', excType: 'TypeError')),
      );
    });

    test('different lineNumber is not equal', () {
      expect(
        const MontyException(message: 'x', lineNumber: 1),
        isNot(const MontyException(message: 'x', lineNumber: 2)),
      );
    });

    test('traceback uses deep equality (independent List instances)', () {
      // Build the traceback lists at runtime so they are guaranteed to be
      // distinct List instances (no const canonicalisation). Each holds
      // the same canonical MontyStackFrame, but the *lists* are not
      // identical — exactly the scenario where deep equality matters.
      final tracebackA = List<MontyStackFrame>.from(const [
        MontyStackFrame(filename: 'f.py', startLine: 1, startColumn: 0),
      ]);
      final tracebackB = List<MontyStackFrame>.from(const [
        MontyStackFrame(filename: 'f.py', startLine: 1, startColumn: 0),
      ]);
      expect(identical(tracebackA, tracebackB), isFalse);

      final a = MontyException(message: 'x', traceback: tracebackA);
      final b = MontyException(message: 'x', traceback: tracebackB);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different traceback length is not equal', () {
      const oneFrame = [
        MontyStackFrame(filename: 'f.py', startLine: 1, startColumn: 0),
      ];
      const twoFrames = [
        MontyStackFrame(filename: 'f.py', startLine: 1, startColumn: 0),
        MontyStackFrame(filename: 'g.py', startLine: 2, startColumn: 0),
      ];
      expect(
        const MontyException(message: 'x', traceback: oneFrame),
        isNot(const MontyException(message: 'x', traceback: twoFrames)),
      );
    });
  });

  group('MontyException JSON round-trip', () {
    test('minimal exception (message only)', () {
      const e = MontyException(message: 'plain');
      expect(MontyException.fromJson(e.toJson()), e);
    });

    test('full exception with all optional fields populated', () {
      const e = MontyException(
        message: 'bad value',
        filename: 'main.py',
        lineNumber: 10,
        columnNumber: 4,
        sourceCode: "raise ValueError('bad')",
        excType: 'ValueError',
        traceback: [
          MontyStackFrame(
            filename: 'main.py',
            startLine: 10,
            startColumn: 4,
            frameName: '<module>',
            previewLine: "raise ValueError('bad')",
          ),
        ],
      );
      expect(MontyException.fromJson(e.toJson()), e);
    });

    test('toJson omits all null fields', () {
      const e = MontyException(message: 'plain');
      final json = e.toJson();
      expect(json.keys, ['message']);
    });

    test('toJson omits empty traceback list', () {
      const e = MontyException(message: 'x', excType: 'ValueError');
      final json = e.toJson();
      expect(json.containsKey('traceback'), isFalse);
    });

    test('toJson includes traceback when non-empty', () {
      const e = MontyException(
        message: 'x',
        traceback: [
          MontyStackFrame(filename: 'a.py', startLine: 1, startColumn: 0),
        ],
      );
      expect(e.toJson()['traceback'], isA<List<Object?>>());
    });
  });

  group('MontyException.toString', () {
    test('message-only', () {
      expect(
        const MontyException(message: 'plain').toString(),
        'MontyException: plain',
      );
    });

    test('with excType prepends the type', () {
      expect(
        const MontyException(message: 'bad', excType: 'ValueError').toString(),
        'MontyException: ValueError: bad',
      );
    });

    test('with filename appends a (path) suffix', () {
      expect(
        const MontyException(message: 'x', filename: 'main.py').toString(),
        'MontyException: x (main.py)',
      );
    });

    test('with filename + lineNumber appends (path:line)', () {
      expect(
        const MontyException(
          message: 'x',
          filename: 'main.py',
          lineNumber: 5,
        ).toString(),
        'MontyException: x (main.py:5)',
      );
    });

    test(
      'with filename + lineNumber + columnNumber appends (path:line:col)',
      () {
        expect(
          const MontyException(
            message: 'x',
            filename: 'main.py',
            lineNumber: 5,
            columnNumber: 12,
          ).toString(),
          'MontyException: x (main.py:5:12)',
        );
      },
    );

    test('column without filename does not produce a position suffix', () {
      // Defensive: filename is the gate — no filename means no (path)
      // suffix even if line/column are set.
      expect(
        const MontyException(
          message: 'x',
          lineNumber: 5,
          columnNumber: 12,
        ).toString(),
        'MontyException: x',
      );
    });
  });

  // ------------------------------------------------------------------
  // MontyError subclasses (other than MontySyntaxError, already covered)
  // ------------------------------------------------------------------

  group('MontyPanicError', () {
    test('is a MontyError + Exception', () {
      const e = MontyPanicError('rust panicked');
      expect(e, isA<MontyError>());
      expect(e, isA<Exception>());
    });

    test('is NOT a MontyScriptError (different supervisor action)', () {
      const e = MontyPanicError('rust panicked');
      expect(e, isNot(isA<MontyScriptError>()));
    });

    test('toString contains type name and message', () {
      const e = MontyPanicError('boom');
      expect(e.toString(), 'MontyPanicError: boom');
    });

    test('message is preserved', () {
      const e = MontyPanicError('detailed message here');
      expect(e.message, 'detailed message here');
    });
  });

  group('MontyCrashError', () {
    test('default message when none supplied', () {
      expect(
        const MontyCrashError().message,
        'Interpreter crashed unexpectedly',
      );
    });

    test('custom message overrides default', () {
      expect(
        const MontyCrashError('worker exited 137').message,
        'worker exited 137',
      );
    });

    test('toString contains type name and message', () {
      expect(
        const MontyCrashError().toString(),
        'MontyCrashError: Interpreter crashed unexpectedly',
      );
    });

    test('is a MontyError + Exception', () {
      const e = MontyCrashError();
      expect(e, isA<MontyError>());
      expect(e, isA<Exception>());
    });
  });

  group('MontyDisposedError', () {
    test('default message when none supplied', () {
      expect(
        const MontyDisposedError().message,
        'Interpreter disposed during execution',
      );
    });

    test('custom message overrides default', () {
      expect(
        const MontyDisposedError('disposed mid-feedRun').message,
        'disposed mid-feedRun',
      );
    });

    test('toString contains type name and message', () {
      expect(
        const MontyDisposedError().toString(),
        'MontyDisposedError: Interpreter disposed during execution',
      );
    });

    test('is a MontyError + Exception', () {
      const e = MontyDisposedError();
      expect(e, isA<MontyError>());
      expect(e, isA<Exception>());
    });
  });

  group('MontyResourceError', () {
    test('toString contains type name and message', () {
      const e = MontyResourceError('memory limit exceeded');
      expect(e.toString(), 'MontyResourceError: memory limit exceeded');
    });

    test('message is preserved', () {
      const e = MontyResourceError('oom');
      expect(e.message, 'oom');
    });

    test('is a MontyError + Exception', () {
      const e = MontyResourceError('x');
      expect(e, isA<MontyError>());
      expect(e, isA<Exception>());
    });
  });

  group('MontyError sealed-hierarchy exhaustiveness', () {
    test('switch over all subtypes compiles + dispatches correctly', () {
      // Touching every concrete subtype keeps a cross-check that no new
      // subclass slips into the hierarchy without a corresponding test
      // file. If a new subclass is added, this switch stops being
      // exhaustive and the analyser flags it.
      final errors = <MontyError>[
        const MontyScriptError('s'),
        const MontySyntaxError('y'),
        const MontyPanicError('p'),
        const MontyCrashError('c'),
        const MontyDisposedError('d'),
        const MontyResourceError('r'),
        const MontySuspensionBudgetExceeded(1),
      ];
      final names = errors.map((e) {
        return switch (e) {
          MontySyntaxError() => 'syntax',
          MontyScriptError() => 'script',
          MontyPanicError() => 'panic',
          MontyCrashError() => 'crash',
          MontyDisposedError() => 'disposed',
          MontyResourceError() => 'resource',
          MontySuspensionBudgetExceeded() => 'suspension-budget',
        };
      }).toList();
      expect(names, [
        // MontySyntaxError is more specific than MontyScriptError, so
        // the syntax-specific branch of the switch must come first.
        'script',
        'syntax',
        'panic',
        'crash',
        'disposed',
        'resource',
        'suspension-budget',
      ]);
    });
  });

  group('MontySuspensionBudgetExceeded', () {
    test('carries the budget, names how to raise it and its type', () {
      // Built at run time on purpose: a const instance never runs the
      // constructor, so its message and type name would go unexercised.
      final budget = int.parse('7');
      final e = MontySuspensionBudgetExceeded(budget);

      expect(e.budget, 7);
      expect(e.message, contains('suspension limit 7 exceeded'));
      expect(e.message, contains('MontyLimits(maxSuspensions: ...)'));
      expect(e.message, isNot(contains('unlimited')));
      expect(e.toString(), startsWith('MontySuspensionBudgetExceeded: '));
    });
  });
}
