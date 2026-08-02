// Shared test body for ffi_oscall_decline_test.dart and
// wasm_oscall_decline_test.dart.
//
// Covers what happens when an `osHandler` DECLINES a call rather than serving
// or failing it. Upstream gives declining a first-class meaning: the sandbox
// raises the call's own default via `OsFunctionCall::on_no_handler()`
// (monty-types/src/os.rs:260) — `PermissionError` naming the path for a
// filesystem op, `RuntimeError: '<name>' is not supported in this environment`
// for anything else.
//
// In the pool topology that travels as `ResumeValue::NotHandled` and the CHILD
// computes the default (monty-proto/src/worker.rs:503 —
// `ExtFunctionResult::Error(call.function_call.on_no_handler())`). We embed the
// interpreter in-process, and `ExtFunctionResult` has no `NotHandled` variant
// (monty-types/src/results.rs:26-39), so the host computes the same default and
// resumes with it. Same semantics, one layer up.
//
// This exists because `OsCallNotHandledException` used to route to
// `resumeNotFound`, which is the EXTERNAL-FUNCTION verb: declining
// `Path.read_text` produced `NameError: name 'Path.read_text' is not defined`,
// turning a sandbox refusal into a missing-function message.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// Runs [code] against a handler that declines every call.
Future<MontyResult> _declineAll(String code) => Monty(code).run(
  osHandler: (op, args, kwargs) async => throw OsCallNotHandledException(op),
);

void runOsCallDeclineTests() {
  group('declining an OS call', () {
    test(
      'declined filesystem op raises PermissionError, not NameError',
      () async {
        final r = await _declineAll(
          'from pathlib import Path\n'
          'try:\n'
          "    Path('/etc/passwd').read_text()\n"
          "    out = 'NO RAISE'\n"
          'except Exception as e:\n'
          "    out = type(e).__name__ + ': ' + str(e)\n"
          'out',
        );

        expect(r.error, isNull);
        // Upstream wording: `Permission denied: '<path>'`, no Errno prefix
        // (monty-fs/tests/fs.rs:2390 asserts exactly that).
        expect(
          r.value.dartValue,
          "PermissionError: Permission denied: '/etc/passwd'",
        );
      },
    );

    test(
      'declined non-filesystem op raises RuntimeError naming the op',
      () async {
        final r = await _declineAll(
          'import datetime\n'
          'try:\n'
          '    datetime.datetime.now()\n'
          "    out = 'NO RAISE'\n"
          'except Exception as e:\n'
          "    out = type(e).__name__ + ': ' + str(e)\n"
          'out',
        );

        expect(r.error, isNull);
        expect(
          r.value.dartValue,
          "RuntimeError: 'datetime.now' is not supported in this environment",
        );
      },
    );

    test('declining never reports the op as an undefined NAME', () async {
      final r = await _declineAll(
        'from pathlib import Path\n'
        'try:\n'
        "    Path('/x/y.txt').read_text()\n"
        "    out = 'NO RAISE'\n"
        'except Exception as e:\n'
        '    out = type(e).__name__\n'
        'out',
      );

      expect(r.error, isNull);
      // The regression this file exists for.
      expect(r.value.dartValue, isNot('NameError'));
    });
  });
}
