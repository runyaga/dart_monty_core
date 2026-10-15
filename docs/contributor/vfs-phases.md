# VFS design record

The design record for the in-memory filesystem behind
`memoryMountedOsHandler` (`lib/src/mount/`): what was decided, what was
settled against, and why. The arguments worth keeping are consolidated in
"Why this shape" at the bottom.

The handler is an `OsHandler`: it answers the OS calls a session makes
(`Path.read_text`, `open()`, `Path.iterdir`, ...) from a tree of `VfsFile`s
under declared `MountDir`s. A call for a path outside every mount goes to its
`fallthrough` handler, or, with none, finds the path absent
(`FileNotFoundError`).

```bash
dart test test/unit/mount                # the handler and the tree
bash tool/gate.sh                         # commit gate: read EXIT CODE and VERDICT LINE
```

## Host-reaching files

- [x] `VfsCallbackFile` in a **separate library**
      (`package:dart_monty_core/unsafe_callback_file.dart`), so importing it is
      an affirmative act visible in review
- [x] ~~The default entry point cannot accept one without that import~~
      **DELETED — the guarantee does not exist.** See below.
- [x] Upstream's warning repeated verbatim (`os_access.py:684-706`, Python
      example translated to Dart)
- [x] Own branch, own review
- [x] The callback receives the **seeded** path, never the live one

### Box 2 was never true, and deleting it is the point

The box asked for something Dart cannot express, and — worse — for a property
this library never had.

Not expressible: `VfsFile` is an `abstract interface class` (`vfs_node.dart:37`)
and the entry point takes `List<VfsFile>` (`memory_mounted_os_handler.dart:85`),
so any `VfsFile` satisfies it. The import gates **construction**, not
**passing**.

Never true, which is the part that matters. **A host-reaching `VfsFile` is
constructible today from the shipped public API, with no `unsafe_callback_file.dart`
import.** Measured: a separate package with a path dependency,
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
interface.

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

## Upstream's `OSAccess` suite, ported

The upstream corpus is not the only spec. `test_os_access.py` pins
directory and mode semantics no fixture reaches, and the design doc flagged it
as worth mining. It was, immediately:

- [x] `iterdir` of an **empty** directory lists as empty and does not raise —
      distinct from a missing path, which does
- [x] `append_text` returns **characters** where `append_bytes` returns
      **bytes**: `'αβγ'` is 3 and 6, so the two calls must disagree
- [x] root is a directory, lists its children, and is not a file
- [x] **`open()` rejects a malformed mode before any side effect** — this one
      found a live defect, see below

### The defect it found

`resolveOpenCall` string-compared the mode and sent *everything* unrecognised
to `createIfMissing`, so `open(p, 'wxyz')`, `open(p, 'x')` and `open(p, '')`
silently created a file instead of raising. `open_call.dart` is exported, so a
direct caller reached it. Upstream's own test for this is a named data-loss
regression guard (`os_access.py:870-876`).

The fix parses the mode first. That also made `b`/`t`/`+` orthogonal to the
action, as upstream has them — `r+` is a *read* action and no longer creates.

## Deferred, and deliberately so

Neither item is "not done yet"; both are decisions already taken.

- [x] ~~**overlay mode + `deleted` tombstones**~~ — **SETTLED AGAINST, and the
      two were wrongly bundled.** Bundling them made the feature look ~4× more
      expensive than its useful part, which hid the real answer.

      Upstream's overlay separates into three independent ingredients, and only
      the first is intrinsically about a host directory:

      1. an **immutable lower layer** — the one property we genuinely lack;
      2. an **in-memory upper layer with tombstones** — needed *only because
         upstream cannot unlink a host file*. We can delete from our tree, so
         tombstones are a consequence of (1), not of overlay;
      3. **discard at feed end** — **already reachable today.** `os` is a
         per-feed parameter of `feedRun`, so a fresh handler over fresh files reproduces
         upstream's overlay observable exactly, with no new API.

      Two measurements decided it. Both of upstream's own
      `OverlayMemory`-generated `mount_fs` fixtures pass green against our
      `readWrite` tree — within one feed, over a mount with nothing underneath,
      overlay and read-write are **observationally identical**, which is why the
      missing mode has never shown up. And `overlay.rs` is 1221 lines that exist
      to reconcile a *real directory* with an in-memory diff; we have no real
      directory, so porting the diff machinery would be building the expensive
      half of a feature whose cheap half already works.

      It is also a **lifetime, not a mode**: `MountDir` is a `const` value object
      while the thing being scoped is mutable per-feed state. Upstream gets away
      with `OverlayMemory(OverlayState)` only because Rust enums carry payloads
      and its `Mount` is rebuilt per feed.

      If a consumer ever needs an immutable lower layer, the variant to build is
      **`fallthrough` as the lower layer** — its "host" is a consumer-written
      callback, which is *consistent with* the host-mount decision below rather
      than a reversal of it. Note it would re-scope an existing public
      parameter: `fallthrough` is consulted today only for paths outside every
      mount, never for a path inside one that is merely absent.
- [ ] **boundary-enforced host mounts** (`MountDir.hostPath` + a Dart
      `path_security`) — **settled against.** A solo-maintained Dart
      re-derivation of upstream's Rust boundary module, tested against one
      person's adversarial imagination, is more dangerous than a callback the
      consumer deliberately wrote. Challenged in review and the objection was
      withdrawn.

## Owner decisions — all three CLOSED

- [x] **Per-feed or persistent writes?** **Not actually open — it named the
      wrong host.** The per-feed discard belongs to `MountDir(mode='overlay')`
      (`_monty.pyi:110`), the Rust/pool path, where a real host directory is the
      durable thing and the overlay is scratch. We have no overlay and no host
      directory: our tree *is* the filesystem, so "discard at feed end" would
      either erase what the consumer seeded or erase writes while seeds survive.
      The host we mirror is Python `OSAccess`, and it **persists** — *"When
      Monty code writes to this file, the content attribute is updated"*
      (`os_access.py:608`), which is what the handler implements. A consumer
      porting from `pydantic_monty` assumes persistence and gets it. Revisit
      only if overlay mode lands, which is when we would need a feed
      boundary we do not currently model.
- [x] **Per-mount memory budget?** Shipped. And the framing understated it: our
      `writeBytesLimit` had upstream's *name* with per-write semantics, which
      bounds nothing — measured, a 100-byte cap let all ten of ten 30-byte
      writes through. Now cumulative, plus `memoryUsageLimit` at upstream's
      100 MB default.
- [x] **Is the store type public API?** **No — `VfsTree` stays internal.** The
      question as originally posed asked about a `VfsStore` that the design doc
      had already deleted in favour of per-file backing, and named a
      `hostMountedOsHandler` that was settled against. On the live version:
      1. **The decision is not symmetric.** Adding an export later is additive;
         removing one is breaking. Zero consumers makes this the cheapest moment
         to decide the *reversible* direction, not either direction.
      2. **Exporting it is a half-kit.** `OsHandler` is a bare typedef and
         `resolveOpenCall` is exported and store-agnostic by design
         (`open_call.dart:10-12`), so a consumer *can* author a working
         tree-backed handler — verified by probe — but with no mount matching,
         no `MountMode`, no accounting, and **no path clamp**, because
         `normalizeVfsPath` and `VfsAccountant` are unexported. It ships the
         part that makes a wrong handler easy and withholds what a right one
         needs.
      3. **The engine passes `..` through verbatim.** Probed:
         `ENGINE PASSED: Path.read_text /data/../../etc/passwd` — it collapses
         `.` only. Our clamp is load-bearing, not belt-and-braces.
      4. ~~**Overlay mode changes `lookup`.** The `deleted` flag goes on the node, so
         publishing `lookup` now turns a planned internal change into a breaking
         one.~~ **STRUCK — the premise was not upstream's shape.** Upstream's
         tombstone is a **peer variant in a flat, per-feed map** (`Deleted`
         alongside `File`/`RealFileRef`/`Directory`, `overlay_state.rs:207-223`),
         not a bool on a tree node — and a bool on `VfsFile` could not express a
         tombstoned *directory*, which `rmdir` needs (`overlay.rs:705`). Under a
         Rust-shaped design the tombstone lives beside `VfsTree`, the merge
         happens in the handler, and `lookup` does not change at all. The
         decision to keep `VfsTree` internal stands on 1–3; 2 was always the
         strong one.
      If this is ever reversed, the minimum bill is: mark it `final class` (it
      currently has no modifier, so exporting publishes ten *overridable*
      methods), export `normalizeVfsPath` with a note about `..`, and say in the
      class doc that the tree is a data structure and **not** a policy boundary.

## Why this shape — the durable arguments

Consolidated from the deleted design doc. These are the arguments that would
otherwise get re-litigated.

**Upstream wrote both candidate designs and shipped the tree.** Its repo
contains two managed hosts: `OSAccess`, a recursive `dict[str, File | Tree]`
(`os_access.py:591`), shipped in production; and `TestOS`, a
`dict[str, bytes]` **plus** a `set[str]`, which exists only as a test fixture
(`test_os_access_raw.py:26-27`). An earlier draft of our design proposed the
`TestOS` model. Compare one operation — `TestOS.path_iterdir` needs two scans
and a dedupe over two collections, while `OSAccess.path_iterdir` is one line
(`os_access.py:1019`). The tree wins on three concrete grounds, not aesthetics: one
source of truth, so a path in both collections or a file whose parent is missing
from the dir set is unrepresentable; every operation needs a three-way answer
(file / dir / missing) which the tree gives structurally; and empty directories
exist for free.

**The platform split is per-FILE, not per-store.** Web supplies only in-memory
files; a host-reaching backing is one more `VfsFile` implementation. One store,
one tree, one code path — the difference is which file objects are in it. This
is why there is no `VfsStore` abstraction and why `VfsFile` is an open interface
while `VfsNode` is sealed: the set of node *kinds* is closed, the set of content
*backings* is not.

**Do not reimplement `path_security.rs` in Dart.** Upstream calls it their sole
security boundary. A solo-maintained Dart re-derivation, tested against one
person's adversarial imagination, is more dangerous than a callback the consumer
deliberately wrote. Challenged in adversarial review; the objection was
withdrawn.

**The corpus is not the only spec.** Upstream's Python binding has four test
files covering behaviour no fixture reaches, and mining them found a live
data-loss defect (see "Upstream's `OSAccess` suite, ported"):

| file | what it pins |
|---|---|
| `tests/test_os_access.py` | the `OSAccess` behaviour spec — empty dirs, the mkdir matrix, `IsADirectoryError` sites, `open()` modes, return-value units |
| `tests/test_os_access_raw.py` | the raw callback protocol, `NOT_HANDLED` fallthrough, and the `TestOS` model upstream did not ship |
| `tests/test_os_calls.py` | the bare callback contract and mkdir kwarg marshalling |
| `tests/test_mount_table.py` | mount semantics, incl. `resolve()` normalising `..` |

**A store swap silently changes what every injected predicate means.** The
lesson from moving the store from a flat map to the tree, worth carrying forward: grep for the *predicates*, not
just the store. `exists` meant "a file is here" under a flat map and "a node is
here" under a tree, and one nested `if` was wrong for a week because of it.
