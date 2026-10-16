# Host directory mounts

`MountDir` maps an opened native host directory to a virtual path. It is
exported by `dart_monty_core.dart`. Memory filesystems use `OSAccess`;
`MountDir` serves real directories through upstream `monty-fs` 1.1.0.

```dart
final data = MountDir(
  hostPath: '/host/project/data',
  virtualPath: '/data',
  mode: 'overlay',
  writeBytesLimit: 1000000,
  memoryUsageLimit: 100000000,
);
try {
  await session.feedRun("open('input.txt').read()", mount: [data]);
} finally {
  data.close();
}
```

## Construction and lifetime

Construction opens the directory immediately. `hostPath` reports its canonical
path; `virtualPath` is normalized and must be absolute. The capability follows
the opened directory even if the host renames it. `close()` is idempotent and
keeps the fields readable. A native finalizer releases abandoned capabilities;
explicit close provides deterministic cleanup.

The modes are the strings `'overlay'` (default), `'read-only'`, and
`'read-write'`. Overlay changes live in one feed and disappear when it ends.
Read-only mounts reject mutations with Python `PermissionError` (errno 30).
Read-write changes persist on the host. `writeBytesLimit` is cumulative per
feed; null means unlimited. `memoryUsageLimit` defaults to 100,000,000 bytes
and covers retained overlay data and transient reads and listings in every
mode. Exceeding these budgets raises Python `OSError` and `MemoryError`,
respectively. No usage counters are exposed.

A nonempty `mount: List<MountDir>` creates a fresh table for each feed. The
same mount may be reused by multiple feeds and sessions. Closing a mount
prevents new tables from using it; an already-running feed retains its root.
The table is released on completion, error or crash, including terminal
automatic-resume failures before another worker turn. An abandoned table also
has a native finalizer backstop, including on isolate shutdown; normal feed
cleanup closes it immediately and detaches that finalizer. `mount: []` behaves
like an omitted mount list.

## Routing, snapshots and cwd

For filesystem calls, the feed tries its mounts, then `os:`, then the worker's
default. A mounted path stays handled even when the file does not exist.
An unhandled filesystem call defaults to `PermissionError`; other unhandled
OS calls default to `RuntimeError`.

Nested virtual prefixes select the longest match, provided the host roots
are disjoint. Duplicate virtual paths and overlapping host directories fail
before Feed with `MontyRuntimeError(ValueError)`. A closed mount fails before
Feed with `StateError`. Both leave the session usable.

Rename validates both paths even when the source is unmounted. Destination
length validation precedes its NUL check. Invalid paths are handled errors;
they do not fall through to `os:`. Two unmounted valid paths may fall through.
Exactly one mounted path, or paths in different mounts, raises `OSError`
(errno 18). Mount-relative traversal cannot escape the directory capability;
absolute symlink targets are refused, including targets back inside the root.
These rules are enforced by upstream `monty-fs`, not a Dart path-security port.

`feedStart` retains the table across suspensions. `FunctionSnapshot.resumeAuto()`
consults it and the captured `os:` handler; `resume(result)` supplies the answer
directly, and `resumeNotHandled()` invokes the worker default. `feedStart`
surfaces both system sleep kinds, so `resumeAuto()` can route them through
`os:`. `feedRun` keeps automatic system sleep handling.

Dumps contain no mounts or overlay data. `loadSnapshot(state, mount: [data])`
starts a fresh table and overlay while preserving the saved cwd. Restoring
without mounts routes filesystem calls through the supplied `os:` or default.
`loadSession` also preserves the saved cwd. A later first mount cannot replace
that restored directory.

Until cwd is established, an omitted cwd chooses the first mount's virtual
path, or `/` without mounts. A sent feed establishes it unless type checking
rejects that feed. Sent syntax/runtime errors establish it; typing rejection
and pre-send validation errors do not. Once established, omitted cwd preserves
the worker's current directory. Explicit cwd validation happens before
mount-table construction, so invalid cwd wins over overlap, sends no Feed,
and preserves default eligibility. `FakeMontySession` shares this host-side
state machine and mount dispatch for scripted events; it does not evaluate
Python or implement real session serialization.

## Platforms and discovery

The class and session signatures compile on every backend. Constructing a
mount on dart2js or dart2wasm throws `UnsupportedError`: browsers provide no
host directory capability. `OSAccess` remains available on those backends.

On native, library lookup first uses the code asset emitted by the opt-in
build hook (`build_worker: true`), then the cdylib beside the located worker
executable. `tool/build_worker.sh` builds both for repository tests. If neither
route supplies the library, construction throws `UnsupportedError` with the
`build_worker: true` instruction. It never substitutes an in-memory mount.

Bad paths or modes at construction raise `ArgumentError`, and negative limits
raise `RangeError`; sandbox filesystem exceptions retain upstream types and
messages. These Dart error families, the list-only `mount:` parameter and
browser constructor refusal are deliberate differences from upstream's binding.
Memory-filesystem caps and the former `MountMode` enum are absent;
host-directory budgets belong to `monty-fs`.

See [execution model](execution-model.md) for synchronous host-call behavior
and the separation of mount budgets from worker interpreter memory limits.
