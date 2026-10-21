# Native worker

This page describes native worker selection, installation, integrity checks, and platform support.

## Supported platforms

Only macOS, Linux, and Windows reach the build hook's native worker handling, and the hook returns without native assets for every other target operating system. Manifest targets support `macos-arm64`, `linux-x64`, `linux-arm64`, and `windows-x64`.

Source: `hook/build.dart`, `lib/src/worker/worker_manifest.dart`, `test/hook/worker_hook_opt_in_test.dart`

## Worker selection

[`locateWorker`](../lib/src/worker/worker_locator.dart) selects the native
worker.

## Build hook

The build hook attempts the prebuilt worker installation for an eligible manifest target before it evaluates `build_worker`. An installation failure aborts the hook. With `build_worker: true`, `dart build cli` receives a bundled worker library from a verified prebuilt library when the manifest provides one, or from the native build otherwise.

```yaml
hooks:
  user_defines:
    dart_monty_core:
      build_worker: true
```

The `worker_mirror` user define, when it is a string, overrides the manifest's release mirror for worker and worker-library archives. A value that is neither absent, null nor a string makes the hook throw when it processes an eligible target.

Source: `hook/build.dart`, `lib/src/worker/worker_install.dart`, `test/hook/worker_install_hook_test.dart`

## Self-relaunch

Self-relaunch connects AOT worker selection to the worker library bundled by
the build hook. The
[`runMontyWorkerIfChild`](../lib/src/worker/self_relaunch.dart) declaration
defines call ordering, child protocol behavior, failure status, and isolate
scope. The diagnosis APIs in that file distinguish application setup from a
missing or unloadable library.

Source: `lib/src/worker/self_relaunch.dart`, `test/integration/worker/self_relaunch_test.dart`

## Worker cache and integrity

[`workerCacheRoot`](../lib/src/worker/worker_cache.dart) defines cache
placement. [`WorkerFingerprint`](../lib/src/worker/worker_fingerprint.dart)
defines the fingerprint.

## Downloaded workers

Published workers have no developer signature or notarization. The macOS
linker supplies only an ad hoc signature. SHA-256 verification provides the
integrity check.

Platform probes establish the following behavior:

- A worker written by Dart `HttpClient` on macOS has no
  `com.apple.quarantine` attribute and starts normally. `spctl --assess`
  rejects its ad hoc signature. `Process.run` also starts a worker after a
  quarantine attribute is added manually. The probe has no desktop session,
  so it does not cover Finder launch dialogs.
- A worker written by Dart `HttpClient` on Windows has no `Zone.Identifier`
  stream. Browser downloads carry that Mark of the Web. `Process.run` starts
  a copy with `ZoneId=3`, while `Start-Process` can reject it until
  `Unblock-File` removes the mark. The package uses `Process.start`, which
  calls CreateProcess as `Process.run` does.
- A downloaded Linux worker starts normally. The probe identifies no
  quarantine mechanism.

The build hook receives `HOME` and `PATH` on macOS and Linux. On Windows it
also receives `LOCALAPPDATA`, `USERPROFILE`, `SYSTEMROOT`, `TEMP`, and `TMP`.

Source: `tool/consumers/native/`

## The build hook installs published workers

The build hook installs a published worker archive selected by a manifest target into the per-user cache. A bundled manifest with an empty `targets` map publishes no prebuilt worker, and the hook installs none.

Source: `hook/build.dart`, `lib/src/worker/worker_install.dart`, `lib/src/worker/worker_manifest_data.dart`, `test/unit/worker/worker_install_test.dart`

## Repository builds write native workers

`bash tool/build_worker.sh` builds the worker executable and worker library and writes them to `lib/src/bin/<os>-<arch>/`, using `dart_monty_worker` with the `.exe` suffix on Windows.

Source: `tool/build_worker.sh`, `lib/src/worker/worker_locator.dart`, `test/hook/worker_hook_build_print_test.dart`

## Flutter macOS

A Flutter macOS app bundle has the worker at `<App>.app/Contents/Helpers/dart_monty_worker` after `embed_worker.sh` embeds it. The application passes that path as `workerLocation`, because the locator does not search `Contents/Helpers` automatically. In check mode, `embed_worker.sh` requires that helper to exist, be executable, and have a valid signature. In embed mode, it checks the supplied worker's SHA-256, requires a thin arm64 Mach-O executable, copies it to that path, and signs it. Re-signing the containing app needs `--resign-app` when the app was signed before embedding. An Xcode phase that runs before app signing does not need it.

Source: `tool/flutter_macos/embed_worker.sh`, `tool/flutter_macos/probe.sh`
