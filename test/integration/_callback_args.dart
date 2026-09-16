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
import 'package:dart_monty_core/dart_monty_core.dart';
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

/// The Dart value of positional argument [i] of a pending call, as [T].
///
/// The `MontyValue` sibling of [callbackArg]. A `MontyPending.args` is a
/// `List<MontyValue>`, and `MontyValue.dartValue` is `Object?`, so the shape
/// this replaces carried TWO assertions for two independent nulls:
///
///     p.args.firstOrNull!.dartValue! as int
///
/// The first is "no argument at that index", the second is "that argument has
/// no Dart value" (MontyNone). They are different failures and deserve
/// different messages; `!` gave them the same one, which was none.
///
/// Same caveat as [callbackArg]: when the callback is driven by the library
/// rather than the test body, `fail` surfaces as a sandbox error, not a direct
/// test failure. Assert on the run's result.
T montyArg<T>(List<MontyValue> args, int i) {
  final value = args.elementAtOrNull(i);
  if (value == null) {
    fail('pending call needs an argument at index $i, got ${args.length}');
  }

  final dart = value.dartValue;
  if (dart == null) {
    fail('pending call argument $i has no Dart value (got $value)');
  }

  return dart as T;
}

/// The Dart value behind a [MontyValue], as [T].
///
/// Replaces `someResult.value.dartValue! as T`. `dartValue` is `Object?`
/// because MontyNone has no Dart counterpart, so the `!` was asserting "this
/// result is not None" — a real claim, made silently. Stating it gives a
/// failure that shows what the value actually was.
///
/// Distinct from [montyArg], which indexes a pending call's argument list and
/// has TWO nulls to check. This one already has the MontyValue in hand.
T dartValueOf<T>(MontyValue value) {
  final dart = value.dartValue;
  if (dart == null) {
    fail('expected a $T, but this Monty value has no Dart value: $value');
  }

  return dart as T;
}
