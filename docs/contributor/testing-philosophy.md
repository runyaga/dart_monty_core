# Testing philosophy

Three checks. [`testing-runbook.md`](testing-runbook.md) tells you *what to run*.
This tells you whether what you wrote is worth running.

Each is phrased as something you must be able to **name**, because a principle
is a belief you can hold while doing nothing. Naming produces an artefact — or
an obvious absence.

---

### 1. Name the break you applied, and the test that went red

A test you have not watched fail is a guess about what it covers. Apply the
mutation it claims to catch, see it go red, revert.

This is not ceremony. A kwargs test written *for this rule* passed under
mutation, because there were **two** serialization sites and the wrong one had
been broken. It would have been committed as coverage while testing nothing.
Another mutation — dropping every keyword argument on the way to an OS handler —
left **all 193 Rust tests green**.

If you cannot name the break, you do not know what the test does.

---

### 2. Name where the expected value came from

If the answer is *"from running the code"*, you have written the bug down as the
specification.

A test that records current-but-wrong behaviour makes the defect permanent: the
suite now defends it. `Ellipsis` collapsed onto the string `"..."`, and tests
asserted that collapse **as correct** — so the encoder was "right" by
construction, and the defect outlived every one of 1062 passing fixtures.

**At least six tests in this repo have done this**, and four still do:
`rt_bigint_large_stays_lossy`, `rt_function_becomes_string`,
`rt_exception_becomes_string`, `rt_repr_becomes_string`, plus the two `Ellipsis`
assertions since inverted. This is a different and worse failure than a test that
checks nothing: a silent test proves nothing, but these actively defend the bug.

Expected values must come from somewhere the code cannot reach: the language
spec, upstream's own output, a hand-computed constant.

**A known-wrong behaviour is allowed, but never as a passing assertion.** Make
it fail, or `markTestSkipped(reason)` with an issue link. `_knownDivergences`
in `_repr_oracle_test_body.dart` is the pattern.

---

### 3. Name what your reference shares with the code it checks

The answer must be **nothing**.

This is the rule the other two cannot reach. You can mutate every test, watch
every one go red, and still build an oracle that proves only that the code
agrees with itself.

That happened here. The conformance suite compares the FFI shim against a binary
that includes the same `convert.rs` via `#[path = "../convert.rs"]`. Both sides
encode with the same code, so it cannot detect a bug in the encoder — and did
not, through 1062 green fixtures, for two separate defects.

Before trusting a reference, say what it shares with the subject: the same
struct, the same function, the same file, the same assumption. Shared anything
is shared blind spots. The fix is a source the code does not participate in —
here, monty's own `repr()`, computed upstream before our encoding runs.

---

### Why the bar is here

Two distinct failures, and they need different responses.

**Silence.** Of **1593** registered fixture tests, **646 (41%)** asserted nothing
at all: a bare `return` in the harness produced a passing test. One harness
advertised 531 green tests on the strength of 34 real assertions.

**Inversion.** At least six tests asserted a known defect *as correct*. That is
not a coverage gap — it is the suite treating a bug as the specification, and it
is why fixing one required inverting tests rather than adding them.

None of that was carelessness. Each was a reasonable-looking test that nobody
had watched fail, checked the provenance of, or asked what its reference shared
with its subject.
