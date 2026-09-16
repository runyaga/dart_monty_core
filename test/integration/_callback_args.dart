// Shared accessor for host-callback positional arguments.
//
// ONE copy, imported by every `*_test_body.dart` that implements a
// MontyCallback. The alternative — a private helper per file — is the shape
// that has broken conformance in this repo twice already (see the header of
// packages/monty_conformance/lib/src/fixture_externals.dart): a copy does not
// stay a copy.
//
// It cannot live in package:monty_conformance, which is deliberately
// dependency-free so it compiles for the browser — `fail()` is package:test.
import 'package:test/test.dart';

/// Positional argument [i] of a host callback's `args`, as [T].
///
/// NOT `args.firstOrNull! as T`, and NOT `args.first as T`.
///
/// Those two are the only forms this codebase used, and they trade one lint
/// for the other: `firstOrNull!` satisfies avoid-unsafe-collection-methods and
/// trips avoid-non-null-assertion; `.first` does the reverse. 43 of the 70
/// suppressed `!` in test/ were the former, because that rule was excluded for
/// test/** and the collection rule was not — so the config, not a judgement,
/// picked the form.
///
/// It also picked the worse failure message. Measured, same short-args case:
///
///     OLD -> RuntimeError: Null check operator used on a null value
///     NEW -> RuntimeError: host callback needs an int at index 1,
///                          got 1 argument(s): [41]
///
/// WHAT `fail` DOES AND DOES NOT DO HERE. `fail` returns `Never`, which is why
/// `value` promotes and no `!` is needed — that part is why both rules stay
/// quiet. But when the callback is invoked by the LIBRARY rather than by the
/// test body, the TestFailure it throws does NOT fail the test directly: the
/// dispatch loop catches it like any other callback error and delivers it to
/// the sandbox as a Python RuntimeError. Measured 2026-09-16 — a test whose
/// callback failed this way still reported "All tests passed".
///
/// That is NOT a regression from this helper: `args.firstOrNull! as T` was
/// swallowed identically, and the probe above shows both arriving as
/// RuntimeError. The difference is only the message, and the message is the
/// whole value. Do not read `fail` here as a guarantee that a wrong arg count
/// turns the suite red — assert on the run's result for that.
T callbackArg<T>(List<Object?> args, int i) {
  final value = args.elementAtOrNull(i);
  if (value == null) {
    fail(
      'host callback needs a value of type $T at index $i, '
      'got ${args.length} argument(s): $args',
    );
  }

  return value as T;
}
