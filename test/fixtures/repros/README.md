# Repro fixtures

Each file in this directory is a minimal, self-documenting reproduction of an
open `dart_monty_core` issue. Repros are designed to be **side-loadable** —
the same `.py` file documents both the input and the divergence so it can be
replayed against the reference implementation (CPython / `pydantic-monty`) to
confirm what the expected behavior is.

## Layout

- `issue_<N>_<slug>.py` — the repro itself. The body is valid,
  directly-runnable Python so the reference implementation can execute it
  unmodified. Externals are defined inline as plain Python functions; the
  Dart-side test replaces those with registered `externalFunctions` callbacks.
- `test/integration/repros/issue_<N>_<slug>_<backend>_test.dart` —
  the Dart-side replay. Asserts the **expected reference behavior** wrapped
  in `xfail('#<N>', () async { ... })`, so the test passes today *because*
  the inner assertion fails (the bug is reproducing). When the bug is fixed
  the inner assertion passes, `xfail()` raises, and CI flags the test for
  promotion to a regular test.

## File format

Each repro `.py` file is structured so that:

1. The top of the file documents the issue, expected reference output, and
   actual broken output on `dart_monty_core`.
2. The body is plain, executable Python — you can `python3 issue_NN_*.py`
   and watch the reference behavior. Comments tagged `# === FEED N ===`
   delimit the call sequence; on dart_monty_core each FEED becomes a
   separate `repl.feedRun(...)` call so that the exact multi-call cadence
   that triggers the bug is preserved.
3. Stub external definitions sit at the top under
   `# === EXTERNALS (reference impl) ===`. The Dart-side test
   registers equivalent callbacks via `externalFunctions:`.

## XFAIL pattern

`package:test` has no native xfail. `test/integration/repros/_xfail.dart`
provides a helper that wraps the *correct* assertion in an inverted
expectation:

```dart
test('issue #32: ...', () async {
  await xfail('#32', () async {
    // Asserts the expected reference behavior — exactly what you'd write
    // for a regular regression test.
    expect(probe.value, isA<MontyString>()
        .having((s) => s.value, 'value', 'function'));
  });
});
```

- **Today** (bug reproduces): inner `expect` raises `TestFailure`, `xfail()`
  catches it via `throwsA(anything)`, the test passes.
- **After the fix** (bug gone): inner `expect` passes, `xfail()` sees no
  throw and itself fails — CI tells you "this XFAIL just started passing,
  promote it."

## Running a repro

**Reference (CPython / pydantic-monty) — confirms expected behavior:**

```bash
python3 test/fixtures/repros/issue_32_listcomp_global_clobber.py
```

**dart_monty_core (FFI):**

```bash
dart test test/integration/repros/issue_32_listcomp_global_clobber_ffi_test.dart \
  -p vm --run-skipped --tags=ffi --reporter=expanded
```

This is wired into the CI `test-ffi` job, so the FFI repros run on every
PR — staying green while the bugs reproduce, alerting on fix.

## Adding a new repro

1. File a GitHub issue with a minimal repro.
2. Drop a `issue_<N>_<slug>.py` in this directory documenting the divergence.
   The body must be valid, directly-runnable Python so the reference
   implementation can execute it unmodified.
3. Mirror it as a Dart test under `test/integration/repros/`. Wrap the
   *correct* (reference) assertion in `xfail('#<N>', () async { ... })`.
4. Confirm the test passes locally — meaning the inner assertion fails —
   with `dart test test/integration/repros/<file> --run-skipped --tags=ffi`.
5. The next CI run picks up the new file via the `test/integration/repros`
   directory glob in `.github/workflows/ci.yaml`'s `test-ffi` job.

## Promoting a repro to a regression guard

When the underlying bug is fixed:

1. Remove the `xfail('#<N>', () async { ... });` wrapper, so the inner
   assertion runs directly.
2. The test now becomes a regular regression guard — CI fails if the bug
   ever resurfaces.
3. (Optional) Move or delete the `.py` if it's no longer pedagogically
   useful, or keep it as a documented historical artifact.
