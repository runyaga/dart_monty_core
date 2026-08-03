# Testing runbook

This package has **nine distinct test mechanisms**. Which one to reach for is
not discoverable from the code, and running the wrong one — or the right one
wrongly — produces a green result that verified nothing.

This file is the single source of truth for how to verify a change.
`AGENTS.md` links here rather than restating commands: restated commands are
what rot. Seven instructions in the sibling `dart_monty` repo's `AGENTS.md` were
outright false (including `cd native && cargo build` for a crate that does not
exist there) precisely because they were a second copy nobody executed.

**The gate for changing this file: run every command in it, verbatim.** That
check is what found those seven, and nothing else would have.

---

## Before you commit: run mechanism 9

```bash
bash tool/gate.sh
```

That is the answer for **every** change. It runs all seventeen steps, and a red
step means do not commit — including when it looks unrelated to what you touched.

The table below is for **fast feedback while developing**, not a substitute. It
cannot be complete: you do not know which mechanism your change affects until
something fails, which is the entire reason mechanism 9 exists. A change to
`convert.rs` "obviously" needs 2 and 3 — it also silently changes what the
browser sees, and the committed `.wasm`.

| While iterating on… | Fastest useful signal |
|---|---|
| pure Dart in `lib/` | 1 |
| anything in `native/` | **clear the dylib cache** (Traps §1), then 2 and 7 |
| `convert.rs` (value conversion) | 2, then 4 and 5 — and rebuild the WASM assets |
| the web demo or `docs/index.html` | 6 |
| a test harness or CI wiring | read Traps §3 first, then 9 |

---

## 1. Unit tests — pure Dart

```bash
dart test --exclude-tags=ffi,wasm,integration,ladder,example
```

**Verifies:** pure-Dart logic with no native library and no browser.
**Cannot verify:** anything crossing the FFI or WASM boundary — which is most of
this package. Dart line coverage from this run alone is ~32%, and the large
uncovered files are the FFI bindings, which the excluded suites do exercise.
A high number here would not mean the package works.

## 2. FFI integration — the native path

```bash
dart test $(ls test/integration/ffi_*_test.dart | grep -v with_cm) \
  --run-skipped --tags=ffi -p vm
```

**Verifies:** Dart ↔ Rust over the C ABI, using the real compiled library.
**Note the glob.** A hand-maintained list previously named 7 of the 19 files on
disk, so twelve suites ran in no CI job at all. If you add a
`ffi_*_test.dart`, the glob picks it up; do not replace it with a list.

`ffi_with_cm_test.dart` is the one deliberate exclusion — it needs
`--features test-hooks`, which is never shipped. See `tool/test_cm.sh`.

**`--run-skipped --tags=ffi` is required, and so is the file list.** Two ways to
get a meaningless green here, both verified:

```bash
dart test --tags=ffi -p vm                 # "All tests skipped." EXIT 0
dart test --tags=ffi -p vm --run-skipped   # FAILS: picks up ffi_with_cm_test
```

The first is the dangerous one: these suites are skipped by default (see
`dart_test.yaml`), so without `--run-skipped` every test is skipped, nothing
runs, and the command **exits 0**. In a shell one-liner or a CI step that only
checks the exit code, that is indistinguishable from success.

The second fails because a bare `--tags=ffi` sweep includes
`ffi_with_cm_test.dart`, which needs `--features test-hooks`. That is why the
command above passes an explicit glob with `grep -v with_cm`.

## 3. Oracle conformance + the repr differential

```bash
dart test test/integration/oracle_ffi_test.dart \
          test/integration/oracle_ffi_ext_test.dart \
  -p vm --run-skipped --tags=ffi          # conformance (circular — read on)
dart test test/integration/ffi_repr_oracle_test.dart \
  -p vm --run-skipped --tags=ffi          # the independent check
```

**Conformance is circular, and you must know that to read it.** It compares
`MontyFfi` against the `oracle` binary, which links the same Rust crate and
shares `convert.rs` with the FFI shim via `#[path = "../convert.rs"]`. Both
sides use the same encoder, so it **cannot detect a bug inside `convert.rs`** —
which is exactly how dict-ordering and `Ellipsis` collapse survived 1062
"passing" fixtures (#129). A green conformance run means FFI and the oracle
agree; it is not evidence that either is right.

**The repr differential is the independent check.** monty computes `repr()` in
Rust, upstream, before anything of ours touches the value. So it runs each
expression twice —

    monty's repr(expr)          <- upstream, independent
    render(decode(run(expr)))   <- our encoder + decoder + our renderer

— and requires the strings to match. `test/integration/_monty_repr.dart` is
deliberately hand-written and shares no code with `lib/`; if it reused the
encoder it would reintroduce the circularity it exists to break.

Proven to work: reintroducing #129 (sorting dict keys in the encoder) turns it
red on the unsorted-dict cases, while the full 1062-fixture conformance suite
stays green.

Known divergences are listed in the body and reported as **skips with an issue
link**, never asserted as correct — see `_knownDivergences` and #134 (integers
outside i64 arrive as `MontyString`).

## 4. WASM fixture corpus — dart2js *and* dart2wasm through a browser

```bash
bash tool/test_wasm.sh                          # full build + run (dart2js)
bash tool/test_wasm.sh --skip-build             # reuse current assets
bash tool/test_wasm.sh --skip-build --dart2wasm # same corpus, dart2wasm
```

**Verifies:** the 531 fixtures against the WASM engine, driven in headless
Chrome. **Not** `dart test`. It is a bespoke harness that parses
`FIXTURE_RESULT` lines.

**Run both targets.** One WASM engine, two Dart compilers:

| flag | compiles | entry page |
|---|---|---|
| *(none)* | `dart compile js` of `wasm_runner.dart` | `fixtures.html` |
| `--dart2wasm` | `dart compile wasm` of `wasm_runner_wasm.dart` | `wasm_runner_wasm.html` |

They are not interchangeable — dart2js has a single number type, dart2wasm has
real doubles — which is the same reason mechanism 1 runs `-c dart2js -c
dart2wasm`. Until 2026-08-02 the gate ran only the first, so a dart2wasm-only
corpus regression passed locally and failed in CI. Both are gate steps now
(`corpus_js`, `corpus_wasm`).

`--dart2wasm` stages its build into a temp dir. Do **not** "simplify" it to
`-o test/integration/web/wasm_runner.wasm` the way CI does: that path is a
tracked file, and so are the `.mjs` and `.wasm.map` emitted beside it, so an
in-place compile would leave every gate run with a dirty tree.

Its expectations come from `# Return=` / `# Raise=` directives authored in
upstream monty's `test_cases/`, so unlike mechanism 3 it is **not** circular.
It is still blind to dict ordering for a different reason: exactly one of the 531
fixtures returns a dict, and that one's keys are already in sorted order.

## 5. WASM package:test suites — `dart test -p chrome`

```bash
bash tool/test_wasm_unit.sh
```

**Verifies:** the `wasm_*_test.dart` suites in a real browser.

**Do not run `dart test -p chrome --tags=wasm` directly.** It fails: several
`test/integration/*.dart` files cannot compile for chrome, and the script also
stages the bridge assets the page needs. Use the script.

The script keeps an explicit file list *and* a guard that fails if any
`wasm_*_test.dart` on disk is unlisted — added after two new suites silently ran
nowhere. If you add a suite, add it to the list; the guard will tell you.

## 6. Pages render + execute — the deployed site

```bash
bash tool/check_pages.sh              # build + serve + drive
bash tool/check_pages.sh --skip-build
```

**Verifies:** the assembled GitHub Pages site loads its assets and **actually
evaluates Python**, driven over the Chrome DevTools Protocol. Nothing else covers
the deployed artefact.

**Serves without COOP/COEP on purpose.** GitHub Pages cannot set response
headers, so a gate that sent them would test a configuration that never ships.

**dart2js and dart2wasm are different targets and behave differently.** Measured
inside each page with no `Cross-Origin-*` headers:

| page | `crossOriginIsolated` | `SharedArrayBuffer` | service worker |
|---|---|---|---|
| `index_wasm.html` | `true` | available | `coi-serviceworker.js` controlling |
| `index_js.html` | `false` | **absent** | none |

Both work. `index_wasm.html` is isolated **because `coi-serviceworker.js` injects
the headers client-side** — that file is load-bearing, do not remove it. They also
diverge on numerics at the JS boundary (#128), so a value that is correct on one
target is not automatically correct on the other.

This gate drives `index_js.html`. Confirming `index_wasm.html` on the live Pages
origin is a release-cycle step and has not been done.

## 7. Rust

```bash
cd native
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check
cargo deny check
cargo llvm-cov --summary-only --ignore-filename-regex 'src/bin/'
```

CI fails under **60%** line coverage. For a crate whose job is faithful value
conversion, an aggregate floor is weak — it permits `convert.rs` coverage to fall
while unrelated code holds the number up.

## 8. DCM ratchet

```bash
bash tool/dcm_ratchet.sh            # fails on any NEW issue above baseline
bash tool/dcm_ratchet.sh --update   # deliberate rebaseline
```

`dcm analyze` has long been red (206 issues), so a clean run was never the bar
and a raw count hides new issues behind net improvements. This fails on any new
rule, per-rule increase, or newly-offending file; reducing counts is always
allowed.

**`--update` defeats the purpose if used to silence your own change.** Rebaseline
only when the new issues are genuinely intended, and say why in the commit.

## 9. The gate — run this before every commit

```bash
bash tool/prebuild.sh           # ONLY if you changed native/ or js/ (see Traps)
bash tool/gate.sh               # read-only; never rebuilds, never restores
```

Runs every step in this runbook and prints `GATE GREEN` or `GATE RED`, with
per-step logs. **A red matrix means do not commit** — including when the failing
step looks unrelated to your change. It has caught genuine defects in changes
that "obviously" could not have broken anything.

**Read the exit code and the verdict line, not the tail of the summary.** A
`FAIL` in the middle of `SUMMARY.txt` is invisible to `tail`; see trap 5.

The gate also checks its own read-only promise: it snapshots `git status
--porcelain` before step 1 and compares afterwards, and reports
`FAIL read_only_tree` if the run modified anything. It compares against the
snapshot rather than against a clean tree, so a work-in-progress tree does not
trip it.

---

## Traps

Each of these cost real time. None are guessable.

### 1. A stale native library silently tests the OLD engine

After changing anything in `native/`, `dart test` may load a cached dylib from
`.dart_tool/hooks_runner`. **Symptom:** a fix that provably works in `cargo test`
does not appear in Dart, and the test asserts the old behaviour.

```bash
rm -rf .dart_tool/hooks_runner
```

The matrix does this automatically when `native/` is newer. Manual runs do not.

### 2. `dart format --output=none` CHECKS — it does not write

Using it to "fix" formatting verifies nothing and leaves the file unformatted.
To write: `dart format --line-length=80 lib/ test/ hook/ tool/`.
To check: add `--output=none --set-exit-if-changed`.

### 3. Explicit file lists silently drop new tests

This has happened twice. Twelve `ffi_*_test.dart` files were in no CI job; two
new `wasm_*_test.dart` suites ran nowhere. A file can exist, be correctly tagged,
pass locally, and never run in CI.

Prefer a glob. If a list is unavoidable, add an unlisted-file guard —
`tool/test_wasm_unit.sh` has one.

### 4. `--compiler=kernel` is the JIT default, not AOT

A job named `test-aot` ran no AOT for months and ended in an `echo` claiming
success. Related: the package currently **cannot run from an AOT executable at
all** (#131) — it compiles, then dies on the first FFI call with
`No available native assets`.

### 5. `$?` after a pipe is the LAST command's status

`cmd | tail -3; echo $?` reports `tail`'s exit code. Several "verified" results
in this repo's history were measuring `tail`. Capture the status of the command
you care about, or use `${PIPESTATUS[0]}`.

### 6. A bare `return` in a fixture harness is a passing test that asserts nothing

646 of 1593 registered tests did exactly this (#130). If a fixture cannot be run,
either do not register it, or call `markTestSkipped(reason)` — never return
silently, which reports green.

### 7. The WASM build is not byte-reproducible

An unchanged tree produces a different `.wasm`, so **a `git diff` on the blob
tells you nothing** — it is always dirty after a rebuild and never means what it
appears to mean.

The gate used to work around that by *restoring* the committed asset after its
web steps. That reverted a deliberate rebuild — the one adding the
`monty_wire_format_version` export — the stale binary was committed, and every
web job in CI went red. A local gate cannot catch it: the FFI path compiles from
source, so only the web path loads the committed asset.

So building and gating are now separate jobs, and **the gate never writes to the
working tree**:

| | |
|---|---|
| `bash tool/prebuild.sh` | writes `lib/assets/`. You run it, you commit the result. |
| `bash tool/gate.sh` | reads `lib/assets/`. Never rebuilds, never restores. |

`tool/gate.sh` therefore runs `tool/test_wasm.sh --skip-build` (both targets), so
its web steps exercise the exact bytes you are about to commit. Forgetting `prebuild.sh` is
caught by `tool/check_asset_freshness.sh` (gate step 1), which hashes the
**sources** rather than the non-reproducible output. When you rebuild, also
regenerate `tool/wasm-provenance.json` (sizes, sha256s, and the commit `native/`
was at).

Its complement is `tool/check_wire_version.sh` (gate step 2). `WIRE_FORMAT_VERSION`
lives in `native/src/convert.rs` and the JS side reads it out of the wasm at
runtime, but `expectedWireFormatVersion` must be a Dart compile-time constant, so
it is a hand-kept copy — and the handshake would otherwise depend on someone
remembering to bump two files together. Freshness catches "sources moved, nobody
rebuilt"; this catches "the encoding was versioned on one side only".

That record lives in `tool/` — which is `.pubignore`d — and **not** in
`lib/assets/`, which ships. It used to ship: every consumer downloaded a file
explaining our internal build-reproducibility problem, of no use to them. It was
also found stale, with all three hashes wrong and nothing verifying it.

It is deliberately **not** a supply-chain attestation. An in-package hash of an
in-package artefact is a circular oracle: the record travels in the same archive
as the binary it attests, so anyone who can alter one can alter the other. Real
verification needs something out-of-band — pub.dev already publishes an archive
sha256 recorded in `pubspec.lock`, which is strictly stronger.

The useful CI check is therefore not hash-matching. It is: **fail if `native/**`
has changed since the commit recorded in the JSON**, which catches the case that
actually happened — assets going stale against the crate.

---

## Verification philosophy

Two disciplines decide whether any of the above is worth running:
**a test is not verified until you have seen it fail**, and **never assert
current behaviour just to make a test pass**. Both, with the cases that prove
them, live in
[`testing-philosophy.md`](testing-philosophy.md) — methodology, not procedure,
so it is deliberately not in this runbook.
