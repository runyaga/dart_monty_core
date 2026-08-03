# REPL statefulness coverage — plan

Status: PROPOSED. Nothing here is implemented. Written 2026-08-02 against
`feat/vfs-019` (`0d9d486`), with the REPL corpus runner read from
`feat/repl-corpus-runner` (`7816822`, `d0a9e1f`).

**Where this lives and why.** In `docs/contributor/`, not `~/dev/plans/`, for
two reasons: `docs/contributor/vfs-phases.md` is already a phased plan tracked
in-repo, so the precedent exists; and this document's central argument is a
reading of `docs/contributor/testing-philosophy.md`, which a reader must be
able to follow from the same tree. A planning directory outside the repo would
separate the argument from the doctrine it rests on.

---

## 0. The gap, stated exactly

`test/integration/ffi_repl_corpus_test.dart` (on `feat/repl-corpus-runner`)
drives all 531 upstream fixtures through a **fresh `MontyRepl` each**. Its own
header says what that is worth, and it is right:

> Every fixture in the corpus is a self-contained script. Feeding one to a
> FRESH `MontyRepl` exercises `feedRun`/`feedStart`'s plumbing … and exercises
> NOTHING about statefulness, which is the REPL's entire reason to exist.

A REPL exists to carry state across feeds. Nothing in this repo systematically
tests that. This plan says what to build instead, and what not to.

### The defect that proves the gap is not theoretical

**Measured on this branch, 2026-08-02, FFI and both web compilers.**

`MontyRepl.restore(bytes)` onto a REPL that has **never been fed** silently
discards the restored state:

```
PROBE fresh mul  => value=MontyNone() err=NameError:name 'total' is not defined
PROBE fresh read => value=MontyNone() err=NameError:name 'total' is not defined
PROBE fed-first read => value=MontyInt(2) err=null      # same bytes, works
```

Mechanism, and it is entirely in shared Dart code:

- `_ensureCreated()` is called by `feedRun` (`lib/src/repl/monty_repl.dart:186`),
  `feedStart` (`:285`) and `detectContinuation` (`:386`).
- It is **not** called by `snapshot()` (`:405`–`:410`) or `restore()`
  (`:417`–`:422`), and `restore()` never sets `_created`
  (the flag is set only at `:657`, inside `_ensureCreated`).
- So on a fresh handle, `restore()` writes into a session that the next
  `feedRun` then replaces via `_ensureCreated()` → `_bindings.create(...)`.

Upstream cannot have this bug: its equivalent is a **static constructor**,
`MontyRepl::load(&bytes)`
(`crates/monty/tests/repl.rs:209`), not an instance method on a
lazily-created handle. Our API turned a constructor into a mutator and
introduced the failure mode.

It survived because `test/integration/_repl_snapshot_lifecycle_test_body.dart`
tests only the `StateError` guards and `expect(bytes, isNotEmpty)` — it never
round-trips a **value**. Upstream does exactly that at
`crates/monty/tests/repl.rs:204` (`repl_dump_load_survives_between_snippets`,
asserting `42`) and `:217` (heap aliasing).

This is a Severity-4 shape — silent data loss on the documented
snapshot/restore path — and category R1 below exists to catch it. **The fix is
not in scope here**; this document plans coverage.

---

## 1. What upstream actually does

Four surfaces read in full.

| file | lines | what it is |
|---|---|---|
| `crates/monty/src/repl.rs` | 1187 | implementation |
| `crates/monty/tests/repl.rs` | 865 | Rust integration tests, 51 `#[test]` |
| `crates/monty-python/tests/test_repl.py` | 417 | host tests, 48 `def test_` |
| `crates/monty-js/__test__/repl.spec.ts` | 61 | JS bindings, 3 tests |

### 1.1 There is no fixture-driven REPL corpus upstream

`grep -n "test_cases\|fixture\|Fixture"` over `crates/monty/tests/repl.rs`,
`crates/monty-python/tests/test_repl.py` and
`crates/monty-js/__test__/repl.spec.ts` returns **0 hits**. The `test_cases/`
corpus is one-shot only. Every piece of REPL statefulness coverage upstream is
a hand-written multi-step scenario.

The single table-driven construct in any of the three is
`@pytest.mark.parametrize` at `crates/monty-python/tests/test_repl.py:136`,
covering single-feed **return types** (`'42'→42`, `'3.14'→3.14`, …). It feeds
once. It is not a stateful scenario.

**So our REPL corpus runner has no upstream analogue, and copying the
fixture-corpus shape onto the REPL is not something upstream would recognise.**

### 1.2 What upstream asserts about statefulness

Categories, with the line each starts at in `crates/monty/tests/repl.rs`
(`R`) or `crates/monty-python/tests/test_repl.py` (`P`):

| category | where |
|---|---|
| No replay — only the new snippet executes | R:14, R:126 |
| Variables / definitions persist | R:39, P:49, P:54, P:61 |
| Function redefinition wins | R:49, R:61 |
| Late binding over builtins (`def sum` shadows `sum`) | R:76, R:96 |
| Heap mutation persists and is not replayed | R:126, P:93, P:100 |
| Closures persist across feeds | P:78 |
| Runtime error keeps partial state | R:113, R:350, P:170, P:209 |
| Syntax error preserves session | P:163 |
| Error inside an external preserves session | R:372, P:339 |
| Traceback filenames increment `<python-input-N>` | R:159 |
| Cross-snippet traceback resolves against the **defining** snippet | R:173, P:219 |
| `dump`/`load` round-trip carries state | R:204 |
| `dump`/`load` preserves heap **aliasing** | R:217 |
| Paused-progress dump/load round-trip | R:291, R:311 |
| External fn first referenced in a **later** feed | R:432 |
| Externals re-queried per feed | P:306, P:320 |
| Print accumulates across feeds | P:269 |
| Inputs, incl. overriding an existing variable | P:374–P:405 |
| Continuation-mode detection | R:143 |
| Sessions are isolated from each other | P:410 |
| Comprehension slots restored before next turn / after error | R:255, R:276 |

### 1.3 What upstream deliberately does NOT test

- **Limits across feeds.** `P:279`/`P:283` set limits at *checkout* level and
  run a single feed. Nothing asserts a budget spanning feeds.
- **Snapshot/restore in the Python host.** `dump`/`load` appear only in the
  Rust tests (`R:204`, `R:217`) and, as opacity-only, in JS
  (`crates/monty-js/__test__/repl.spec.ts:47`). `test_repl.py` has none.
- **Concurrency between sessions.** Isolation is tested (`P:410`); parallel use
  is not.
- **The web/browser REPL.** `repl.spec.ts:24` and `:48` call `skipIfBrowser`,
  so two of its three tests do not run in a browser at all.

### 1.4 Where our API makes upstream untranslatable

**29 of the 51 `#[test]`s in `crates/monty/tests/repl.rs` — the section
starting at `:454` — test `call_function`**, calling a Python function from the
host by name. We do not expose that API:
`grep -rn "callFunction\|functionNames\|hasFunction" lib/ native/src/` returns
**0 hits**.

So more than half of upstream's REPL test file tests a surface we do not have.
Other divergences that change how a scenario must be written:

| upstream | ours | consequence |
|---|---|---|
| `MontyRepl::load(bytes)` static ctor (`R:209`) | `restore()` instance method | the R1 defect above; scenarios must cover *both* orderings |
| `feed_run` returns `Result`, errors throw in Python | `feedRun` returns `MontyResult` with `.error` | assert on `r.error?.excType`, not `throwsA` |
| native `input_values` channel | inputs prepended as source text | input scenarios test a different mechanism than upstream's |
| errors carry filename/line/column | REPL errors carry no filename/line/column on our handle (per `7816822`) | traceback scenarios (R5) must assert only what our envelope carries |

**Consequence for this plan:** upstream is a strong donor for the ~22 stateful
scenarios in §1.2 and *no* donor for the 29 `call_function` tests. We port the
former and ignore the latter. We do not build `callFunction` to serve tests.

---

## 2. What we already have

| area | file | covers |
|---|---|---|
| Session isolation | `test/integration/{ffi,wasm}_multi_repl_test.dart` | 3 scenarios; incidentally the only cross-feed persistence assertions we have |
| Externals lifecycle | `test/integration/_repl_extfns_lifecycle_test_body.dart` | 3 scenarios, **deeper than upstream** — de-registration across feeds |
| Snapshot lifecycle | `test/integration/_repl_snapshot_lifecycle_test_body.dart` | `StateError` guards + non-empty bytes. **No state round-trip.** |
| Futures | `test/integration/_repl_futures_test_body.dart` | 11 scenarios on `resumeAsFuture`/`resolveFutures` |
| OS calls | `test/integration/ffi_repl_oscall_test.dart` | OS handler dispatch |
| Metadata | `test/unit/repl/monty_repl_metadata_test.dart` | `scriptName` |

Two absences worth naming:

- **`detectContinuation` has no assertion anywhere under `test/`.**
  `grep -rn detectContinuation` finds it in `README.md:92`,
  `example/05_repl.dart:74`, `example/09_limits_and_code_capture.dart:87` and
  `packages/dart_monty_web/web/repl_demo.dart:164` — documented and
  demonstrated, never asserted. `example/05_repl.dart` runs under the gate's
  `examples` step, so it is smoke-covered; no test asserts the three
  `ReplContinuationMode` values. Upstream does, at `R:143`.
- **Print accumulation across feeds** is untested;
  `_print_callback_test_body.dart` drives one-shot `Monty(...)`, not a REPL.

### 2.1 The pattern to reuse — no new infrastructure needed

`test/integration/_repl_snapshot_lifecycle_test_body.dart` (97 lines) exports
`void runReplSnapshotLifecycleTests()`. Two 12-line wrappers call it:
`ffi_repl_snapshot_lifecycle_test.dart` and
`wasm_repl_snapshot_lifecycle_test.dart`. **One scenario set, both backends.**
This is the whole mechanism the plan needs.

---

## 3. Decision 1 — hand-written scenarios, not a fixture format

**Recommendation: hand-written scenarios in shared test bodies (Option A).
Reject a new multi-step fixture format. Reject "both".**

The ergonomic argument (a DSL for feeds is boilerplate-free) is real but
secondary. The decisive argument is provenance, and it comes from this repo's
own doctrine.

`docs/contributor/testing-philosophy.md:27` — *"Name where the expected value
came from. If the answer is 'from running the code', you have written the bug
down as the specification."* And `:52` — *"Name what your reference shares with
the code it checks. The answer must be **nothing**."*

Upstream's scenarios supply **both** the steps and the expected value, computed
by an implementation our Dart binding does not participate in. Porting
`crates/monty/tests/repl.rs:39` carries upstream's `42` across, and that `42`
satisfies both rules.

The obvious way to author a fixture format's rows is to run our REPL and record
what it printed — precisely the failure `:29` names, and one this repo has
committed **at least six times** (`testing-philosophy.md:37`).

### 3.1 The strongest objection, and why it still loses

agy attacked this and was **partly right**, so the argument is stated here in
its corrected form rather than its original one.

> *A generator script could extract the feeds and assertions out of
> `crates/monty/tests/repl.rs` into a data format, bypassing our Dart code
> entirely. That satisfies rules 2 and 3 just as well as hand-porting. Your
> claim that a data format has "no donor" is false, and distinguishing it from
> the 531-fixture corpus is special pleading.*

**Conceded:** a data format *can* borrow upstream's values. "No donor" was too
strong, and the corpus distinction on its own is indeed special pleading. The
provenance rule therefore does **not** by itself decide A over B — it decides
both over inventing values, which is the real target.

**But the objection does not survive contact with the file.** Classifying the
22 stateful tests in `crates/monty/tests/repl.rs:1`–`:453` by whether they are
a linear feed→assert sequence or need host-side control flow
(`feed_start`, `resume`, `dump`/`load`, `into_function_call`, `collect_string`,
`ReplStartError` destructuring):

**11 linear, 11 non-linear.** The non-linear half is:
`repl_dump_load_survives_between_snippets`,
`repl_dump_load_preserves_heap_aliasing`,
`repl_start_external_call_resumes_to_updated_repl`,
`repl_feed_start_restores_comprehension_slots_before_next_turn` and
`…_after_runtime_error`, `repl_progress_dump_load_roundtrip`,
`repl_start_run_pending_resolve_futures_roundtrip`,
`repl_start_runtime_error_preserves_repl_state`,
`…_during_external_call_…`,
`repl_dataclass_method_call_yields_function_call_with_method_flag`,
`repl_start_new_external_function_in_later_block`.

Three consequences, in order of weight:

1. **A generator covers at most half, and not the important half.** R1 —
   the top-ranked category, the one with a live measured defect — is
   `repl_dump_load_survives_between_snippets`, which carries `snapshot()` bytes
   between two `MontyRepl` instances. It is in the non-linear half. So is every
   paused-progress scenario. The generator buys the *easy* scenarios and leaves
   the ones that found a bug to be hand-written anyway — which is Option C,
   two mechanisms, strictly more cost than either alone.
2. **The generator is a new artifact with a silent failure mode.** It must
   parse Rust source that upstream is free to refactor, and this repo is
   mid-0.19-upgrade. When upstream renames a helper, the generator emits
   *fewer rows* and everything still passes. That is category-absence rot
   (§3.2) reintroduced one layer down, where no exhaustiveness check is looking.
3. **Hand-porting gets the same provenance for free.** Writing
   `expect(r.value, const MontyInt(42))` next to a `// crates/monty/tests/repl.rs:45`
   comment carries upstream's value across just as faithfully as a generated
   row, with no parser to build, test, or keep current.

So the provenance rule is neutral between A and B; the **expressiveness and
maintenance** arguments decide it, and both point at A. Where the data format
would genuinely read better — the ~11 linear cases — the saving is a few lines
of `await repl.feedRun(...)` per scenario, which does not pay for a parser.

**Cost of the rejected option:** one file format, one generator, one runner,
one upstream-source coupling, and a second mechanism to cover the half the
generator cannot reach.

### 3.2 The rot mechanism, and its limit

Hand-written sets rot by **category absence** — nobody ever writes the
snapshot round-trip scenario, and nothing notices. A data format does not fix
this: a missing row is exactly as invisible as a missing test function.

So the guard must target absence directly. **Proposed artifact:** a
`required categories` test in the shared body that enumerates the R-codes of
§4 as data and fails when a category has no registered scenario:

```dart
// Illustrative. The list is the contract; the map is what exists.
const requiredStatefulCategories = {'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'R9'};
test('every required statefulness category has at least one scenario', () {
  expect(registeredCategories, containsAll(requiredStatefulCategories));
});
```

This is an assertion, not a convention, and it fails when a category is
deleted or never written. It follows the `knownReplDivergentFixtures` precedent
on `feat/repl-corpus-runner`: **every entry is run and asserted, never
skipped**, so the list is self-cleaning in both directions.

Note what does **not** protect this: DCM. `dcm_options.yaml:26` excludes
`test/**` from metrics, and `tool/dcm_ratchet.sh:3` is a *count* ratchet
against a recorded baseline, not a threshold rule. Any proposal resting on
`max-file-length` is inert in this repo today.

---

## 4. Decision 2 — categories to cover, ranked

Ranked by (severity of the failure it catches) × (currently uncovered). Each
row names the failure and the upstream donor for its expected values.

| # | category | failure it catches | donor | now |
|---|---|---|---|---|
| **R1** | **Snapshot/restore round-trip + heap aliasing** | **the live measured defect in §0** — silent state loss on `restore()`; and aliased objects de-duplicating across a round-trip | `R:204`, `R:217` | guards only |
| **R2** | Error recovery mid-session | a failed feed kills or corrupts the session; state assigned *before* a mid-feed raise is lost. This is the agent-loop use case. | `R:113`, `R:350`, `P:170`, `P:209`, `P:163` | none |
| **R3** | Redefinition & late binding | a previously-compiled function keeps calling the *old* callee, or a user `def` fails to shadow a builtin. The most REPL-specific semantic there is. | `R:49`, `R:61`, `R:76`, `R:96` | none |
| **R4** | No replay / heap mutation | the engine re-executes earlier snippets — `items.append(1)` runs twice and the list holds `[1,1]`. Catastrophic and silent. | `R:14`, `R:126`, `P:93`, `P:100` | none |
| **R5** | Cross-snippet traceback provenance | a frame's line/column resolved against the *wrong* snippet's source. Upstream calls this out explicitly at `R:173`. Assert only what our envelope carries (see §1.4). | `R:159`, `R:173`, `P:219` | none |
| **R6** | Definitions & closures persist | a `def` or a closure's captured cell does not survive to the next feed | `R:39`, `P:67`, `P:78` | incidental |
| **R7** | Print accumulation across feeds | output from feed N leaks into, or is lost by, feed N+1 | `P:269` | one-shot only |
| **R8** | Inputs across feeds | an input fails to override an existing global. Ours prepends source text rather than using the native channel (§1.4), so this tests *our* mechanism. | `P:374`–`P:405` | none |
| **R9** | Continuation-mode detection | `>>>` vs `...` misreported, breaking every REPL UI | `R:143` | unasserted |
| **R10** | Limits across feeds | a session budget not enforced on the *second* feed. **Web-blocked — see §5.2.** | no upstream donor (`P:279` is single-feed) | none |

R1 is first because it is the only category with a defect already measured and
in the tree. R10 is last because it is the only one with neither an upstream
donor nor a working web path.

Externals-across-feeds is deliberately absent: `_repl_extfns_lifecycle_test_body.dart`
already covers it more thoroughly than upstream does.

---

## 5. Decision 3 — both backends

**Recommendation: R1–R9 run on FFI and web from day one, via the shared-body
pattern of §2.1. Only R10 is FFI-only, and it gets a tripwire.**

### 5.1 This is possible today — measured

The obstacle everyone expects here is core#140. It does not apply.
`lib/src/repl/wasm_repl_bindings.dart:47` throws **only** `if (limitsJson != null)`.
A bare `MontyRepl()` works on the web. Measured on both web compilers:

```
PROBE web add(22) => value=MontyInt(42) err=null      # R3/R6 across 4 feeds
PROBE web items   => value=MontyList(2 items) err=null # R4 heap mutation
PROBE web fresh read    => value=MontyNone() err=NameError  # R1 defect reproduces
PROBE web fed-first read=> value=MontyInt(2) err=null
```

R1–R9 need no limits, so **the web blocker that made the corpus runner FFI-only
does not constrain this suite.** That asymmetry is the single most useful
finding in this document: the corpus runner is FFI-only because it depends on
limits to match one-shot's footing; a statefulness suite has no such dependency.

### 5.2 R10 and the tripwire

R10 needs `MontyRepl(limits: …)`, which throws on the web. Follow the existing
precedent rather than inventing one: `test/integration/wasm_repl_corpus_test.dart`
is a **tripwire**, asserting the blocker is still present so the suite goes red
the day core#140 lands. R10's web half should do the same, and must not be a
skip.

**Rejected: making the whole suite FFI-only.** The cost is concrete — the WASM
engine and the FFI engine are the same Rust crate but reach it through
different bindings and a worker boundary, and R1 is a *Dart-side* defect that
reproduces on both. A web-only regression in cross-feed persistence would ship
silently. Nine categories would be dark on the web to accommodate one.

### 5.3 dart2js erases `int`/`double` — what it means here

Measured, same scenario, the two web compilers disagree on rendering:

```
dart2js:   PROBE web float => value=MontyFloat(4)
dart2wasm: PROBE web float => value=MontyFloat(4.0)
```

The `MontyValue` type is correct on both; the `toString()` differs because
dart2js has one number type. Rules for these scenarios:

- Assert on the **typed value** (`const MontyInt(42)`, `isA<MontyFloat>()`),
  never on a rendered string of a number.
- Do not assert `4.0 is int` either way, and avoid integral doubles as
  expected values where an `int` would do.
- Both compilers must run it: the gate already pairs `wasm_unit` and
  `wasm_unit_w` (`tool/gate.sh:134`, `:137`) for exactly this reason.

---

## 6. Decision 4 — the gate

**Recommendation: yes, and for the FFI half the decision is already made by a
glob.**

- `tool/gate.sh:94` runs `dart test $(ls test/integration/ffi_*_test.dart | grep -v with_cm)`.
  A new `ffi_repl_statefulness_test.dart` **joins the gate automatically**.
- The web half does not: `tool/test_wasm_unit.sh` uses an explicit list
  (`:139`–`:165`) plus an `UNLISTED` guard (`:113`–`:126`) that **fails the gate**
  if a `wasm_*_test.dart` exists and is not listed. So adding
  `wasm_repl_statefulness_test.dart` requires one line in that list — and
  forgetting is caught, not silent.

That asymmetry is fine, and the two mechanisms agree on the invariant that
matters: *every test file runs*. One reaches it by globbing, the other by an
explicit list with a guard derived from the same glob.

### Wall-clock cost — measured, not estimated

| suite | backend | tests | time |
|---|---|---|---|
| existing 3 REPL feature files | FFI (`-p vm`) | 11 | **1.5 s** |
| existing 3 REPL feature files | web (`-p chrome -c dart2js`) | 12 | **3.9 s** |

A ~30-scenario suite of the same shape projects to **~3 s FFI** and **~6–8 s
per web compiler**. The gate runs two web compilers, so the total added is
**under ~20 s** against a gate already around four minutes. Not a reason to
defer it to a separate job.

---

## 7. Decision 5 — what NOT to do

1. **Do not build a multi-step fixture DSL.** §3. No donor for expected values,
   cannot express the mid-pause and cross-instance scenarios, and the parser
   becomes a second thing to test.

2. **Do not reintroduce the differential runner (REPL vs one-shot).** The
   objection recorded in `7816822` stands and this plan does not weaken it: the
   handles are intentionally non-identical (usage hard-zero on the REPL, errors
   carrying no filename/line/column), so it needs a normaliser and the
   normaliser becomes the thing under test. Nothing in §4 requires comparing
   the two handles — every category asserts against an upstream-authored value
   instead.

3. **Do not port upstream's `call_function` half.** 29 of 51 tests
   (`crates/monty/tests/repl.rs:454`–`:864`) drive an API we do not expose.
   Porting them means building `callFunction` to serve tests, which is
   backwards. If that API is ever added, these tests come with it.

4. **Do not add a skip list.** Use the `knownReplDivergentFixtures` pattern from
   `feat/repl-corpus-runner`: record the divergence and **assert it still
   happens**, so a fixed divergence turns the suite red. Two skip sets in this
   repo were found carrying wrong reasons on a single day; an assertion cannot
   go stale unnoticed.

5. **Do not gate this behind fixing the R1 defect.** The plan is coverage; the
   fix is separate work. R1's scenario should be written to the *upstream*
   expectation (`R:204` asserts 42) and will be **red on arrival** — which is
   `testing-philosophy.md:12`, "name the break you applied, and the test that
   went red", obtained for free. Land it red-and-skipped-with-an-issue-link, or
   land it with the fix; do not land it asserting the current wrong behaviour
   (`testing-philosophy.md:46`).

### 7.1 The 531-through-a-fresh-REPL runner: KEEP

**Recommendation: keep it as is. Do not drop or narrow it.**

agy argued for dropping it, on the ground that once a stateful suite exists the
runner "provides no unique coverage" and only sustains a misleading signal.
**Rejected on mechanism.** The runner's unique contribution is not plumbing —
a stateful suite does exercise create/feed/dispose — it is **breadth of value
and error shapes through the REPL's second result-envelope builder**
(`build_repl_result_json`, a different function from one-shot's
`build_result_json`). 531 distinct Python programs exercise that envelope;
~30 hand-written scenarios exercise perhaps fifteen value shapes. Dropping it
would retire real coverage to fix a comprehension risk.

The comprehension risk is real, though, and agy identified it correctly. It is
already mitigated in the strongest available way: the runner's header states
in its first six lines that it is a plumbing smoke test and *"a green run here
does not mean the REPL is tested by 531 fixtures"*. Once this plan's suite
exists, that header should gain one line pointing at it, so the reader who
wants REPL coverage is sent somewhere real.

Worth recording against a future "narrow it" proposal: 531 fixtures found
exactly **two** divergences, and both
(`ext_call__name_lookup.py`, `with__class_external.py`) have the **same** root
cause — the REPL auto-resolves every `NameLookup` and never asks the host. A
narrowing proposal should confront that number honestly in both directions: it
is a low yield for 531 fixtures, and it is a defect class no scenario in §4
would have found.

---

## 8. Implementation sketch

Four commits, each independently green.

1. `_repl_statefulness_test_body.dart` + `ffi_`/`wasm_` wrappers, covering
   **R4, R6, R3** (no-replay, persistence, redefinition). Add the wasm file to
   `tool/test_wasm_unit.sh`. Add the §3.2 category-completeness assertion.
2. **R2, R5** — error recovery and traceback provenance.
3. **R1** — snapshot round-trip and aliasing. Expect red; see §7 item 5.
4. **R7, R8, R9** — print accumulation, inputs, continuation modes.

R10 last, with its tripwire, and only if someone wants it before core#140.

Per `testing-philosophy.md:12`, every scenario must be watched to fail before
it is committed. The mutation for most of §4 is one line: make `feedRun`
construct a fresh session each call, and R3/R4/R6 must all go red.

---

## 9. agy disposition ledger

Four runs, against a cap of eight. Prompts and raw responses in the session
scratchpad as `sfp_q{1..4}.txt` / `sfp_q{1..4}_resp.md`.

Mechanical check (`agy_check`): run 1 **FAILED** (3706 bytes, zero citations);
runs 2 (2991 B, 1.9:1), 3 (3772 B, 2.3:1) and 4 (2840 B, 2.2:1) passed. Every
`path:line` cited in runs 2–4 was opened and checked; **all exact**, including
`dcm_options.yaml:26`, a file agy opened that the prompt did not name.

| # | run | claim | disposition | basis |
|---|---|---|---|---|
| 1 | q1 | Whole response carried **zero `path:line` citations** despite being asked to verify three specific claims | `RETURNED` | Re-asked as q3 demanding citations. Skill rule: a response with no citations is a failed run, not a clean bill of health. |
| 2 | q1 | Pick **Option A** (hand-written) over a fixture format | `ACCEPTED-ON-ARGUMENT` (due: superseded by §3) | Uncited, and it later reversed under challenge. Recorded as one vote. The plan's §3 rests on `testing-philosophy.md:27`/`:52`, which I verified, not on this. |
| 3 | q1 | `tool/dcm_ratchet.sh` with `max-file-length` is the artifact that stops scenario rot | `REJECTED` | `grep -n 'max-file-length\|max-methods' analysis_options.yaml` → 0 hits; `tool/dcm_ratchet.sh:3` = *"fail on any NEW issue above the recorded baseline"*, a count ratchet, not a threshold. Retracted by agy in run 3. |
| 4 | q2 | Gate membership is decided by a glob — `tool/gate.sh:94` | `MEASURED` | Opened `tool/gate.sh:94`; quote exact. Independently confirmed a new `ffi_*_test.dart` is auto-included. |
| 5 | q2 | core#140 throws only when limits are supplied — `wasm_repl_bindings.dart:47` | `MEASURED` | Citation exact (`if (limitsJson != null) {`). Independently confirmed by running a bare `MontyRepl()` on dart2js and dart2wasm — state carried across 4 feeds. |
| 6 | q2 | Split R10 out and tripwire it; run everything else on both backends | `REPRODUCED` | Same conclusion I reached from the probe in §5.1. Repro: stage assets per `tool/test_wasm_unit.sh` steps 1–3, run a bare-REPL multi-feed test on `-c dart2js` and `-c dart2wasm`. |
| 7 | q2 | Glob-driven gate membership is **BAD** | `REJECTED` | Applied consistently it would condemn `tool/test_wasm_unit.sh`'s `UNLISTED` guard (`:113`–`:126`), which exists to *simulate* a glob because the explicit list was the thing that failed. Both mechanisms enforce "every file runs"; the glob does it without a guard. |
| 8 | q2 | **DROP** the 531-through-fresh-REPL runner — "no unique coverage" | `REJECTED` | The unique coverage is 531 value/error shapes through `build_repl_result_json`, which ~30 scenarios do not approach. Its misleading-signal point is accepted separately and handled in §7.1. |
| 9 | q3 | RETRACT the dcm_ratchet claim | `MEASURED` | Clean retraction, correctly scoped. |
| 10 | q3 | `dcm_options.yaml:26` excludes `test/**` from metrics | `MEASURED` | Verified: `sed -n '26p' dcm_options.yaml` → `      - "test/**"`, under `exclude.metrics`. Agy opened a file I had not handed it. |
| 11 | q3 | Upstream is 100% hand-written; only parametrize is `test_repl.py:136` (return types) | `MEASURED` | Citations exact (`repl.rs:16`, `test_repl.py:50`, `:136`). Independently: `grep -c 'test_cases\|fixture'` → 0 across all three test files. |
| 12 | q3 | ~48% of `repl.rs` is `call_function`, section starts `:454` | `MEASURED` | Confirmed: `awk 'NR>=454 && /^#\[test\]/' \| wc -l` → **29 of 51** tests; 412 of 865 lines. Both framings hold. |
| 13 | q3 | Therefore upstream is a **weak template**; build table-driven instead | `REJECTED` | Non-sequitur. That half of the file tests an API we lack is a reason to ignore *that half*, not to discard the 22 stateful scenarios in §1.2 — which are precisely our surface and carry the independent expected values §3 depends on. |
| 14 | q1 vs q3 | Reversed its own Option A verdict under challenge, with no new evidence bearing on the choice | noted, not a claim | The `dcm_options.yaml` finding is real but only shows no *lint* guard exists; it does not favour a data format. Textbook framing-induced instability — treated as one vote, per the skill. |
| 15 | q4 | My "a data format has **no donor** for expected values" is **UNSOUND** — a generator could extract upstream's feeds and assertions into rows | `MEASURED` — **claim upheld against me** | Correct, and §3.1 now says so. Rules 2/3 do not by themselves separate A from B. I had overstated my own argument; the correction is agy's. |
| 16 | q4 | Therefore the corpus-vs-new-format distinction is **special pleading** | `MEASURED` (partly upheld) | Upheld as stated: on provenance alone the distinction does not hold. It is not special pleading once expressiveness is added, which is the ground §3.1 now argues on. |
| 17 | q4 | Therefore prefer a table-driven format | `REJECTED` | `sfp_count.sh` over `crates/monty/tests/repl.rs:1`–`:453` classifies the 22 stateful tests **11 linear / 11 non-linear**. A generator reaches at most half, and R1 — the top category, with the live defect — is in the non-linear half. Covering the rest still needs hand-written Dart, i.e. Option C. |
| 18 | q4 | RETRACT "a table-driven runner is the only mechanism that catches rot"; the real mechanism is an **exhaustiveness meta-test** over a canonical category list | `REPRODUCED` | Clean retraction. It independently proposed the same mechanism already drafted at §3.2, arrived at from the opposite direction — the strongest single confirmation in these four runs. |

**`ACCEPTED-ON-ARGUMENT` count: 1** (row 2), within the limit of two. The run is
validated; findings below are reported as findings, not hypotheses.

Row 15 is the one that changed the document. It is recorded as agy's, not
absorbed into the prose: the published §3 argues on narrower ground than the
draft did **because agy refuted the wider version**.

### What I verified, could not verify, and rejected

**Verified myself** (opened the file or ran the command): every upstream line
cited in §1; the 29/51 `call_function` split; zero `callFunction` hits in
`lib/` and `native/src/`; zero `detectContinuation` assertions under `test/`;
`gate.sh:94` glob and `test_wasm_unit.sh`'s `UNLISTED` guard; `dcm_options.yaml:26`;
`wasm_repl_bindings.dart:47`; the `_ensureCreated` call sites and the missing
one in `restore()`; the R1 defect on FFI, dart2js and dart2wasm; the dart2js /
dart2wasm float rendering difference; both wall-clock measurements in §6.

**Could not verify:** whether R10 is worth building at all before core#140
lands — that is a priority call for the owner, not a fact. Whether the ~30-scenario
projection in §6 holds; it is arithmetic from an 11-test and a 12-test
measurement, not a measurement of the suite itself.

**Rejected from agy:** rows 3, 7, 8, 13, 17 above, each with the
counter-evidence recorded there.

**Accepted against myself:** row 15. My original provenance argument was too
strong and agy broke it. The recommendation did not change; its justification
did, and §3.1 carries the corrected version.

**Not laundered:** rows 2 and 14 record that agy's format verdict is a single
vote that reversed under pressure — it said Option A in run 1 and the opposite
in run 3. §3's conclusion is mine and rests on the 11/11 split I measured, not
on either of its votes.
