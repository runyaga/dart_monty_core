// Shared test body for ffi_monty_019_semantics_test.dart (and its WASM mirror).
//
// Pins the monty v0.0.19 behaviour changes that are SILENT — they alter runtime
// semantics without any compile error, so nothing else in the suite would catch a
// regression or an accidental revert.
//
// Every expectation here was verified to differ under v0.0.18 by running the same
// snippet against the preserved 0.18 reference oracle
// (~/dev/plans/monty-0.19-upgrade/reference-018/). A test that passes on both
// versions would not be evidence of anything, which is the standard P2's gate
// asks for: "a test that would fail under 0.18 semantics".

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runMonty019SemanticsTests() {
  group('monty 0.19 semantics', () {
    // -- upstream #558 : print collection is capped -------------------------
    //
    // 0.18: collected 20,000,200 bytes with no error.
    // 0.19: MemoryError once the buffer would exceed the cap.
    //
    // Note this is a REJECTED WRITE, not truncation: check_print_collect_limit
    // (monty-types/src/io.rs:150-171) runs before the append and returns
    // Err(MontyException(MemoryError)). No output is silently lost.
    test(
      'print output beyond the cap raises a catchable MemoryError',
      () async {
        final r = await Monty(
          's = "x" * 100000\n'
          'for i in range(200):\n'
          '    print(s)\n',
        ).run();

        expect(
          r.error,
          isNotNull,
          reason:
              'print collection must be capped; unbounded collection lets '
              'sandboxed code exhaust host memory (upstream #558)',
        );
        expect(r.error!.excType, 'MemoryError');
      },
    );

    test('the print cap is catchable from Python, not a hard abort', () async {
      final r = await Monty(
        'caught = False\n'
        'try:\n'
        '    s = "x" * 100000\n'
        '    for i in range(200):\n'
        '        print(s)\n'
        'except MemoryError:\n'
        '    caught = True\n'
        'caught\n',
      ).run();

      expect(r.error, isNull, reason: 'MemoryError must be catchable');
      expect(r.value.dartValue, true);
    });

    test('output below the cap is unaffected', () async {
      final r = await Monty('print("hello")\n1\n').run();
      expect(r.error, isNull);
      expect(r.printOutput, 'hello\n');
    });

    // -- upstream #612 : action-less open() modes are rejected ---------------
    //
    // 0.18: 'b' alone was accepted at parse time and only failed later, when the
    //       Open OS-call was dispatched (NotImplementedError with no handler).
    // 0.19: rejected up front with ValueError, before any dispatch.
    //
    // The 0.18-vs-0.19 difference is WHERE it fails, so this test asserts the
    // exception type — under 0.18 semantics it would be NotImplementedError.
    test('open() with an action-less mode raises ValueError', () async {
      final r = await Monty('open("/m/a.txt", "b")\n').run();

      expect(r.error, isNotNull);
      expect(
        r.error!.excType,
        'ValueError',
        reason:
            'mode must contain exactly one of r/w/a/x; under 0.18 this '
            'reached the Open OS-call and failed as NotImplementedError',
      );
    });

    test('open() with a valid mode still reaches the OS-call layer', () async {
      // No handler is registered, so a correctly-formed open() must get past
      // validation and fail at dispatch. Guards against over-tightening the
      // mode check into rejecting valid modes.
      final r = await Monty('open("/m/a.txt", "r")\n').run();

      expect(r.error, isNotNull);
      expect(r.error!.excType, isNot('ValueError'));
    });

    // -- upstream #576 : the Open OS-call was renamed to 'open' --------------
    //
    // The only op renamed in 0.19, and the only break in this release that fails
    // SILENTLY in consumer code: a handler matching 'Open' simply stops matching
    // and falls through. See BREAKING-LEDGER.md row 4.
    test('the open() OS-call is dispatched as op "open"', () async {
      final seen = <String>[];
      final r = await Monty('open("/m/a.txt", "r")\n').run(
        osHandler: (op, args, kwargs) async {
          seen.add(op);
          throw OsCallException('stop', pythonExceptionType: 'OSError');
        },
      );

      expect(r.error, isNotNull);
      expect(
        seen,
        contains('open'),
        reason:
            'renamed from "Open" in 0.19; a consumer handler keyed on the '
            'old name silently stops matching',
      );
      expect(seen, isNot(contains('Open')));
    });
  });
}
