# Changelog

## Unreleased

(no entries)

## 0.17.0

A complete reorganize of the Dart-side Monty packages, simplifying the
surface area and easier to maintain.

`dart_monty_core` is the new bare-bones lower-level binding for
[pydantic/monty](https://github.com/pydantic/monty) — the sandboxed
Python interpreter in Rust. The companion
[`dart_monty`](https://pub.dev/packages/dart_monty) package keeps its
role as the higher-level, Flutter-friendly bridge layered on top.

The previous five-package federated layout
(`dart_monty_ffi`, `dart_monty_platform_interface`, `dart_monty_wasm`,
`dart_monty_native`, `dart_monty_web`) has been **discontinued** on
pub.dev. Two packages now cover what five used to:

- `dart_monty_core` (this package) — bare-bones bindings
  (`Monty`, `MontyRepl`, `MontyValue`, FFI/WASM platform glue).
  Replaces `dart_monty_ffi`, `dart_monty_platform_interface`,
  `dart_monty_wasm`.
- `dart_monty` — higher-level Flutter API (asset auto-loading, plugin
  scaffolding, host-function bridge). Replaces `dart_monty_native`,
  `dart_monty_web`.

### Coverage

Complete coverage of upstream pydantic/monty's public surface as of
**monty v0.0.17**: 188 Rust unit tests pass; 464 Python conformance
fixtures pass on both FFI and WASM backends (no fixture is skipped).

### What ships

- `Monty(code)` — compiled program holder. Run with `.run({inputs,
  externalFunctions, limits, osHandler, printCallback})`. Plus
  `Monty.exec(code, …)` for one-shot, `Monty.compile(code)` +
  `Monty.runPrecompiled(bytes, …)` for pre-parsed reuse,
  `Monty.typeCheck(code)` for static type analysis without execution.
- `MontyRepl` — stateful REPL on a persistent Rust heap. `feedRun` /
  `feedStart` / `resume`, `snapshot`/`restore`, `clearState`,
  `dispose`. Multiple instances coexist concurrently on both backends.
- 18 `MontyValue` subtypes: scalars (int, float, str, bool, none,
  bytes), collections (list, tuple, set, frozenset, dict),
  datetime (date, datetime, timedelta, timezone), and structured
  (`MontyPath`, `MontyNamedTuple`, `MontyDataclass`).
  `MontyDataclass.hydrate(factory)` round-trips Python `@dataclass`
  values into typed Dart objects.
- `MontyResult` with convenience getters `ok` (positive form of
  `!isError`) and `excType` (shorthand for `error?.excType`).
  `MontyException`, `MontyError`, `MontySyntaxError`,
  `MontyResourceError`, `MontyTypingError` value classes.
- External-function callbacks (sync + async). `OsCallHandler` for
  `pathlib`, `os.getenv`, `datetime.now`, `time.time`. Typed Python
  exceptions via `OsCallException(pythonExceptionType: ...)`.
- `memoryMountedOsHandler` — in-memory VFS with mount-based
  sandboxing, supports `Path.{read_text, write_text, read_bytes,
  write_bytes, exists, is_file, is_dir, mkdir, rmdir, unlink, rename,
  iterdir, absolute, resolve}`.
- `MontyLimits` (memory bytes, stack depth, timeout ms) and the
  JS-aligned spelling `MontyLimits.jsAligned(maxMemory:,
  maxDurationSecs:, maxRecursionDepth:)`.
- Backends: `MontyFfi` (dart:ffi) and `MontyWasm` (JS interop).
  `createPlatformMonty()` auto-picks at compile time.

### Build model (this release)

- **Native (FFI)** — `hook/build.dart` runs `cargo build --release`
  on consumer machines during `pub get`. Desktop triples only —
  macOS arm64+x86_64, Linux arm64-gnu+x86_64-gnu, Windows arm64+x86_64.
  Requires Rust + a system C linker. iOS and Android fall through
  with no asset emitted; for mobile use `dart_monty` (the higher-level
  Flutter wrapper) or compile the native crate yourself and wire it
  into your Flutter plugin. See `AGENTS.md` for prerequisite details.
- **Web (WASM)** — three prebuilt assets ship in `lib/assets/`
  (`dart_monty_core_bridge.js`, `dart_monty_core_worker.js`,
  `dart_monty_core_native.wasm`). No toolchain required.

### Migration from the discontinued federated packages

| Old package (discontinued) | Replacement |
|---|---|
| `dart_monty_ffi` | `dart_monty_core` (this package) |
| `dart_monty_platform_interface` | `dart_monty_core` |
| `dart_monty_wasm` | `dart_monty_core` |
| `dart_monty_native` | `dart_monty` |
| `dart_monty_web` | `dart_monty` |

The new APIs are deliberately different — see this package's README
for the `Monty` / `MontyRepl` surface and the dart_monty README for
the high-level bridge. There is no automated migration tool; existing
users `dart pub remove` the old name and `dart pub add dart_monty`
(or `dart_monty_core` for low-level use).

### Notes

- Python features intentionally unsupported: user-defined classes
  (`class` keyword), generators (`yield`), `match`/`case`, `del`,
  decorators, C extensions. Use dicts and functions in place of
  classes.
- Pre-1.0 — pin exact versions (`dart_monty_core: 0.17.0`, not
  `^0.17.0`). Patch releases may track upstream pydantic/monty
  breaking changes; minor version mirrors the upstream `monty` patch
  number (`0.X.0 ↔ monty v0.0.X`).
