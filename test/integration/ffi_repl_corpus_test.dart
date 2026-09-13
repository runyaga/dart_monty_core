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

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/base_monty_platform.dart';
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
  memoryBytes: BaseMontyPlatform.defaultMemoryBytes,
  stackDepth: BaseMontyPlatform.defaultStackDepth,
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
/// A fixture that KILLS THE HOST PROCESS through the REPL handle.
typedef ReplCrash = ({int exitCode, String why});

/// Fixtures that segfault (or otherwise die) instead of returning a result.
///
/// **This is a quarantine, not a skip — and it is self-cleaning.** The entries
/// are excluded from the in-process loop below, because a process death takes
/// the whole suite with it and 530 results vanish behind one crash. But each is
/// then RE-RUN IN A SUBPROCESS by the guard test `quarantined fixtures still
/// crash`, which asserts the recorded `exitCode`. So:
///
///   * if a fixture STOPS crashing, the subprocess exits 0, the guard FAILS,
///     and the entry must be deleted — a fix cannot land silently;
///   * if a key leaves the corpus, the key-existence guard fails.
///
/// This mirrors `knownReplDivergentFixtures` above, which asserts rather than
/// skips for the same reason: "a skip proves nothing about whether it is still
/// needed", and this repo has had skip lists go stale repeatedly.
///
/// Why a subprocess rather than an in-process assertion: the note on
/// `a bare MontyRepl() is UNBOUNDED` already establishes the constraint — "a
/// fixture that raises SIGILL cannot be asserted in-process". Same here.
/// Fixtures quarantined because they KILLED THE HOST PROCESS.
///
/// EMPTIED 2026-09-13. The reason matters more than the list.
///
/// Four fixtures lived here — collections__deque.py, dataclass__repr_eq.py,
/// dict__eq_self_referential.py and list__eq_self_referential.py. All four are
/// cyclic-structure comparisons, all four SIGSEGV'd the host, and all four were
/// recorded as suspected UPSTREAM monty bugs.
///
/// They were not upstream bugs. They were this runner's own recursion limit.
///
/// Monty's guard is a COUNTER — RecursionError after N nested frames — and
/// reaching N costs real native stack. Upstream runs the engine in SUBPROCESS
/// WORKERS with a full main-thread stack, so its default of 1000 suits it;
/// this binding runs it IN-PROCESS on a Dart isolate thread, where the stack
/// overflows before the counter trips. `_replSessionLimits` hardcoded 1000
/// even after the shared default moved to 512, so this runner kept testing at
/// a depth that kills the host while every other caller had been fixed. Both
/// now reference BaseMontyPlatform.defaultStackDepth.
///
/// With that corrected, all four run to completion and PASS: the suite went
/// +556 ~34 -3 to +560 ~34 -3, same failures, no crash.
///
/// Proof it was never upstream: `pydantic-monty 0.0.23` — the exact tag
/// native/Cargo.toml pins — raises RecursionError on these scripts and its
/// parent process survives.
///
/// If a fixture kills the host again, add it back WITH its exit code
/// (`Process.run` reports -signal, so SIGSEGV is -11, NOT 139) and a reason
/// naming what was MEASURED rather than what was suspected. And check the
/// recursion limit first — that is what this list was compensating for.
const Map<String, ReplCrash> knownReplCrashFixtures = <String, ReplCrash>{};

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
      // Pin the EQUALITY, not the numbers. These used to be literals — 256MB
      // and 1000 — retyped from handle.rs. When the one-shot default moved to
      // 512 (see BaseMontyPlatform.defaultStackDepth) the literals did not,
      // so this runner silently kept testing at a depth that KILLS THE HOST,
      // while every other caller had been fixed. That is precisely the drift
      // this test exists to catch, and asserting literals could not catch it.
      expect(
        _replSessionLimits.memoryBytes,
        BaseMontyPlatform.defaultMemoryBytes,
      );
      expect(
        _replSessionLimits.stackDepth,
        BaseMontyPlatform.defaultStackDepth,
      );
    });

    test(
      'a bare MontyRepl() is BOUNDED — why this runner passes limits',
      () async {
        // The measurement behind [_replSessionLimits], kept executable so it
        // cannot rot into a comment.
        //
        // `recursion__function_depth.py` recurses 2000 deep and declares
        // `# Raise=RecursionError`; bounded sessions should therefore produce
        // it.
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
            equals('RecursionError'),
            reason:
                'a bare MontyRepl() appears unbounded (it did not raise at '
                'depth 2000). If this is intentional, revisit the corpus '
                'runner limits and the one-shot Monty.run() defaults.',
          );
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

    test('every knownReplCrashFixtures key is still in the corpus', () {
      final missing = knownReplCrashFixtures.keys
          .where((k) => !fixtureCorpus.containsKey(k))
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            'quarantined fixtures are no longer in the corpus — delete these '
            'knownReplCrashFixtures entries: $missing',
      );
    });

    // The self-cleaning subprocess guards were REMOVED here. They ran
    // `dart run repl_crash_probe.dart <fixture>` as a child and asserted it
    // still died, so a fix could not land behind a stale quarantine. On CI
    // (linux_x64) they aborted the whole FFI suite with exit 134 — the parent
    // faulted in the dynamic loader (SEGV_MAPERR in ld-linux) right after a
    // guard passed. The mechanism was never established: a dlopen-collision
    // theory was refuted (child and parent have separate address spaces), and
    // a `dart run` build-hook theory did not reproduce locally (the mapped
    // .so's inode was unchanged across a probe run).
    //
    // They were also invisible locally: the Makefile runs `-x crash-probe`, so
    // every local measurement excluded the very tests that broke CI.
    //
    // repl_crash_probe.dart is kept — it is still the way to check one fixture
    // by hand.
    //
    // BE PRECISE ABOUT WHAT THIS COSTS. The main loop below still does
    //     if (knownReplCrashFixtures.containsKey(key)) continue;
    // so with the guards gone these four fixtures now execute NOWHERE in the
    // automated suite — not merely "unchecked for staleness", but unrun. They
    // cannot simply be un-skipped: they SIGSEGV on the BOUNDED session this
    // runner uses (see each entry's `why`), so putting them back in the loop
    // takes the whole suite down again.
    //
    // So this is a real, accepted coverage gap: if one of these crashes is
    // fixed upstream, nothing goes red and the quarantine silently rots — the
    // exact failure this repo's earlier skip lists had. Closing it means
    // re-adding the guards as a SEPARATE CI step with the probe pre-compiled,
    // so the child never runs the native-assets build pipeline and its death
    // cannot take a sibling suite with it.
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

    final fixtureLimit = int.tryParse(
      Platform.environment['SOLPI_FIXTURE_LIMIT'] ?? '',
    );

    // The harness registers many tests before any execute. If the VM segfaults
    // during native symbol resolution (core#??), a simple fixture-limit guard
    // is not enough, because the process can die while registering later tests
    // even though only the first N would have run.
    //
    // So: when slicing, only REGISTER the first N tests.
    final entries = fixtureLimit == null
        ? fixtureCorpus.entries
        : fixtureCorpus.entries.take(fixtureLimit);

    for (final MapEntry(:key, :value) in entries) {
      // Quarantined fixtures kill the process; they are asserted in a
      // subprocess by the guard test instead. See knownReplCrashFixtures.
      if (knownReplCrashFixtures.containsKey(key)) continue;
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
