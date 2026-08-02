# Changelog

## Unreleased (0.19.0)

Requires `monty` v0.0.19. The `monty` crate's public surface was split in 0.19 —
it went from 1321 to 306 public items and most of what this package uses moved to
the new `monty-types` crate — so this is a substantial internal change with a
small consumer-facing surface.

### Breaking

- **The web backends no longer lose numbers (#128).** Three distinct defects,
  all from the same cause — a JSON number's *text* is where the information
  lives, and the JS bridge reparses it:

  | Python | was, on dart2js/dart2wasm | now |
  |---|---|---|
  | `4.0` | `MontyInt(4)` — `JSON.parse("4.0") === 4` | `MontyFloat(4.0)` |
  | `-0.0` | `MontyFloat(0.0)` — `JSON.stringify(-0) === "0"` | `MontyFloat(-0.0)` |
  | `2**62` | `4611686018427388000` (rounded) | exact |

  Those three shapes now travel as tagged **text**, which no reparse can damage.
  Every other finite number stays a plain JSON number, so the corpus does not
  grow — tagging *all* numbers was measured at 6.52× bytes and 17.4× round-trip
  latency and rejected.

- **Integers beyond 2⁵³ are `MontyBigInt` on every backend, including the VM.**
  Previously anything inside i64 was a `MontyInt`. On dart2js Dart's `int` IS a
  double, so past 2⁵³ such a value cannot be a `MontyInt` there at all; making
  the type depend on the backend would be worse than moving the boundary. The
  value is exact either way.

  ```dart
  // was, on the VM: MontyInt(4611686018427387904)
  // now, everywhere: MontyBigInt(4611686018427387904)
  ```

- **Wire format is now 4.**

- **A bare JSON string now means Python `str` and nothing else (#134 + four
  more).** Seven value types used to collapse onto a bare string, so a value's
  Dart type depended on whether some *other* type happened to produce the same
  characters. Each now travels tagged:

  | Python | was | now |
  |---|---|---|
  | `2**63` (beyond i64) | `MontyString` | **`MontyBigInt`** (exact `BigInt`) |
  | `ValueError("boom")` | `MontyString('ValueError: boom')` | **`MontyExceptionValue`** |
  | `float('nan')`, `inf`, `-inf` | `MontyString('NaN')` … | `MontyFloat` (tagged on the wire) |
  | `int` (a class) | `MontyString('int')` | **`MontyOpaque(type, 'int')`** |
  | `abs` | `MontyString('Abs')` ← Rust `Debug`! | **`MontyOpaque(builtin, 'abs')`** |
  | an object's `repr()` | `MontyString` | **`MontyOpaque(repr, …)`** |
  | a cycle marker `[...]` | `MontyString('[...]')` | **`MontyOpaque(cycle, '[...]')`** |

  Two of these were worse than lossy. `ValueError("boom")` was **byte-identical**
  to the Python string `"ValueError: boom"`, so nothing downstream could tell an
  exception from prose describing one — and a message containing `": "` could not
  be recovered at all. And `abs` arrived as `"Abs"`, Rust's `Debug` rendering of
  an internal enum, where every reader would expect the Python name.

  The string `"NaN"` is now a string. It used to decode as `MontyFloat(NaN)`,
  because non-finite floats travelled as bare text and the decoder parsed any
  string that looked like one.

  **Three new variants on the sealed `MontyValue`** — `MontyBigInt`,
  `MontyExceptionValue`, `MontyOpaque` — so exhaustive `switch`es stop compiling
  until each gains an arm. Loud, and the analyzer names every site.

  `MontyExceptionValue` is deliberately *not* called `MontyException`: that name
  is already the exception this package THROWS. Reusing it would leave
  `catch (e) { if (e is MontyException) }` compiling and silently never matching.

- **`MontyOpaque` cannot be sent back into the interpreter.** `type`, `function`,
  `repr` and `cycle` are host-side renderings, not constructible values, so
  decoding one is an error rather than an approximation. `builtin` is the
  exception — its Python name identifies it, so it round-trips exactly.

- **Wire format is now 3.** Asserted at init on both backends.

- **Sandbox escape fixed: sandboxed Python could mint any host type (#136).**
  Returning the plain dict `{"__type": "path", "value": "/etc/passwd"}` from
  Python arrived in Dart as a genuine `MontyPath` — untrusted code choosing its
  own host class by writing a dict key. Closed in **both** directions; the two
  halves landed separately and the second is described in the next entry.

  The cause: only 13 of 27 value types carried a `__type` envelope, so a Python
  dict and a type envelope were **byte-identical on the wire**. Now every dict is
  tagged, and its contents live in a payload the decoder never re-dispatches:

  ```
  {"a": 1}                          →  {"__type":"dict","value":{"a":1}}
  {1: "a"}   (non-string keys)      →  {"__type":"dict","entries":[[1,"a"]]}
  ```

  `MontyValue.toJson()` output changes shape accordingly. If you persisted it, or
  wrote your own decoder against it, both need updating. `WIRE_FORMAT_VERSION` is
  now 2 and is asserted at init, so a stale committed asset fails loudly rather
  than mis-decoding.

- **The other half of #136: a host callback's return value is now encoded, so
  the sandbox can no longer pick its own type through an echo (#139).** The dict
  tagging above closed **Python → Dart**. **Dart → Python** was still open: three
  sites in the self-driven drive loop sent a callback's return with a raw
  `jsonEncode`, so a payload the *sandbox* authored reached the interpreter
  unwrapped.

  ```dart
  // was: Python sees _io.TextIOWrapper, and f.write() reaches the osHandler
  //      as Path.append_text with NO preceding open() to refuse
  // now: Python sees a dict
  await Monty('''
  f = echo({"__type": "filehandle", "path": "/etc/shadow", "mode": "w"})
  ''').run(externalFunctions: {'echo': (args, kwargs) async => args[0]});
  ```

  The host here is an *echo*, and so is any transform, cache, lookup or
  validation callback — it authors nothing. So the advice given for the
  hand-built-envelope entry below ("don't spell envelopes by hand") never
  applied to this: there was nothing a consumer could do.

  The forged **file handle** is the severe case, not the forged path. A path
  grants nothing — sandboxed Python can already write `pathlib.Path(...)`, and
  every path operation reaches the `osHandler` with the path as an argument. A
  file handle skips the authorisation point entirely.

  The fix is a type, not a test: the internal bindings methods that carry a
  value now take `WireJson`, which only `MontyValue`'s encoder can mint, so a
  raw `jsonEncode` at those sites **does not compile**. That caught a fourth,
  unencoded site no audit had listed — it passed a literal, so no grep for
  `jsonEncode` would ever have found it. `core_bindings` is not exported, so
  the public API is unchanged — `resume`, `resolveFutures` and `MontyCallback`
  still take `Object?`.

  Why it survived three tiers, a 17-step gate and green CI: every instrument in
  this package reads values *out* of Python. Nothing tested inbound. There is
  now an inbound probe on both backends where the sandbox authors the payload
  and observation leaves via `print`, never via the value codec under test.

- **An `inputs` key must now be a valid Python identifier, and it is enforced
  (#137).** The doc always said so; nothing checked, and each key was
  interpolated into Python source raw — so a key was a working code-injection
  primitive:

  ```dart
  // executed as Python, before this release:
  Monty(code).run(inputs: {'ignored = 0\nanswer = "INJECTED"\nz': 1});
  ```

  Now `ArgumentError`. Rejecting rather than sanitising is deliberate: a key
  that is not an identifier cannot express what you meant, so rewriting it
  would substitute our guess for your intent. Non-ASCII identifiers still
  work — Python accepts `café`, so an ASCII-only rule would have been a
  regression dressed up as a fix.

  **This is a guard, not a boundary.** Inputs are still rendered as Python
  source, so an escaping bug here would be a code-execution bug. And a bound
  name shadows what it collides with — `{'print': 1}` makes `print("x")` raise
  `TypeError`. That second one is not a bug we can encode away: shadowing is
  what binding a name means, and `print = 1` is legal Python.

- **An infinite `inputs` value produced invalid Python on the web.** Fixed.

  ```dart
  Monty(code).run(inputs: {'f': double.infinity});
  // was, on dart2js:  f = Infinity   → NameError in Python
  // now, everywhere:  f = float('inf')
  ```

  Cause: on dart2js `double.infinity is int` is **true** — the runtime check is
  effectively `Math.floor(x) === x`, which holds for the infinities — so the
  `int` branch claimed the value before the non-finite branch could. The VM was
  never affected.

  **A related case is NOT fixed, and is now reported rather than hidden.** On
  dart2js `4.0 is int` is also true, so `inputs: {'x': 4.0}` still binds a
  Python `int` on that backend, where the VM and dart2wasm bind a `float`.
  Unlike the infinities, this is not recoverable inside the library: the
  parameter is `Object?`, and dart2js destroys the `4` / `4.0` distinction
  before the call is entered. Only a typed input can carry it. Tracked as
  **#137**; the test row is live on the VM and dart2wasm and skipped on dart2js
  with that reference, rather than asserting the wrong answer.

- **`MontyValue.fromJson` now throws `FormatException` on an untagged object or
  an unknown `__type`.** Both used to decode as a dict, and that guess is what
  turned a forged type into a real one. `fromJson` is a deserializer; it now has
  the same contract as `json.decode`.

- **Non-string-key dicts are `MontyPairsDict`, not `MontyList`.** They used to
  travel as a bare JSON array, so a dict silently became a sequence with keys
  indistinguishable from values. `MontyPairsDict` exposes
  `List<(MontyValue, MontyValue)> pairs` in Python insertion order.

  **This adds a variant to the sealed `MontyValue` hierarchy**, so exhaustive
  switches stop compiling until they gain an arm — loud, and the analyzer points
  at each one.

- **A hand-built `{'__type': ...}` Dart `Map` is no longer honoured as that
  type — it is a dict.** THIS ONE FAILS QUIETLY. If an OS-call handler or
  external function returns a map spelling an envelope by hand, the interpreter
  now receives a dict and your code stops working with no error at the boundary.

  ```dart
  // was: interpreted as a dataclass
  (args, _) async => {'__type': 'dataclass', 'name': 'User', 'attrs': {…}}

  // now: say it with the type
  (args, _) async => MontyDataclass(
        name: 'User', typeId: 1, fieldNames: ['name'], attrs: {…},
      )
  ```

  This is the same defect as #136 pointing from the host into the sandbox: any
  `Map` whose keys happened to spell an envelope became that type. Three test
  fixtures in this repo relied on it, which is how it was found.

  Six call sites also built wire JSON with a raw `json.encode(value)`, bypassing
  the encoder entirely — `resume`, `resumeNameLookup`, `MontyRepl.resume`, and
  all three `resolveFutures` implementations. They now route through
  `MontyValue.encodeForWire`, so host values and interpreter values are encoded
  by the same code.

- **Python's `Ellipsis` (`...`) is now `MontyEllipsis`, not `MontyString('...')`.**
  It travels as `{"__type": "ellipsis"}` rather than the bare string `"..."`, so
  `...` and the actual string `"..."` are finally distinguishable — previously
  both arrived as `MontyString` and nothing could tell them apart.

  ```dart
  final r = await Monty('...').run();
  // was: MontyString('...')
  // now: MontyEllipsis()
  ```

  **This adds a variant to the sealed `MontyValue` hierarchy.** If you have an
  exhaustive `switch` over `MontyValue`, it will no longer compile until you add
  a `MontyEllipsis` arm — the analyzer will point at each one. That is the only
  loud part; code that treated `...` as a string just stops matching it.

  A test in `convert.rs` asserted the old collapse as correct behaviour, which
  is precisely why the defect survived to 0.19. It has been inverted. Fixes #129.

- **Dict key order now follows Python insertion order; it used to be sorted
  alphabetically.** ⚠️ **Silent** — nothing errors, values simply arrive in a
  different order. `{"b": 1, "a": 2, "c": 3}` previously came back as
  `{"a": 2, "b": 1, "c": 3}`. Affects **both backends, FFI included**.

  ```python
  d = {"b": 1, "a": 2, "c": 3}
  list(d)     # was ['a', 'b', 'c']  ->  now ['b', 'a', 'c']
  ```

  This restores correct Python semantics: dicts have been insertion-ordered
  since CPython 3.7, and monty computes the order correctly in Rust — `repr(d)`
  always returned `{'b': 1, 'a': 2, 'c': 3}`. Our JSON encoder was discarding it,
  because `serde_json::Map` is a sorted `BTreeMap` unless the `preserve_order`
  feature is enabled. It now is.

  If you sort our output before comparing, nothing changes for you. If you
  relied on receiving alphabetical order, you were relying on a bug — sort
  explicitly. Fixes #129.

- **The `open()` OS-call op is now `'open'`, was `'Open'`.** ⚠️ **This is the one
  change that fails silently.** If you have a custom `OsCallHandler` that matches
  on the op name, a `case 'Open':` (or `if (op == 'Open')`) stops matching and
  every `open()` falls through to your not-handled path. Rename it:

  ```dart
  // before
  if (op == 'Open') { ... }
  // after
  if (op == 'open') { ... }
  ```

  Upstream renamed exactly one of the 23 ops in v0.0.19 (the other 22 are
  unchanged);
  `'Open'` was the only capitalised, undotted name, so `'open'` is now consistent
  with `Path.*`, `os.*`, `date.*` and `datetime.*`.

- **Print output is capped at 10 MB and raises `MemoryError` past it.** Print
  collection previously sat outside all resource accounting, so sandboxed code
  could exhaust the *host* process with a `while True: print(x)` loop. Exceeding
  the cap now raises a normal, catchable Python `MemoryError` — the write is
  rejected, nothing is truncated and no output is silently lost:

  ```python
  try:
      for _ in range(1_000_000):
          print("x" * 100_000)
  except MemoryError:
      ...          # reachable; chunk the output or stream it via printCallback
  ```

- **Session snapshots are not portable across this upgrade.** The canonical dump
  for `"2 + 2"` changed from 60 to 59 bytes, because serialized sessions now carry
  `CompileOptions`. Snapshots taken with 0.18.x cannot be restored on 0.19.0 and
  must be regenerated. (This has been true of every monty bump: 98 → 74 → 60 → 59.)

- **`monty`'s argument-error wording now matches CPython** for Python-style
  argument callsites. For example `json.dumps(1, 2)` raised
  `TypeError('dumps expected at most 1 argument, got 2')` and now raises
  `TypeError('dumps() takes 1 positional argument but 2 were given')`. If you
  assert on these strings, update them.

- **`native/Cargo.lock` is now committed.** The build hook compiles the Rust crate
  as a top-level package on every consumer's `pub get`, so the lockfile is honoured
  and pinning it is what makes your build reproducible. It is also load-bearing:
  free resolution selected a `get-size2` whose `GetSize` impl targeted a different
  `compact_str` major than `ruff_python_ast` used, and the build failed inside a
  dependency neither we nor you control. If you vendor or patch transitive Rust
  dependencies, you now inherit our pins.

### Deliberately unchanged

- **`assert` keeps CPython semantics.** monty v0.0.19 enables pytest-style
  introspected assert messages by default, so `assert 2 == 5` would raise
  `AssertionError('assert 2 == 5')` where CPython raises an empty
  `AssertionError()`. This release pins them **off**, preserving 0.18 behaviour;
  adopting a new upstream default silently is not an upgrade. An opt-in is
  planned.

### Security

- Removed four stale `unic-*` advisory exemptions from `native/deny.toml`.
  v0.0.19 dropped that dependency chain entirely, so the crate no longer carries
  those unmaintained transitive dependencies.

### Internal

- Depends on the new `monty-types` crate; `monty_type_checking` is now
  `monty-type-checking` upstream (the Rust path is unchanged). `monty-fs` is
  **not** required — this package never used `monty::fs`.
- The conformance corpus moved to v0.0.19's 531 fixtures (was 482 from v0.0.18),
  and `tool/check_fixture_corpus.sh` now fails the build if the corpus and the
  pinned monty version disagree.


## 0.18.1

Requires `monty` v0.0.18 (Rust 1.95+ to build from source). Upgrades the
embedded interpreter and surfaces Python `open()` / file I/O with typed OS
exceptions.

### Breaking

- **Snapshot bytecode format changed.** `monty` v0.0.18 re-encoded
  instructions: the `monty_snapshot` byte stream for `"2 + 2"` shrank from 74
  to 60 bytes. Snapshots are NOT portable across the 0.17 → 0.18 upgrade —
  consumers persisting snapshots must regenerate them. Pinned by
  `snapshot_format_pinning` in `native/tests/integration.rs`.
- **Building from source now requires Rust 1.95+** (upstream `monty` raised its
  MSRV). Run `rustup update stable`.

### Added

- **`open()` / file I/O.** `memoryMountedOsHandler` services the `Open` OS-call
  (existence-check for `r`/`rb`, truncate-create for `w`/`wb`, create-preserving
  for `a`/`ab`) and the `append_text`/`append_bytes` calls the interpreter
  emits. Python can `open()` files, read/write/append, and use
  `with open(...) as f:` against an in-memory mount. A new **`MontyFileHandle`**
  `MontyValue` represents the returned file object.
- **`resolveOpenCall(...)`** — the store-agnostic `open()` primitive that owns
  the mode→effect mapping (existence-check / truncate / create → file handle,
  with typed errors). `memoryMountedOsHandler` delegates to it, and any
  `OsCallHandler` (e.g. a `package:file`-backed one) can support `open()` by
  supplying its `exists`/`truncate`/`createIfMissing` primitives.
- **Typed OS exceptions.** OS-handler errors are delivered to Python as their
  real class — `except FileNotFoundError:` / `except PermissionError:` now work
  (previously every `OsCallException` surfaced as `RuntimeError`). New FFI +
  WASM resume entry points: `monty_repl_resume_with_exception` and
  `DartMontyBridge.replResumeWithException`.

### Changed

- **Upgraded the embedded interpreter to `monty` v0.0.18** — an `open()` builtin
  with buffered file I/O and `with` / context-manager support, plus upstream
  garbage-collector, exception-safety, and performance fixes.
- **`resolveFutures` per-call errors are now catchable in Python.** An `errors`
  entry on `resolveFutures` is raised as a `RuntimeError` at the `await` point,
  so a wrapping `try/except RuntimeError` catches it normally. Previously this
  short-circuited past Python's exception handling and terminated the script
  with `MontyScriptError`. Scripts that relied on the old script-terminating
  behavior (without a `try/except`) still surface a terminal error.

### Fixed

- **`memoryMountedOsHandler`'s `Path.read_bytes` returns a typed bytes value**
  instead of a bare list, so binary `open(..., 'rb').read()` buffers correctly.

### Known limitations

- `with__cm_*` use `monty`'s synthetic `_test_cm()`, which exists only under the
  testing-only `test-hooks` cargo feature (never shipped). They have dedicated
  conformance on both backends via opt-in test-hooks builds that never touch the
  shipped binaries: `bash tool/test_cm.sh` (FFI) and `bash tool/test_cm_wasm.sh`
  (WASM). The default suites skip them; real `with open(...)` is covered by
  `with__all`.
- `range__ops` (`2**63` range membership) and `edge__int_float_mod`
  (`int % float`) diverge on the shared `monty` wasm32 engine — an upstream
  concern, not a host-binding gap. Skipped on the WASM runners only; both pass
  on native FFI.

## 0.17.1

### Breaking

- **`MontyCallback` is now `(List<Object?> args, Map<String, Object?>? kwargs)`.**
  Positional args by index (`args[0]`…); keyword args in `kwargs`. Old single-map
  form (`args['_0']`) no longer compiles.
- **`.arguments` renamed to `.args`** on `MontyPending`, `MontyOsCall`,
  `CoreProgressResult`, and `WasmProgressResult`.
- **`useFutures` removed** from `feedRun`/`feedStart`/`Monty.run`. Use
  `externalAsyncFunctions` instead.

### Added

- **`inputs:`** on `Monty.run`/`feedRun`/`feedStart` — inject Dart values as
  Python variables for one execution.
- **`externalAsyncFunctions`** — callbacks dispatched via `resumeAsFuture`;
  Python can `await` them and `asyncio.gather` runs them concurrently.
- **`MontyInternalError`** — new `MontyError` subtype for interpreter-internal
  failures.
- **`MontyNone` literal** — `feedRun('None')` now returns `MontyNone`.

## 0.17.0

Re-cut release: align versioning with `dart_monty`. Supersedes the
retracted `0.0.17` (which omitted `native/src/bin/oracle.rs` from
the published archive, breaking the build hook for consumers).

## 0.0.17

Initial release.
