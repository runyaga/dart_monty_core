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

- [ ] `wasm_runner.dart` uses the shipped handler; its private ~400-line
      `_VirtualFs` deleted
- [ ] `bash tool/test_cm_wasm.sh` **and** `bash tool/test_cm_wasm.sh --dart2wasm`
      still report **528/531, 0 failures, 3 skipped** — that is the equivalence
      proof. Run both: the dart2js half alone was the proof until 2026-08-03,
      and the eight test-hooks fixtures had never executed on dart2wasm at all.
- [ ] regression script green · gate green

## Phase 5 — FFI local files · STOP, needs review

**Do not automate.** A sandbox-escape surface.

- [ ] `VfsCallbackFile` in a **separate library**, so importing it is an
      affirmative act visible in review
- [ ] The default entry point cannot accept one without that import
- [ ] Upstream's warning repeated verbatim
- [ ] Own branch, own review

## Phase 6 — deferred

- [ ] overlay mode + `deleted` tombstones
- [ ] boundary-enforced host mounts (`MountDir.hostPath` + a Dart
      `path_security`) — own branch, own adversarial suite

## Open decisions (owner, not implementer)

- [ ] **Per-feed or persistent writes?** 0.19 discards overlay writes at feed
      end; ours persist. A consumer porting from `pydantic_monty` will assume
      upstream's.
- [ ] **Per-mount memory budget?** Without one, `write_bytes` in a loop can
      exhaust host memory — `writeBytesLimit` caps a single write, not the total.
- [ ] Is the store type public API?
