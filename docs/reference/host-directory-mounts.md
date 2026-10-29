# Host directory mounts

`MountDir` maps an opened native host directory to a virtual path. It is
exported by `dart_monty_core.dart`. Memory filesystems use `OSAccess`.

## A mount reads a host directory

This example mounts a host directory and reads it through the sandbox. An OS
handler answers calls outside the mount. Native mount setup is described in
[Platforms and discovery](#platforms-and-discovery).

```dart
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final host = await Directory.systemTemp.createTemp('monty-mount');
  final note = File('${host.path}/note.txt');
  await note.writeAsString('from the host disk');

  final data = MountDir(
    hostPath: host.path,
    virtualPath: '/data',
    mode: 'overlay',
    writeBytesLimit: 1000000,
  );
  try {
    await Monty.withPool((monty) => monty.withSession((session) async {
      // The mount answers filesystem calls. OSAccess answers the rest.
      final os = OSAccess(environ: {'APP_ENV': 'test'});
      final result = await session.feedRun(
        "import os\n(open('/data/note.txt').read(), os.getenv('APP_ENV'))",
        mount: [data],
        os: os,
      ) as MontyTuple;
      print(result.items); // [MontyString(from the host disk), MontyString(test)]
    }));
  } finally {
    data.close();
    await host.delete(recursive: true);
  }
}
```

`example/12_mount_dir.dart` runs this composition and checks the mount and
host file afterward.

## Construction and lifetime

[`MountDir`](../../lib/src/mount/mount_dir.dart) defines construction,
capability ownership, access modes, budgets, close behavior, and finalization.

## Routing, snapshots and cwd

[`MontySession.feedRun`](../../lib/src/worker/monty_session.dart),
[`OsHandler`](../../lib/src/worker/host_answers.dart), and
[`FunctionSnapshot.resumeAuto`](../../lib/src/worker/monty_snapshot.dart)
define routing and suspension behavior.

[`MontySession.loadSnapshot`](../../lib/src/worker/monty_session.dart) defines
how restored feeds receive new mount capabilities and preserve session state.
The same declaration defines working-directory establishment and validation.

The mount is not the first thing an import reaches: the session's module map
answers the `import` of a host module, and the stub request the worker sends
before it type checks a feed, before the mount sees them. See
[host modules](host-modules.md).

## Platforms and discovery

The class and session signatures compile on every backend.
[`MountDir`](../../lib/src/mount/mount_dir.dart) defines native-only
construction behavior. [`OSAccess`](../../lib/src/mount/os_access.dart) remains
available on browser backends.

[`MountDir`](../../lib/src/mount/mount_dir.dart) defines native service
discovery and constructor failure behavior.

Sandbox filesystem exceptions retain upstream types and messages. Browser
refusal and the list-only `mount:` parameter are deliberate differences from
upstream's binding. Host-directory budgets belong to `monty-fs`.

See [execution model](execution-model.md) for synchronous host-call behavior
and the separation of mount budgets from worker interpreter memory limits.
