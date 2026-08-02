# VFS rework — phase checklist

Execution checklist for the VFS rework. Design and rationale live in
`~/dev/plans/monty-0.19-upgrade/vfs-design.md`; this file is the part you tick
off, and it is deliberately machine-checkable.

Branch: `feat/vfs-019`.

## The two commands

```bash
bash tool/check_vfs_regression.sh   # inner loop, seconds — did I break what worked?
bash tool/gate.sh                   # commit gate, 22 steps — read EXIT CODE and VERDICT LINE
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

- [ ] `MontyMemoryFile` + a `files:` constructor, mirroring upstream's
      `OSAccess([MemoryFile(...)])`
- [ ] Content is a sealed ADT — `TextContent | BytesContent` with polymorphic
      `byteLength`, `late final` cached so `stat()` is not O(n)
- [ ] All ~69 call sites migrated
- [ ] Old `vfs:` map parameter and `vfsText` removed (no backwards compatibility)
- [ ] regression script green · gate green

## Phase 1b — tree interior + `open()`'s closures, SAME COMMIT

- [ ] `sealed class VfsNode` → `VfsDir(Map<String, VfsNode>)` | `VfsFile(AbstractFile)`;
      composition, so "closed set of node kinds" and "open set of content
      backings" stay separate axes
- [ ] Lookup walks components and returns `null` when an intermediate is a
      **file** — that is where `ENOTDIR` comes from
- [ ] **`open()`'s injected `isDirectory` closure updated in this commit.**
      Otherwise the 649-line `open__fs.py` passes with stale semantics — a false
      green, worse than a red
- [ ] Every write routes through ONE `_writeFile`
- [ ] Do **not** add a `deleted` flag yet — upstream's lookup ignores it; it is
      an overlay concern (Phase 6)
- [ ] Empty directories exist; `mkdir`-then-write works; `exists`/`is_dir` true
      after `mkdir`
- [ ] regression script green · gate green

## Phase 1c — `IsADirectoryError` on writes

The P0: writing to a directory currently **succeeds and destroys the directory
entry**. Silent data loss, not a wrong message.

- [ ] `read_text`/`read_bytes`/`write_text`/`write_bytes` on a directory raise
      `[Errno 21] Is a directory: '<path>'`
- [ ] Reinstate the write parent-dir check reverted in `11bd4a8`, and un-skip
      its test
- [ ] regression script green · gate green

## Phase 2 — directory-aware policy

- [ ] `iterdir` → `FileNotFoundError` when missing, `NotADirectoryError` on a file
- [ ] `rmdir` distinguishes absent / empty / non-empty
- [ ] `unlink` of a directory → `IsADirectoryError`
- [ ] regression script green · gate green

## Phase 3 — remaining CPython semantics · RELEASE MILESTONE

- [ ] `resolve`/`absolute` return `MontyPath`, and **normalise `..`**
      (upstream's Python host does not, and its comment wrongly claims it does)
- [ ] `write_text` returns **codepoints**, not UTF-16 units
- [ ] `rename`: four paths — file→dir `IsADirectoryError`, dir→file
      `NotADirectoryError`, dir→non-empty ENOTEMPTY, **file→existing file
      OVERWRITES**; plus descendant path rewrite
- [ ] Errno 39 for both rmdir and rename (upstream's 66 is an inconsistency they
      snapshotted)
- [ ] `Errno 36`: >255-**byte** component, >4096-**byte** total; applied to
      read/write/append/stat/mkdir/open but **NOT** to
      `exists`/`is_file`/`is_dir`, which swallow it and return False
- [ ] **`mount_fs__ops.py` and `mount_fs__errors.py` GREEN** — the demo's last
      two red rows
- [ ] regression script green · gate green

## Phase 4 — converge the duplicate

- [ ] `wasm_runner.dart` uses the shipped handler; its private ~400-line
      `_VirtualFs` deleted
- [ ] `bash tool/test_cm_wasm.sh` still reports **527/531, 0 failures** — that is
      the equivalence proof
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
