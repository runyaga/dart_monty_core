### Breaking

- The in-process engine (monty 0.0.23) is removed: `Monty` (the one-shot class), `MontyRepl`, `MontyPlatform`, `MontyResult`, `MontyProgress` and its subtypes, `MontyResourceUsage`, `MontyFutureCapable`, `ReplPlatform`, `ReplContinuationMode`, `createPlatformMonty`, `inputsToCode`, `toPythonLiteral`, the code-capture helpers, and `MockMontyPlatform`/`MockCallHistory` from the testing library. The native library `dart_monty_core_native` and the web assets `dart_monty_core_native.wasm` and `dart_monty_core_bridge.js` are no longer shipped.

### Changed

- The worker's web assets are named `dart_monty_core_worker.js` and `dart_monty_core_worker.wasm`. The build hook builds native code only when the root package opts in with `build_worker: true`.
- The package version follows upstream monty 1.1.0: `0.110.0-dev.1`.
