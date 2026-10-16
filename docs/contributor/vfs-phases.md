# Filesystem design record

The former memory-backed `MountDir` and `memoryMountedOsHandler` design has
been replaced by two upstream hosts. `OSAccess` ports the Python in-memory
filesystem, with `MemoryFile`, `AbstractFile`, and `CallbackFile`.
`MountDir` opens real host directories and delegates their operations to
upstream `monty-fs` through the native mount service. See
[host directory mounts](../reference/host-directory-mounts.md) for its contract.

## Memory files and host directories have different lifetimes

`OSAccess` owns a persistent memory tree. Writes update the caller's files,
and created files appear in `files`. It has no mount prefixes, read-only mount
mode or filesystem byte caps. The deleted `VfsContent` wrappers, `MountMode`
enum, memory mount accounting and public open resolver have no compatibility
shims. Content is `String` or `Uint8List`; `StatResult` builds stat responses.
Customize `OSAccess` by composing an `OsHandler` around its callable interface.

A native `MountDir` owns an opened directory capability. Each feed owns its
mount table, overlay and cumulative write budget. Overlay writes disappear at
feed end; read-write changes persist in the host directory. Suspend/resume
keeps the table alive; snapshot restoration creates a new one. Memory budgets
cover overlay storage and transient results separately from interpreter memory.

## Host-reaching callbacks

`CallbackFile` remains in the separate `unsafe_callback_file.dart` library.
That import makes construction visible in review; it cannot prevent an
arbitrary `AbstractFile` implementation from reaching the host. Audit every
file implementation that is not a `MemoryFile`.

Callbacks receive the path captured at construction, even when Python renames
the file. Passing the mutable live path would let sandbox code choose a host
callback argument by renaming a virtual file. This is the retained C4b rule
(D-068). The live path still follows the memory tree for lookups and listings.
New files created by `OSAccess` are `MemoryFile`s, not callback files.

## Keep upstream's boundaries

Do not reproduce `monty-fs` path security in Dart. Its opened-root capability,
symlink handling, traversal rules, cross-mount rename checks and error text
are served by the pinned native crate. The memory filesystem is a separate
Python `OSAccess` port and deliberately does not acquire those mount semantics.
The old deferral of host mounts and their overlay mode is closed by F-2.

The internal memory tree stays private. Publishing a tree without the rest
of its policy would encourage consumers to treat a data structure as a
filesystem boundary. `AbstractFile` is open for content backings, while the
tree's node kinds remain internal.

## Evidence

The upstream corpus is one reference, not the whole filesystem specification.
The Python binding's `test_os_access.py`, `test_os_access_raw.py`,
`test_os_calls.py` and `test_mount_table.py` cover additional mode, directory,
callback and routing behavior. Expected values must come from those sources
or the recorded oracle probes, never from the implementation under test.

The VM adjudicator at
`test/unit/conformance/mount_fs_adjudicator_test.dart` runs the pinned
`mount_fs__ops.py` and `mount_fs__errors.py` unchanged, over the exact
`create_mount_fs_tempdir` tree with `/mnt` cwd and the default overlay.
Read-only, closed-mount and lying-handler controls must be reported as failures.
The native corpus runner uses real `MountDir`s as well. Named mutation checks
cover the adjudicator and session transitions; the corpus manifest is compared
in both directions so unexpected passes require removing stale divergences.
