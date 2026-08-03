# VFS rework — phase checklist

Execution checklist for the VFS rework. Design and rationale live in
`~/dev/plans/monty-0.19-upgrade/vfs-design.md`; this file is the part you tick
off, and it is deliberately machine-checkable.

Branch: `feat/vfs-019`.

## The two commands

```bash
bash tool/check_vfs_regression.sh   # inner loop, seconds — did I break what worked?
bash tool/gate.sh                   # commit gate, 23 steps — read EXIT CODE and VERDICT LINE
```

`check_vfs_regression.sh` is *not* a substitute for the gate: it drives the FFI
handler only. The gate covers dart2js and dart2wasm, the corpus, the demo, DCM
and format.

## Standing rules for every phase

- [ ] Write the failing test FIRST and look at the red output before implementing.
- [ ] `check_vfs_regression.sh` exits 0 — the four must-stay-green fixtures still pass.
- [ ] `bash tool/gate.sh` green: read the **exit code** *and* the verdict line, never
      the tail of the summary.
- [ ] Unit tests are `unit`-tagged, so `unit_web` runs them on VM + dart2js +
      dart2wasm. Backend parity is enforced by the gate, not by memory.
- [ ] Stage explicit paths — never `git add -A`.
- [ ] Verify the commit's contents match its message before pushing.
- [ ] No `Co-Authored-By` trailer, no "Generated with" footer.

## Baseline at branch point (`ad76cae`)

```
MUST STAY GREEN   open__fs.py (649 lines) · with__all.py
                  pathlib__pure.py · open__fs_windows.py
TARGETS (red)     mount_fs__ops.py · mount_fs__errors.py
```

---

## Phase 1a — public API only, behaviour-preserving

Split out so the ~69 call sites move **exactly once**. Nothing about behaviour
changes here, so a red result can only be a migration slip.

- [x] `MontyMemoryFile` + a `files:` constructor, mirroring upstream's
      `OSAccess([MemoryFile(...)])`
- [x] Content is a sealed ADT — `VfsText | VfsBytes` with polymorphic
      `byteLength`, `late final` cached so `stat()` is not O(n)
- [x] All call sites migrated
- [x] Old `vfs:` map parameter and `vfsText` removed (no backwards compatibility)
- [x] regression script green · gate green

Two things settled while doing it, both worth carrying into 1b:

- **Writes mutate the caller's file in place.** Upstream's `_write_file`
  (`os_access.py:955-970`) calls `entry.write_content(data)` rather than
  replacing the node, and `MemoryFile`'s own docstring states the contract:
  *"When Monty code writes to this file, the content attribute is updated"*
  (`os_access.py:606-607`). So a caller who seeds `MontyMemoryFile('/out.txt',
  '')` and reads `.content` back afterwards is using the API as designed, not
  working around a missing one. `VfsText`/`VfsBytes` have value equality so that
  assertion reads `expect(file.content, VfsText('…'))`.
- **No store-observation API was added, on purpose.** A caller cannot see a file
  Monty created that they did not seed — and neither can an upstream caller.
  Unit tests that used to assert `vfs.containsKey(...)` now assert through
  `Path.exists` / `Path.read_text`, which is both a contract-level assertion and
  the reason they will not need touching again when 1b swaps the flat map for a
  tree.

## Phase 1b — tree interior + `open()`'s closures, SAME COMMIT

- [x] `sealed class VfsNode` → `VfsDir(Map<String, VfsNode>)` | `VfsFile`;
      composition, so "closed set of node kinds" and "open set of content
      backings" stay separate axes
- [x] Lookup walks components and returns `null` when an intermediate is a
      **file** — that is where `ENOTDIR` comes from
- [x] **`open()`'s injected `isDirectory` closure updated in this commit.**
- [x] Every write routes through ONE `putContent`, which calls
      `requireParentDir` — the check reverted in `11bd4a8`, correct all along
      and only unsafe while `mkdir` had nowhere to record a directory. Its test
      is un-skipped.
- [x] Do **not** add a `deleted` flag yet — upstream's lookup ignores it; it is
      an overlay concern (Phase 6)
- [x] Empty directories exist; `mkdir`-then-write works; `exists`/`is_dir` true
      after `mkdir`
- [x] Seeding auto-creates parents; `/a.txt` + `/a.txt/b.txt` is an
      `ArgumentError` at construction (`os_access.py:837-838`)
- [x] Mount roots are seeded as directories, so `_isMountRoot` stops being a
      special case in every existence question
- [x] regression script green · gate green

### The trap sprang — in the direction not predicted

The checklist warned that leaving `isDirectory` stale would make `open__fs.py`
pass on old semantics. What actually happened was the mirror image, and only the
regression harness caught it.

`resolveOpenCall` had the two read-mode checks **nested**:

```dart
if (!exists(path)) {
  if (isDirectory(path)) throw IsADirectoryError;
  throw FileNotFoundError;
}
```

That is only correct while `exists` means *"a file is here"* — which is what the
flat map's `containsKey` meant. With a tree, a directory answers `true` to
`exists`, so the whole block was skipped and `open('/mnt', 'r')` returned a
handle instead of raising. Upstream states them as one sentence — "verify the
file exists **and** is not a directory" (`os_access.py:851-853`) — i.e. two
independent checks. `open_call.dart` now does that, and its doc says explicitly
that `exists` means "a node is here", not "a file is here".

The lesson generalises past this phase: **a store swap silently changes what
every injected predicate means.** Grep for the predicates, not just the store.

### Where the two targets stand now

Both moved deeper, which is the useful signal — neither is blocked on the store
any more:

```
mount_fs__ops.py     write_text emoji returns char count not byte count: 2   -> Phase 3.2
mount_fs__errors.py  expected FileNotFoundError on iterdir nonexistent       -> Phase 2
```

## Phase 1c — `IsADirectoryError` on writes

The P0: writing to a directory **succeeded and destroyed the directory entry**.
Silent data loss, not a wrong message — `putContent` saw the existing node was
not a `VfsFile` and replaced it, taking every file beneath it along.

- [x] `read_text`/`read_bytes`/`write_text`/`write_bytes`/`append_text`/
      `append_bytes` on a directory raise `[Errno 21] Is a directory: '<path>'`
- [x] `open(dir, 'w')` too — it routes through `truncate` → `putContent`, so
      one guard covers it
- [x] Reinstated the write parent-dir check reverted in `11bd4a8` and un-skipped
      its test (done in 1b, once directories became real)
- [x] regression script green · gate green

Implemented as **one guard at the store boundary**, `refuseDirectory`, rather
than a check per operation — eight call sites cannot drift apart if they share
the guard. Reads go through `requireFile`, which distinguishes *is a directory*
from *is not there*: reporting a directory as missing is wrong twice, because
the path plainly exists and a caller told a file is absent will try to create
it.

## Phase 2 — directory-aware policy

- [x] `iterdir` → `FileNotFoundError` when missing, `NotADirectoryError` on a
      file. It previously returned an EMPTY LIST for a missing path, which is
      the worst of the three answers: indistinguishable from a successful
      listing of an empty directory.
- [x] `rmdir` distinguishes absent / empty / non-empty
- [x] `unlink` of a directory → `IsADirectoryError`
- [x] `mkdir` on an existing directory says `[Errno 17] File exists: '<path>'`.
      CPython uses ONE message for "a file is there" and "a directory is
      there"; we had invented `Directory exists: <path>` for the second.
- [x] regression script green · gate green

`mount_fs__errors.py` walked forward three assertions during this phase and now
stops at `Rename target already exists: /mnt/rename_dst_dir` — Phase 3.3.

## Phase 3 — remaining CPython semantics · RELEASE MILESTONE

- [x] `resolve`/`absolute` return `MontyPath`, and **normalise `..`**
      (upstream's Python host does not, and its comment wrongly claims it does).
      They returned a bare `String`, so Python got a `str` and `.name` on the
      result raised `AttributeError`.
- [x] `write_text`/`append_text` return **codepoints**, not UTF-16 units.
      Three lengths are in play and they agree only for ASCII, which is why
      this hid: codepoints (`write_text`), UTF-8 bytes (`st_size`), and Dart's
      `String.length`, which is UTF-16 code units and is neither.
- [x] `rename`: file→dir `IsADirectoryError`, dir→file `NotADirectoryError`,
      dir→non-empty `[Errno 39]`, dir→**empty** dir succeeds, and
      **file→existing file OVERWRITES silently** — the one that looks like a
      bug and is not. Descendant path rewrite landed in 1b.
- [x] Errno 39 for both rmdir and rename (upstream's 66 is macOS's ENOTEMPTY,
      an inconsistency they snapshotted)
- [x] `Errno 36`: >255-**byte** component, >4096-**byte** total; applied to
      read/write/append/stat/mkdir/open but **NOT** to
      `exists`/`is_file`/`is_dir`/`is_symlink`, which swallow it and return
      False. Checked before the store is consulted, since it is a property of
      the path rather than of what is there.
- [x] `mkdir(parents=True)` through a FILE raises `NotADirectoryError` instead
      of leaking the tree's `StateError` as `RuntimeError: Bad state:`
- [x] **`mount_fs__ops.py` and `mount_fs__errors.py` GREEN** — the demo's last
      two red rows
- [x] regression script green · gate green

### On `package:path`

Asked during this phase: does Dart have a first-class `Path`? No, and not by
oversight — `package:path` is functions over `String` by design, `dart:io`'s
pre-1.0 `Path` was removed, and `MontyPath` here is a *wire value* that tells
the interpreter "this is a `pathlib.Path`, not a `str`", not a path library.

`_normalizePath` stays hand-rolled on purpose, and the reason is recorded at
the function. It is a **clamp**, not a normaliser: `p.posix.normalize`
preserves a leading `..` (`../escape.txt` → `../escape.txt`) because that is
what POSIX means, which would hand a non-rooted string to the mount check.

## Phase 4 — converge the duplicate

- [x] `wasm_runner.dart` uses the shipped handler; its private ~400-line
      `_VirtualFs` deleted
- [x] `bash tool/test_cm_wasm.sh` still reports **527/531, 0 failures** — that is
      the equivalence proof
- [x] regression script green · gate green

### It was not one duplicate, it was five

The checklist named `_VirtualFs`. Deleting only that would have left the two
runners at ~800 duplicated lines each, so the next drift had somewhere to
happen. `wasm_runner.dart` and `wasm_runner_wasm.dart` also each carried their
own copy of the corpus loop, the dispatch loop, the expectation evaluator and
the name-lookup constants — and the copies had **already** drifted:

- the `MontyOsCall` and `MontyResolveFutures` arms sat in opposite orders
- the dart2wasm twin emitted a `"ms"` field its sibling did not
- `_nameConstants` was a third copy of `conformanceNameConstants`
- `tool/check_vfs_regression.sh` held a third mount-fs seed, writing `data.bin`
  as the Dart STRING `'\x00\x01\x02\x03'` where upstream writes the BYTES
  `b'\x00\x01\x02\x03'` — equal only because U+0000..U+0003 are single-byte in
  UTF-8, and wrong the moment a byte above 0x7F appears

The whole body now lives in `monty_conformance/src/fixture_runner.dart`. Both
runners are ~40 lines: a header and `main() => runFixtureCorpus(log: …)`. The
logging shim is the only thing either file may legitimately own.

`"ms"` was dropped rather than added to both: nothing parses it, the documented
protocol in `tool/test_wasm.sh` does not include it, and a timing field makes
the `FIXTURE_DONE` line differ run to run, which is exactly what the
equivalence check compares.

### No local script builds the dart2wasm twin

Worth knowing before trusting a green local run: `tool/test_wasm.sh` and
`tool/test_cm_wasm.sh` both compile `wasm_runner.dart` with `dart compile js`,
despite the names. `wasm_runner_wasm.dart` is compiled **only** by CI
(`.github/workflows/ci.yaml:583`). That asymmetry is the FB-10 mechanism
itself — the backend nobody runs locally is the one that ships broken — and it
is why the equivalence proof below was taken on both targets by hand.

### The proof

Per-fixture, not just the summary counts: all 519 `FIXTURE_RESULT` lines are
byte-identical before and after, on dart2js AND dart2wasm, and the two backends
now produce identical output as each other.

```
tool/test_cm_wasm.sh        before & after  {"total":531,"passed":527,"failed":0,"skipped":4}
tool/test_wasm.sh --skip-build  before & after  {"total":531,"passed":519,"failed":0,"skipped":12}
```

Ten fixtures actually exercise the OS path and every one of them passes on both
sides of the change: `mount_fs__ops`, `mount_fs__errors`, `open__fs`,
`open__fs_windows`, `with__all` (mount-fs, `/mnt`), and `datetime__core`,
`import__os`, `os__environ`, `pathlib__os`, `pathlib__os_read_error`
(call-external, `/virtual`). The 12 skips are unchanged and none is a
filesystem fixture.
- [x] `bash tool/test_cm_wasm.sh` **and** `bash tool/test_cm_wasm.sh --dart2wasm`
      still report **528/531, 0 failures, 3 skipped** — that is the equivalence
      proof. Confirmed in gate `20260803T042142Z`, both steps, identical.
      Run both: the dart2js half alone was the proof until 2026-08-03, and
      the eight test-hooks fixtures had never executed on dart2wasm at all.
      Both are gate steps now (`corpus_cm_js`, `corpus_cm_w`) AND a CI job
      (`test-hooks-corpus`), which pins the expected line rather than trusting
      an exit code — `test_cm_wasm.sh:222` exits 0 when Chrome is missing.
- [x] regression script green · gate green

## Phase 5 — host-reaching files · reviewed, shipped

- [x] `VfsCallbackFile` in a **separate library**
      (`package:dart_monty_core/unsafe_callback_file.dart`), so importing it is
      an affirmative act visible in review
- [x] ~~The default entry point cannot accept one without that import~~
      **DELETED — the guarantee does not exist.** See below.
- [x] Upstream's warning repeated verbatim (`os_access.py:684-706`, Python
      example translated to Dart)
- [x] Own branch, own review
- [x] The callback receives the **seeded** path, never the live one
- [x] regression script green · gate green

### Box 2 was never true, and deleting it is the point

The box asked for something Dart cannot express, and — worse — for a property
this library never had.

Not expressible: `VfsFile` is an `abstract interface class` (`vfs_node.dart:37`)
and the entry point takes `List<VfsFile>` (`memory_mounted_os_handler.dart:64`),
so any `VfsFile` satisfies it. The import gates **construction**, not
**passing**.

Never true, which is the part that matters. **A host-reaching `VfsFile` is
constructible today from the shipped public API, with no Phase 5 code and no
special import.** Measured: a separate package with a path dependency,
importing only `package:dart_monty_core/dart_monty_core.dart`, ~20 lines —

```dart
class HostFile implements VfsFile {
  @override
  VfsContent get content => VfsText(File(hostPath).readAsStringSync());
  // …path, permissions
}
```

— analysed clean and read host content out through `Path.read_text`.

So a checkbox promising the entry point *cannot* accept an unsafe file would
teach a reviewer that the `files:` list needs no scrutiny, which is exactly
backwards. A guarantee you advertise but cannot enforce is worse than none,
because it displaces the manual control doing the real work.

**The honest rule, which replaces the box: audit every `VfsFile` that is not a
`MontyMemoryFile`.** `unsafe_callback_file.dart` makes the common case
greppable; it does not make the unlabelled route unavailable.

Reviewed adversarially by two model families independently (Gemini 3.6 and
Claude), both of which killed the alternative designs — a sealed marker
supertype, a runtime whitelist, and a declared `reachesHost` bit on the
interface. Full disposition ledger:
`~/dev/plans/monty-0.19-upgrade/artifacts/phase5/LEDGER.md`.

### Why the callback gets the seeded path

A rename rewrites the live `path` of every file in the moved subtree
(`vfs_tree.dart:168`). Handing that to the callback would let sandboxed Python
choose the argument the host receives, just by renaming inside the mount —
demonstrated red before the fix, in `vfs_callback_file_test.dart`. Upstream has
the same exposure via directory rename (`os_access.py:1128-1136`); we had it via
file rename too, because our `move()` rewrites both.

`VfsCallbackFile` freezes `seededPath` at construction and hands the callback
that. `path` still tracks the tree, so `resolve` and `iterdir` stay correct.

Two bounds worth recording, both measured: sandboxed code **cannot leave the
mount** (the clamp at `vfs_path.dart` plus "outside a mount means absent"), and
**cannot mint a callback file** — every file Monty creates is a
`MontyMemoryFile` (`vfs_tree.dart:126`, mirroring `os_access.py:967`).

## §6c — port upstream's `OSAccess` suite · done

The 531-fixture corpus is not the only spec. `test_os_access.py` pins
directory and mode semantics no fixture reaches, and the design doc flagged it
as worth mining. It was, immediately:

- [x] `iterdir` of an **empty** directory lists as empty and does not raise —
      distinct from a missing path, which does
- [x] `append_text` returns **characters** where `append_bytes` returns
      **bytes**: `'αβγ'` is 3 and 6, so the two calls must disagree
- [x] root is a directory, lists its children, and is not a file
- [x] **`open()` rejects a malformed mode before any side effect** — this one
      found a live defect, see below
- [x] regression script green · gate green

### The defect it found

`resolveOpenCall` string-compared the mode and sent *everything* unrecognised
to `createIfMissing`, so `open(p, 'wxyz')`, `open(p, 'x')` and `open(p, '')`
silently created a file instead of raising. `open_call.dart` is exported, so a
direct caller reached it. Upstream's own test for this is a named data-loss
regression guard (`os_access.py:870-876`).

The fix parses the mode first. That also made `b`/`t`/`+` orthogonal to the
action, as upstream has them — `r+` is a *read* action and no longer creates.

## Phase 6 — deferred, and deliberately so

Neither item is "not done yet"; both are decisions already taken.

- [ ] **overlay mode + `deleted` tombstones** — "only if a consumer needs it",
      and the VFS API currently has **no downstream consumer at all**
      (measured: zero hits for `VfsFile`/`memoryMountedOsHandler` across
      `dart_monty`, `dart_monty_labs` and every `soliplex*` repo). Building it
      now would be speculative.
- [ ] **boundary-enforced host mounts** (`MountDir.hostPath` + a Dart
      `path_security`) — **settled against.** A solo-maintained Dart
      re-derivation of upstream's Rust boundary module, tested against one
      person's adversarial imagination, is more dangerous than a callback the
      consumer deliberately wrote. Challenged in review and the objection was
      withdrawn.

## Open decisions (owner, not implementer)

- [ ] **Per-feed or persistent writes?** 0.19 discards overlay writes at feed
      end; ours persist. A consumer porting from `pydantic_monty` will assume
      upstream's.
- [ ] **Per-mount memory budget?** Without one, `write_bytes` in a loop can
      exhaust host memory — `writeBytesLimit` caps a single write, not the total.
- [ ] Is the store type public API?
