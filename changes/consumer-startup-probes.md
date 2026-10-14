### Internal

- Consumer startup probes (`tool/consumers/`): a plain Dart web app and a
  Flutter web app depend on the package by path, start the worker pool with no
  `workerLocation` and no init call, run `1 + 1` in headless Chrome and assert
  `2`, on dart2js, dart2wasm, `flutter build web` and `flutter build web
  --wasm`. A driver fails a build whose worker assets are missing or served
  from the wrong base. They run in the `Consumer startup` workflow on the
  paths they cover and nightly; the Flutter SDK is pinned to a release that
  bundles the repo's Dart, and `tool/check_sdk_pin.sh` checks it.

### Fixed

- `dart compile wasm` no longer aborts with "Conversion between non-reference
  types (from f64 to i64)" in an app that reaches the worker pool's value
  conversion. The pool's check for an unpaired surrogate is written as a loop
  in place of a tear-off passed to `Iterable.any`, which the Dart 3.13.5 wasm
  compiler could not compile. Behaviour is unchanged.
