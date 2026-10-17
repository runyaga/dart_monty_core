# Native worker

This page describes native worker selection, installation, integrity checks, and platform support.

## Supported platforms

Only macOS, Linux, and Windows reach the build hook's native worker handling, and the hook returns without native assets for every other target operating system.

Source: `hook/build.dart`, `lib/src/worker/worker_manifest.dart`, `test/hook/worker_hook_opt_in_test.dart`

## Choosing the worker

`locateWorker` selects a native worker in this order:

1. An explicit `workerLocation`, if given.
2. Under JIT execution through `dart run` or `dart test`, a verified per-user cache entry for the host ABI when the bundled manifest publishes one.
3. In an AOT executable, self-relaunch when `runMontyWorkerIfChild(args)` runs first in `main` and the bundled worker library resolves.
4. The package-relative executable for the host ABI, resolved through `Isolate.resolvePackageUri`.

Source: `lib/src/worker/worker_locator.dart`, `test/integration/worker/worker_locator_test.dart`

## Build hook

The build hook attempts the prebuilt worker installation for an eligible manifest target before it evaluates `build_worker`. With `build_worker: true`, `dart build cli` receives a bundled worker library from a verified prebuilt library when the manifest provides one, or from the native build otherwise.

```yaml
hooks:
  user_defines:
    dart_monty_core:
      build_worker: true
```

The `worker_mirror` user define, when it is a string, overrides the manifest's release mirror for worker and worker-library archives.

Source: `hook/build.dart`, `lib/src/worker/worker_install.dart`, `test/hook/worker_install_hook_test.dart`

## Self-relaunch

An AOT executable serves as its worker when `runMontyWorkerIfChild(args)` is the first statement of `main` and the bundled worker library resolves.

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

void main(List<String> args) {
  runMontyWorkerIfChild(args);
}
```

Source: `lib/src/worker/self_relaunch.dart`, `test/integration/worker/self_relaunch_test.dart`

## Worker cache and integrity

The per-user cache root is `~/Library/Caches/dart_monty` on macOS, `~/.cache/dart_monty` on Linux, and `%LOCALAPPDATA%\\dart_monty\\Cache` on Windows.

Installation verifies the complete worker file against the manifest SHA-256 and records a fingerprint containing its size, modification time, change time, and manifest-entry key. A cache lookup performs a complete SHA-256 verification when that record is missing or unusable, its observed fingerprint differs, its size differs from the manifest, or a different manifest entry selects the worker. macOS and Linux use metadata change time in the fingerprint. Windows records file creation time in that field, so a same-size modification with a restored modification time reaches a complete SHA-256 check only when another fingerprint condition requires one.

Source: `lib/src/worker/worker_cache.dart`, `lib/src/worker/worker_fingerprint.dart`, `lib/src/worker/worker_install.dart`, `test/unit/worker/worker_cache_test.dart`, `test/unit/worker/worker_fingerprint_test.dart`

## Installing a published worker

The build hook installs a published worker archive selected by the manifest into the per-user cache.

Source: `hook/build.dart`, `lib/src/worker/worker_install.dart`, `test/unit/worker/worker_install_test.dart`

## Building in this repository

`bash tool/build_worker.sh` builds the worker executable and worker library and writes them to `lib/src/bin/<os>-<arch>/`, using `dart_monty_worker` with the `.exe` suffix on Windows.

Source: `tool/build_worker.sh`, `lib/src/worker/worker_locator.dart`, `test/hook/worker_hook_build_print_test.dart`

## Flutter macOS

A Flutter macOS app bundle contains the worker at `<App>.app/Contents/Helpers/dart_monty_worker`. In check mode, `embed_worker.sh` requires that helper to exist, be executable, and have a valid signature. In embed mode, it checks the supplied worker's SHA-256, requires a thin arm64 Mach-O executable, copies it to that path, and signs it.

Source: `tool/flutter_macos/embed_worker.sh`
