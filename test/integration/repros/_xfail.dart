// XFAIL helper — pytest-style "expected to fail" for repro tests.
//
// Dart's `package:test` has no native xfail. This helper wraps a body that
// asserts the *expected reference behavior* and inverts the test outcome:
// the test passes today *because* the inner assertion fails (the bug is
// reproducing), and fails the day the inner assertion starts passing
// (the bug has been fixed — promote this to a regular test).
//
// Usage:
//
//   test('issue #32: sync_fn survives two list-comp feeds', () async {
//     await xfail('#32', () async {
//       final repl = MontyRepl();
//       // ... feeds ...
//       expect(probe.value, isA<MontyString>()
//           .having((s) => s.value, 'value', 'function'));
//     });
//   });
//
// When the bug is fixed:
//   1. Replace `await xfail('#32', () async { ... });` with the body inline.
//   2. Add the test file to ci.yaml's matching backend job invocation.

import 'package:test/test.dart';

/// Asserts that [body] currently fails (any `TestFailure` from inner
/// `expect`s, or any thrown exception during execution). When the underlying
/// bug is fixed and [body] starts completing without failure, this helper
/// raises a `TestFailure`, signalling that the test should be promoted to
/// a regular test.
///
/// [reason] should reference the tracking issue, e.g. `'#32'`.
Future<void> xfail(String reason, Future<void> Function() body) async {
  await expectLater(
    body,
    throwsA(anything),
    reason:
        'XFAIL $reason: expected to fail until the underlying bug is fixed. '
        'When this assertion fails ("expected throw, none thrown"), the bug '
        'has been fixed — remove the xfail() wrapper and add the test file '
        'to .github/workflows/ci.yaml.',
  );
}
