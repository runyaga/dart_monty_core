# WIRE-CONTRACT.md

**Status: DERIVED, not authored.** Every row below comes from code that runs.
Nothing here was written from memory or inferred from a type name.

This file is cited as normative by 10 sites across Rust, Dart and the test
suite — including a test that prints `WIRE-CONTRACT.md row N requires ...` when
it fails — and **it did not exist**. A developer hitting that failure was told
to consult a document nobody had written. That is what this fixes.

## Where each part comes from

| Part | Source | Why it can be trusted |
|---|---|---|
| The row table | `test/integration/_wire_contract_test_body.dart` | Those rows are EXECUTED on all three backends (VM/FFI, dart2js, dart2wasm). A wrong row fails a test. |
| The tag list | `native/src/convert.rs` | Extracted from the `"__type": "..."` literals the encoder actually emits. |
| The rules | quoted verbatim from their citing sites | Each rule below quotes the comment that cites it, so the rule cannot drift from the code that claims to implement it. |

**Do not hand-edit the row table.** `tool/check_wire_contract.sh` regenerates
and compares it. If a row here disagrees with the test, the test wins.

## Rules

### R1 — a dict is encoded as a TAGGED envelope, never as a bare object

> "Encode a dict as a TAGGED envelope — never as a bare object or array. This
> is rule R1 of `WIRE-CONTRACT.md`, and it is what closes core#136. A bare
> object was byte-identical to a tagged envelope, so sandboxed Python returning
> the plain dict `{"__type": "path", "value": "x"}` arrived in Dart as a
> genuine `MontyPath` — untrusted code choosing its own host type. Now user keys
> live inside `value`/`entries`, which the decoder reads as dict CONTENTS and
> never re-dispatches, so no arrangement of user data can name a type."
>
> — `native/src/convert.rs:965-972`

Row 11 is R1's executable form: `{"__type": "path", "value": "x"}` written by
the sandbox decodes as `dict`, not `path`.

### R2 — a bare JSON string is a Python `str`, full stop

> "A bare JSON string is a Python `str`, full stop — rule R2."
>
> — `lib/src/platform/monty_value.dart:46`

Types that are not `str` carry their own tag rather than arriving as text.
Before wire v3 several did arrive as bare strings, so a value's type depended on
guessing at its contents (`lib/src/platform/monty_value.dart:128`,
`lib/src/platform/monty_value_scalars.dart:112`). Row 6 pins the consequence:
the string `"NaN"` stays `str`, while `float("nan")` is `float` (row 5).

### R4 — an untagged object at a value position is a PROTOCOL VIOLATION

> "Since wire format v2 every object the encoder emits is tagged, so anything
> untagged is a protocol violation rather than a value. `fromJson` is a
> deserializer; refusing malformed input is the same contract `json.decode`
> has (rule R4 of WIRE-CONTRACT.md)."
>
> — `lib/src/platform/monty_value.dart:215-218`

The decoder throws `FormatException` rather than guessing a dict.

### R3 is not cited anywhere

`grep -rn 'rule R3\|R3 of' lib/ native/src/ test/` returns nothing. No source
claims to implement an R3, so none is invented here. If one is added, number it
explicitly rather than assuming this gap is R3.

## The row table

Each row is a Python expression and the `__type` tag its value must carry when
it reaches the host. Generated from 30 executed assertions.

| Row | Python | Decodes as |
|---|---|---|
| 1 | `None` | `none` |
| 2 | `True` | `bool` |
| 3 | `42` | `int` |
| 4 | `2**53 + 1` | `bigint` |
| 4 | `2**63` | `bigint` |
| 5 | `4.0` | `float` |
| 5 | `-0.0` | `float` |
| 5 | `float("nan")` | `float` |
| 5 | `float("inf")` | `float` |
| 6 | `"s"` | `str` |
| 6 | `"NaN"` | `str` |
| 7 | `b"hi"` | `bytes` |
| 8 | `[1, 2]` | `list` |
| 9 | `(1, 2)` | `tuple` |
| 11 | `{"a": 1}` | `dict` |
| 11 | `{"__type": "path", "value": "x"}` | `dict` |
| 11 | `{1: "a"}` | `dict` |
| 12 | `{1, 2}` | `set` |
| 13 | `frozenset([1])` | `frozenset` |
| 14 | `import datetime ; datetime.date(2020, 1, 1)` | `date` |
| 15 | `import datetime ; datetime.datetime(2020, 1, 1)` | `datetime` |
| 16 | `import datetime ; datetime.timedelta(days=1)` | `timedelta` |
| 17 | `import datetime ; datetime.timezone.utc` | `timezone` |
| 18 | `import pathlib ; pathlib.Path("x")` | `path` |
| 21 | `...` | `ellipsis` |
| 22 | `ValueError("boom")` | `exception` |
| 23 | `int` | `type` |
| 25 | `abs` | `builtin` |
| 26 | `class C: ;     pass ; C()` | `class_instance` |
| 27 | `a = [] ; a.append(a) ; a` | `cycle` |

## Tags with no row

These are emitted by `native/src/convert.rs` but are not produced by any row's
Python expression, because they arise from contexts the row table does not
cover (host-inbound values, error paths, or interpreter internals):

- `filehandle`
- `function`
- `namedtuple`
- `nope`
- `not_implemented`
- `repr`
- `time`

They are NOT undocumented in the sense that matters: every one of them has an
inbound-forgery test proving the sandbox cannot forge it into existence
(`test/integration/_inbound_forgery_test_body.dart`, gated by
`tool/check_forgery_coverage.sh`).

## Wire format version

`WIRE_FORMAT_VERSION` in `native/src/convert.rs` is the handshake, and
`tool/check_wire_version.sh` pins the Rust and Dart copies together. The rules
above are versioned with it: R1 landed in v2, R2's tier-2 tags in v3.
