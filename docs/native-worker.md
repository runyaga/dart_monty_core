# Native worker

This page describes native worker selection, installation, integrity checks, and platform support.

## Supported platforms

Only macOS, Linux, and Windows reach the build hook's native worker handling, and the hook returns without native assets for every other target operating system. Manifest targets support `macos-arm64`, `linux-x64`, `linux-arm64`, and `windows-x64`.

Source: `hook/build.dart`, `lib/src/worker/worker_manifest.dart`, `test/hook/worker_hook_opt_in_test.dart`

## Choosing the worker

`locateWorker` selects a native worker in this order:

1. An explicit `workerLocation`, if given.
2. In an AOT executable, self-relaunch when `runMontyWorkerIfChild(args)` runs first in `main` and the bundled worker library resolves. Otherwise, selection throws.
3. Under JIT execution through `dart run` or `dart test`, a verified per-user cache entry for the host ABI when the bundled manifest publishes one.
4. Under JIT, the package-relative executable for the host ABI when the cache entry is absent or the manifest has no host artifact, resolved through `Isolate.resolvePackageUri`. An invalid or inaccessible cache entry throws.

Source: `lib/src/worker/worker_locator.dart`, `test/integration/worker/worker_locator_test.dart`

## Build hook

The build hook attempts the prebuilt worker installation for an eligible manifest target before it evaluates `build_worker`. An installation failure aborts the hook. With `build_worker: true`, `dart build cli` receives a bundled worker library from a verified prebuilt library when the manifest provides one, or from the native build otherwise.

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

The per-user cache root is `~/Library/Caches/dart_monty` on macOS, `~/.cache/dart_monty` on Linux, and `%LOCALAPPDATA%\dart_monty\Cache` on Windows. `HOME` on macOS and Linux and `LOCALAPPDATA` on Windows must be absolute paths. `XDG_CACHE_HOME` is ignored. An artifact path under the root is `worker-<sha256>/<filename>`.

Installation verifies the complete worker file against the manifest SHA-256 and makes a best-effort fingerprint record containing its size, modification time, change time, and manifest-entry key. After a successful verification for the same path and entry key, cache lookup skips verification for the rest of the process. Otherwise, it requests SHA-256 verification when the current fingerprint is unavailable, its size differs from the manifest, or the stored and current fingerprints differ. A missing or non-file worker, or a size mismatch, fails before SHA-256 hashing. Only a regular file with the expected size reaches SHA-256 hashing. macOS and Linux use metadata change time in the fingerprint. Windows records file creation time in that field, so a same-size modification with a restored modification time reaches SHA-256 verification only when another condition requires it.

Source: `lib/src/worker/worker_cache.dart`, `lib/src/worker/worker_fingerprint.dart`, `lib/src/worker/worker_install.dart`, `lib/src/worker/worker_locator.dart`, `test/unit/worker/worker_cache_test.dart`, `test/unit/worker/worker_fingerprint_test.dart`, `test/integration/worker/worker_locator_test.dart`

## Installing a published worker

The build hook installs a published worker archive selected by a manifest target into the per-user cache. A bundled manifest with an empty `targets` map publishes no prebuilt worker, and the hook installs none.

Source: `hook/build.dart`, `lib/src/worker/worker_install.dart`, `lib/src/worker/worker_manifest_data.dart`, `test/unit/worker/worker_install_test.dart`

## Building in this repository

`bash tool/build_worker.sh` builds the worker executable and worker library and writes them to `lib/src/bin/<os>-<arch>/`, using `dart_monty_worker` with the `.exe` suffix on Windows.

Source: `tool/build_worker.sh`, `lib/src/worker/worker_locator.dart`, `test/hook/worker_hook_build_print_test.dart`

## Flutter macOS

A Flutter macOS app bundle has the worker at `<App>.app/Contents/Helpers/dart_monty_worker` after `embed_worker.sh` embeds it. The application passes that path as `workerLocation`, because the locator does not search `Contents/Helpers` automatically. In check mode, `embed_worker.sh` requires that helper to exist, be executable, and have a valid signature. In embed mode, it checks the supplied worker's SHA-256, requires a thin arm64 Mach-O executable, copies it to that path, and signs it.

Source: `tool/flutter_macos/embed_worker.sh`, `tool/flutter_macos/probe.sh`
