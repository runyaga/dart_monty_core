# OS access

Monty routes filesystem operations, environment reads, clock access, sleeps,
and random data through the host. Choose
[`OsHandler`](../../lib/src/worker/host_answers.dart) for application-specific
calls, [`OSAccess`](../../lib/src/mount/os_access.dart) for an in-memory OS, or
[`MountDir`](../../lib/src/mount/mount_dir.dart) for a native host directory.

## In-memory files

`OSAccess` supplies an in-memory filesystem for the complete virtual namespace
and handles environment variables and most other OS calls. Reuse an instance
for shared state, or create one for an empty test environment.

[`OSAccess`](../../lib/src/mount/os_access.dart) defines its namespace and
state transitions.

[`OsPolicy`](../../lib/src/worker/os_policy.dart) selects deterministic clock,
time-zone, sleep, and random behavior for a checkout.

## Open files

Python `open(path, mode)` first reaches
[`OsHandler`](../../lib/src/worker/host_answers.dart). The handler returns a
[`MontyFileHandle`](../../lib/src/platform/monty_value_structured.dart) rather
than a live OS handle. Later path operations pass that handle as their first
argument.
[`OSAccess`](../../lib/src/mount/os_access.dart) routes those calls by the
handle's virtual path.

## Host-backed virtual files

`package:dart_monty_core/unsafe_callback_file.dart` exports `CallbackFile`.
The [`CallbackFile`](../../lib/src/mount/callback_file.dart) declaration
defines its security contract and callback behavior.

## Host directories

`MountDir` maps an opened host directory into the virtual filesystem on native
platforms. See [Host directory mounts](host-directory-mounts.md) for the
cross-component lifecycle.
