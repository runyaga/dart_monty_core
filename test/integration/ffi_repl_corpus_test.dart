// Integration tests: the conformance corpus driven through the REPL handle.
//
// WHAT THIS IS, STATED PLAINLY SO NOBODY OVERREADS IT
// ---------------------------------------------------
// This is a PLUMBING SMOKE TEST for `native/src/repl_handle.rs`. It is NOT
// coverage of the REPL, and a green run here does not mean "the REPL is tested
// by 531 fixtures".
//
// Every fixture in the corpus is a self-contained script. Feeding one to a
// FRESH `MontyRepl` exercises `feedRun`/`feedStart`'s plumbing — the second
// implementation of session creation, the suspension state machine, and the
// second result-envelope builder (`build_repl_result_json`) — and exercises
// NOTHING about statefulness, which is the REPL's entire reason to exist.
// State persisting across feeds is covered by `test/integration/ffi_repl_*`
// and by the unit tests, not here.
//
// WHY IT EXISTS
// -------------
// The 531-fixture corpus only ever drove the ONE-SHOT handle
// (`native/src/handle.rs`), via `oracle_ffi_test.dart` and `wasm_runner.dart`.
// The REPL handle is a genuinely separate implementation — a separate state
// machine, a separate result envelope, a separate limits path — and the two
// diverging has already shipped a defect: FB-1 / core#124, where
// `Monty.run(limits:)` silently ignored limits because it routes through
// `MontyRepl`, which used a non-enforcing tracker while one-shot used the
// enforcing one. Nothing was watching that seam.
//
// WHAT IT ASSERTS AGAINST
// -----------------------
// The fixture's own static `# Return=` / `# Raise=` directives, exactly as
// `oracle_ffi_ext_test.dart` does — NOT the one-shot handle's output. A
// differential runner (run both handles, assert equality) was considered and
// rejected: the two handles are intentionally non-identical (`usage` is
// hard-zero on the REPL, errors carry no filename/line/column), so it would
// need a normalisation layer, and a normalisation layer is the thing you end
// up testing.
//
// SELECTION IS DELIBERATELY IDENTICAL TO THE ONE-SHOT HARNESSES
// -------------------------------------------------------------
// `# call-external` fixtures go down the shared dispatch loop, the same one
// `oracle_ffi_ext_test.dart` uses; everything else goes through
// `platform.run()` with `parseFixture`'s defaults, the same as
// `oracle_ffi_test.dart`. That is what makes a difference here attributable to
// the HANDLE rather than to the harness.
//
// FFI ONLY, ON PURPOSE
// --------------------
// The WASM half of this cannot exist yet: `WasmReplBindings.create` throws on
// any `limitsJson` (core#140), so a REPL session on the web cannot carry the
// limits this runner depends on. Recorded rather than papered over — see
// `lib/src/repl/wasm_repl_bindings.dart`.
//
// Run: dart test test/integration/ffi_repl_corpus_test.dart -p vm \
//        --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Session limits
// ---------------------------------------------------------------------------

/// The limits a bare `MontyRepl()` does NOT get, and one-shot always does.
///
/// `native/src/handle.rs`'s `default_limits()` bounds memory at 256 MB and
/// recursion at 1000 for every one-shot run, and Dart never sends null
/// (`encodeLimitsJson` substitutes `BaseMontyPlatform.default*` when `limits`
/// is null). A bare `MontyRepl()` sends no limits JSON at all, so
/// `monty_repl_create` falls back to `ResourceLimits::default()` — UNBOUNDED.
///
/// That gap is not cosmetic for this corpus: `recursion__function_depth.py`
/// asserts a `RecursionError`, which an unbounded session cannot produce. It
/// would recurse until the process died. Passing these explicitly puts the
/// REPL session on the one-shot handle's footing so a difference in RESULT is
/// attributable to the handle rather than to a difference in configuration.
///
/// The numbers are pinned to the one-shot constants below rather than
/// retyped — see `repl session limits match the one-shot defaults`.
const _replSessionLimits = MontyLimits(
  memoryBytes: 256 * 1024 * 1024,
  stackDepth: 1000,
);

// ---------------------------------------------------------------------------
// Known divergences — EXACT MATCH, and self-cleaning
// ---------------------------------------------------------------------------

/// A fixture that the REPL handle gets WRONG relative to its own directives,
/// where the one-shot handle gets it right.
typedef ReplDivergence = ({String excType, String why});

/// Fixtures whose REPL result differs from the fixture's declared expectation.
///
/// **These entries are not skips.** Each listed fixture is RUN, and the test
/// asserts it produces exactly the recorded `excType`. That makes the list
/// self-cleaning in both directions:
///
///   * a fixture that starts PASSING no longer raises, so the assertion fails
///     and the entry must be deleted;
///   * a key that no longer exists in the corpus fails the guard test below.
///
/// This repo has had skip lists go stale repeatedly — two were found stale in
/// a single day — which is why the mechanism is an assertion rather than a
/// `markTestSkipped`. A skip proves nothing about whether it is still needed.
///
/// The recorded field is the exception TYPE because that is what every
/// divergence found so far produces. A value-only divergence (right type,
/// wrong value) would need a new field; add one rather than widening this to
/// mean "something differs".
const Map<String, ReplDivergence> knownReplDivergentFixtures = {
  'ext_call__name_lookup.py': (
    excType: 'NameError',
    why:
        'The REPL handle AUTO-RESOLVES every NameLookup and never asks the '
        'host (native/src/repl_handle.rs, the ReplProgress::NameLookup arm): '
        'a name in ext_fn_names becomes a Function, everything else becomes '
        'Undefined. So host-injected constants (CONST_INT and friends in '
        'monty_conformance/lib/src/fixture_externals.dart) cannot reach the '
        'sandbox and the fixture dies on its first assert. Measured on FFI '
        '2026-08-02: the one-shot handle SKIPS this fixture — it surfaces '
        'MontyNameLookup, the host offers a value, and FFI answers '
        'UnimplementedError (FB-5), which the shared loop records as a '
        'capability gap. The REPL is strictly worse: it cannot report the gap '
        'because it never asks. Engine work, deliberately NOT attempted here.',
  ),
  'with__class_external.py': (
    excType: 'NameError',
    why:
        'Same cause as ext_call__name_lookup.py: its final section resolves '
        'CONST_INT / CONST_STR inside __enter__ / __exit__. Also SKIPPED by '
        'the one-shot FFI harness, for the same FB-5 reason.',
  ),
};

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

/// What one fixture produced on the REPL handle.
typedef _ReplOutcome = ({
  String? excType,
  MontyValue? value,
  MontyException? exception,
  String? skipReason,
});

/// Runs [source] on a FRESH REPL session and reports the outcome.
///
/// Fresh per fixture on purpose: sharing one session would let fixture N's
/// globals decide fixture N+1's result, and the corpus is not written to be
/// run in sequence.
Future<_ReplOutcome> _runOnRepl(
  String key,
  String source, {
  required bool callExternal,
}) async {
  final repl = MontyRepl(scriptName: key, limits: _replSessionLimits);
  final platform = ReplPlatform(repl: repl);
  try {
    if (callExternal) {
      // No `scriptName:` argument: it is session-scoped on a REPL and
      // ReplPlatform now rejects it rather than dropping it. It was passed to
      // the MontyRepl constructor above instead.
      final o = await runCallExternalFixture(platform, source);

      return (
        excType: o.excType,
        value: o.value,
        exception: o.exception,
        skipReason: o.skipped
            ? (o.skipReason ?? 'dispatch harness could not run this fixture')
            : null,
      );
    }

    try {
      final r = await platform.run(source);

      return (
        excType: r.error?.excType,
        value: r.value,
        exception: r.error,
        skipReason: null,
      );
      // `feedRun` returns Python errors in `result.error` rather than throwing,
      // unlike one-shot — but binding-level failures still throw, so both arms
      // are live.
    } on MontyScriptError catch (e) {
      return (
        excType: e.excType,
        value: null,
        exception: e.exception,
        skipReason: null,
      );
    } on MontyResourceError {
      return (
        excType: 'MemoryLimitExceeded',
        value: null,
        exception: null,
        skipReason: null,
      );
    }
  } finally {
    await repl.dispose();
  }
}

void main() {
  group('ffi_repl_corpus', () {
    test('repl session limits match the one-shot defaults', () {
      // The point of this runner is that a difference is attributable to the
      // HANDLE. If these drift from `handle.rs`'s `default_limits()` the
      // comparison is against a different configuration and means less than it
      // appears to.
      expect(_replSessionLimits.memoryBytes, 256 * 1024 * 1024);
      expect(_replSessionLimits.stackDepth, 1000);
    });

    test(
      'a bare MontyRepl() is UNBOUNDED — why this runner passes limits',
      () async {
        // The measurement behind [_replSessionLimits], kept executable so it
        // cannot rot into a comment. `recursion__function_depth.py` recurses
        // 2000 deep and declares `# Raise=RecursionError`; the one-shot handle
        // always produces it, a bare REPL session silently returns 2000.
        //
        // This is the FB-1 / core#124 shape, still live on this branch: a
        // resource control that reports success. If a future change gives
        // `MontyRepl()` the one-shot defaults, THIS TEST GOES RED — that is the
        // signal to delete it and drop `_replSessionLimits`.
        //
        // THE BLAST RADIUS IS PROCESS DEATH, NOT A WRONG ANSWER. Measured
        // 2026-08-03 by feeding all 531 fixtures to a bare `MontyRepl()` in a
        // subprocess and resuming past each death — 526 survived and FIVE
        // killed the host process outright:
        //
        //     dict__eq_self_referential.py     exit 132 (SIGILL)
        //     list__eq_self_referential.py     exit 132 (SIGILL)
        //     recursion__deep_hash.py          exit 132 (SIGILL)
        //     recursion__deep_isinstance.py    exit 132 (SIGILL)
        //     traceback__recursion_error.py    exit 137 (SIGKILL, memory)
        //
        // All five pass on the BOUNDED session this runner uses, and all five
        // pass one-shot, which is always bounded. So the unbounded default is
        // the whole of the defect, and `Monty(code).run()` — the documented
        // one-line API — is the way a consumer reaches it: it builds
        // `MontyRepl(limits: null)` (lib/src/monty.dart). Untrusted Python can
        // therefore terminate the host, and FFI has no crash isolation to
        // absorb it.
        //
        // Not enumerated as test cases here on purpose: a fixture that raises
        // SIGILL cannot be asserted in-process — it would take the suite with
        // it, and 530 results would vanish behind one crash. The CAUSE is what
        // this test pins, and fixing the cause fixes all five at once.
        const src =
            'def recurse(n):\n'
            '    if n == 0:\n'
            '        return 0\n'
            '    return recurse(n - 1) + 1\n'
            '\n'
            'recurse(2000)\n';

        final bare = MontyRepl();
        try {
          final r = await bare.feedRun(src);
          expect(
            r.error?.excType,
            isNull,
            reason:
                'a bare MontyRepl() is now bounded — delete this test and '
                '_replSessionLimits, the divergence is fixed',
          );
          expect(r.value, equals(const MontyInt(2000)));
        } finally {
          await bare.dispose();
        }

        final bounded = MontyRepl(limits: _replSessionLimits);
        try {
          final r = await bounded.feedRun(src);
          expect(r.error?.excType, equals('RecursionError'));
        } finally {
          await bounded.dispose();
        }
      },
    );

    test('every knownReplDivergentFixtures key is still in the corpus', () {
      // A dead row is a row that checks nothing. Renaming or dropping a
      // fixture upstream must break this, not silently shrink the list.
      final missing = knownReplDivergentFixtures.keys
          .where((k) => !fixtureCorpus.containsKey(k))
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            'these divergence entries name fixtures that no longer exist; '
            'delete them: $missing',
      );
    });

    test('divergence entries do not overlap the all-backend broken list', () {
      // A fixture in both lists is skipped for one reason and asserted for
      // another, and the two would fight. `knownBrokenExtFixtures` means "we
      // are wrong everywhere"; this list means "the REPL is wrong and one-shot
      // is not".
      final overlap = knownReplDivergentFixtures.keys
          .where(knownBrokenExtFixtures.containsKey)
          .toList();
      expect(overlap, isEmpty, reason: 'listed twice: $overlap');
    });

    test('the corpus still contains call-external fixtures', () {
      // Guards the per-fixture branch below: if a directive rename emptied the
      // call-external set, every suspension path in repl_handle.rs would stop
      // being exercised here and the suite would still be green.
      expect(fixtureCorpus.values.where(fixtureIsCallExternal), isNotEmpty);
    });

    test('most of the corpus is actually ASSERTED, not skipped', () {
      // core#130's failure shape: a harness registered 531 tests, 475 of them
      // hit a bare `return`, and it advertised 531 green on 51 real
      // assertions. Every skip below is reported, but a reader sees the
      // headline number — so pin the floor statically.
      //
      // Measured 2026-08-02: 504 assert, 32 skip. The floor is deliberately
      // slack; it is a tripwire for "a directive rename silently gutted the
      // suite", not a golden number to be re-blessed on every corpus bump.
      final asserted = fixtureCorpus.entries
          .where(
            (e) =>
                parseFixture(
                  e.value,
                  skipCallExternal: !fixtureIsCallExternal(e.value),
                ) !=
                null,
          )
          .length;
      expect(
        asserted,
        greaterThan(450),
        reason:
            'only $asserted of ${fixtureCorpus.length} fixtures carry an '
            'assertable directive on this path — something gutted the suite',
      );
    });

    for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
      test(key, () async {
        final callExternal = fixtureIsCallExternal(value);

        // Identical selection to the one-shot harnesses: ext fixtures opt in
        // (oracle_ffi_ext_test.dart), everything else takes the defaults
        // (oracle_ffi_test.dart), which skip run-async and mount-fs.
        final expectation = parseFixture(
          value,
          skipCallExternal: !callExternal,
        );
        if (expectation == null) {
          markTestSkipped('no Return=/Raise= directive to assert against');

          return;
        }

        final broken = knownBrokenExtFixtures[key];
        if (broken != null) {
          markTestSkipped(broken);

          return;
        }

        if (setRecursionLimitFixtures.contains(key)) {
          // Not a REPL divergence — a property of THIS harness. These call
          // `sys.setrecursionlimit`, which the stock build does not have, so
          // they raise AttributeError on both handles. `oracle_ffi_test.dart`
          // reports them green because it compares against an oracle built the
          // same way and both sides agree; asserting against the static
          // directive instead makes the gap visible. Run them with
          // `--features test-hooks`.
          markTestSkipped(
            'needs the test-hooks cargo feature for sys.setrecursionlimit',
          );

          return;
        }

        final outcome = await _runOnRepl(
          key,
          value,
          callExternal: callExternal,
        );
        if (outcome.skipReason != null) {
          markTestSkipped(outcome.skipReason!);

          return;
        }

        final divergence = knownReplDivergentFixtures[key];
        if (divergence != null) {
          expect(
            outcome.excType,
            equals(divergence.excType),
            reason:
                'RECORDED DIVERGENCE no longer reproduces for $key. Either it '
                'was fixed — delete the entry from '
                'knownReplDivergentFixtures — or it changed shape, in which '
                'case update it. Recorded reason: ${divergence.why}',
          );

          return;
        }

        switch (expectation) {
          case ExpectNoException():
            expect(
              outcome.excType,
              isNull,
              reason: describeFixtureFailure(key, outcome.exception),
            );
          case ExpectReturn(value: final expected):
            expect(
              outcome.excType,
              isNull,
              reason: describeFixtureFailure(key, outcome.exception),
            );
            expect(
              outcome.value,
              equals(MontyValue.fromDart(expected)),
              reason: 'value mismatch for $key',
            );
          case ExpectRaise(:final excType):
            expect(
              outcome.excType,
              equals(excType),
              reason: 'excType mismatch for $key',
            );
        }
      });
    }
  });
}
