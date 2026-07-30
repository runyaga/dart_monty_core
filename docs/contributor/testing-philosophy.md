# Testing philosophy

Two disciplines. Everything in
[`testing-runbook.md`](testing-runbook.md) tells you *what to run*; this tells
you whether what you wrote is worth running.

### A test is not verified until you have seen it fail

Apply the mutation it claims to catch, watch it go red, revert.

During the 0.19 upgrade this changed the outcome **three times**. The clearest
case: a new kwargs test passed under mutation because there were *two*
serialization sites and the wrong one had been mutated. Without the check it
would have been committed as coverage while testing nothing. In another, an
OS-call kwargs mutation left **all 193 Rust tests green**.

### Never assert current behaviour just to make a test pass

Three tests asserted a value-fidelity defect **as correct** — `Ellipsis`
collapsing onto the string `"..."`, twice in `convert.rs` and once in control (d)
on *both* backends. That is why #129 survived 1062 "passing" fixtures: the suite
had been taught the bug was the specification.

If a test documents a known-wrong behaviour, it must fail, be marked skipped with
a reason, or carry a comment that says plainly it is pinning a defect and links
the issue.
