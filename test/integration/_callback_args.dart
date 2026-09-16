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
/// It also picked the worse failure. On a short `args` list `firstOrNull!`
/// throws "Null check operator used on a null value", which names nothing;
/// `.first` throws StateError("No element"), which names the problem but not
/// the callback. This names both, and satisfies both rules: `elementAtOrNull`
/// is the safe accessor, and `fail` returns `Never`, so no assertion is needed
/// to promote the result.
T callbackArg<T>(List<Object?> args, int i) {
  final value = args.elementAtOrNull(i);
  if (value == null) {
    fail(
      'host callback needed a $T at index $i, but got ${args.length} '
      'argument(s): $args',
    );
  }

  return value as T;
}
