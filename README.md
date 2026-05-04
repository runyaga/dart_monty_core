# dart_monty_core

<p align="center">
  <img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/assets/dart_monty.jpg" alt="dart_monty_core" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty_core/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty_core/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty_core/actions/workflows/deploy-pages.yml/badge.svg)](https://runyaga.github.io/dart_monty_core/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty_core/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty_core)

Run Python in Dart. A thin binding for
[pydantic/monty](https://github.com/pydantic/monty) — the sandboxed Python
interpreter from Pydantic, written in Rust.

`dart_monty_core` is the raw binding layer — `Monty`, `MontyRepl`,
`MontyValue`, the FFI/WASM platform glue. For a higher-level API
(Flutter integration, asset auto-loading, plugin scaffolding) see
[`dart_monty`](https://github.com/runyaga/dart_monty), which depends
on this package.

## Why

Dart is compiled, no reflection — fast and tree-shakeable, but you can't
ship new behaviour without re-shipping a binary. Monty is a sandboxed
Python runtime designed to behave as Dart's *scripting* language: an
embeddable Python subset under hard resource limits, on both native (FFI)
and web (WASM).

LLMs generate excellent Python. Let them script your Dart app — through
code your app type-checks, runs in a sandbox, exposes only the external
functions and OS calls you whitelist, and inspects the typed result. More
flexible than a plug-in registry, safer than `eval` — Pydantic runs an
active **$5,000 bug bounty** at [hackmonty.com](https://hackmonty.com/)
for the underlying interpreter.

```dart
final errors = await Monty.typeCheck(llmCode);
if (errors.isNotEmpty) return;

final result = await Monty(llmCode).run(
  inputs: {'temperatureC': 22},
  externalFunctions: {
    'fetchWeather': (args, _) async => weatherApi.get(args[0] as String),
    'log': (args, _) async { logger.info(args[0]); return null; },
  },
  limits: const MontyLimits(memoryBytes: 32 << 20, timeoutMs: 5000),
);
```

## Quick start

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

// One-shot
final r = await Monty.exec('2 ** 10');
print(r.value); // MontyInt(1024)

// Compiled program — different inputs, no shared state
final program = Monty('x * y');
print((await program.run(inputs: {'x': 10, 'y': 3})).value); // MontyInt(30)
print((await program.run(inputs: {'x': 7, 'y': 6})).value);  // MontyInt(42)

// Stateful REPL — variables, functions, imports survive
final repl = MontyRepl();
await repl.feedRun('def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)');
print((await repl.feedRun('fib(10)')).value); // MontyInt(55)
await repl.dispose();
```

## API

### `Monty` — compiled program

| | |
|---|---|
| `Monty(code, {scriptName})` | Hold source as a re-runnable program |
| `run({inputs, externalFunctions, externalAsyncFunctions, limits, osHandler, printCallback})` | Run in a fresh interpreter |
| `Monty.exec(code, {…})` | One-shot wrapper |
| `Monty.compile(code)` / `Monty.runPrecompiled(bytes, {…})` | Pre-compile and replay |
| `Monty.typeCheck(code, {prefixCode, scriptName})` | Static type analysis → `List<MontyTypingError>` |

### `MontyRepl` — stateful REPL

| | |
|---|---|
| `MontyRepl({scriptName, preamble})` | Auto-detected backend |
| `feedRun(code, {inputs, externalFunctions, externalAsyncFunctions, osHandler, printCallback})` | State persists |
| `feedStart(code, {externalFunctions, externalAsyncFunctions, …}) + resume / resumeWithError` | Iterative externals + OS calls |
| `detectContinuation(code)` | `>>>` vs `...` mode |
| `snapshot()` / `restore(bytes)` | Serialise / restore the heap |
| `clearState()` / `dispose()` | Wipe / free |

Multiple `MontyRepl`s coexist — each owns its own Rust heap.

### `MontyValue` — typed Python values

```dart
switch (result.value) {
  case MontyInt(:final value):     /* … */ ;
  case MontyString(:final value):  /* … */ ;
  case MontyList(:final items):    /* … */ ;
  case MontyDict(:final entries):  /* … */ ;
  case MontyDate(:final year):     /* … */ ;
  case MontyNamedTuple(:final fieldNames, :final values): /* … */ ;
  case MontyDataclass(:final name, :final attrs): /* … */ ;
  case MontyNone(): /* … */ ;
}
```

18 subtypes — scalars (`MontyInt`, `MontyFloat`, `MontyString`, `MontyBool`,
`MontyBytes`, `MontyNone`), collections (`MontyList`, `MontyTuple`,
`MontyDict`, `MontySet`, `MontyFrozenSet`), datetime (`MontyDate`,
`MontyDateTime`, `MontyTimeDelta`, `MontyTimeZone`), and structured
(`MontyPath`, `MontyNamedTuple`, `MontyDataclass`).
`MontyDataclass.hydrate(factory)` turns a Python `@dataclass` into your
own Dart class:

```dart
final user = (result.value as MontyDataclass).hydrate(User.fromAttrs);
```

Build from Dart with `MontyValue.fromDart(value)`.

### Errors

| | |
|---|---|
| `MontySyntaxError` | Python parse error (subtype of `MontyScriptError`) |
| `MontyScriptError` | Python runtime exception |
| `MontyResourceError` | Limit exceeded (memory / stack / timeout) |
| `MontyInternalError` | API misuse (extends `Error`, not `Exception`, so it can't be swallowed by `on Exception`) |

`run()` / `feedRun()` surface Python-level exceptions in `MontyResult.error`
rather than throwing — the interpreter stays alive. Resource limits,
disposal, and `MontyInternalError` still throw.

### Inputs injection

`run({inputs: {…}})` and `feedRun({inputs: {…}})` accept a
`Map<String, Object?>` of per-call variables. Each entry is converted to
a Python literal via [`toPythonLiteral`][te] and prepended to the script
as an assignment statement, so the value is bound as a top-level Python
name *before* user code runs.

```dart
final r = await Monty('f"{greeting}, {name}!"').run(inputs: {
  'greeting': 'hello',
  'name': 'Alice',
});
// r.value.dartValue == 'hello, Alice!'
```

Each call gets a fresh injection — `inputs` is **not** durable state.
Use `MontyRepl.feedRun(code, inputs: {…})` for the stateful equivalent;
inputs there are also re-bound per call, but anything else assigned by
the script persists across calls.

**Convertible types** — `bool`, `int`, `double` (incl. `nan` / `inf`),
`String`, `List`, `Map`, and `MontyNone()`. Nested lists / maps are
converted recursively.

**Two distinct error mechanisms:**

| Bad input | Throws | When to expect |
|---|---|---|
| Dart `null` value | `MontyInternalError` | Use `MontyNone()` for Python `None` — Dart `null` is rejected so it cannot be silently swallowed. |
| Unsupported type (e.g. `DateTime`, custom class) | `ArgumentError` | Convert to a supported type before injection. |

Both throw **synchronously** from `run()` — the script never starts.

```dart
// MontyInternalError — can't be caught by `on Exception`:
await Monty('x').run(inputs: {'x': null});
// ArgumentError:
await Monty('x').run(inputs: {'x': DateTime.now()});
// Correct: use MontyNone() for Python None
await Monty('x is None').run(inputs: {'x': const MontyNone()});
```

[te]: lib/src/platform/inputs_encoder.dart

#### Async scripts

`inputs:` is a textual prepend, so it composes with **any** script —
including ones that use `async def` / `await` / `asyncio.gather`. Pure-
Python async (no Dart externals) works at every API layer with no extra
setup:

```dart
await Monty('''
async def double(): return n * 2
await double()
''').run(inputs: {'n': 21});
// → MontyInt(42)
```

For a script that `await`s a Dart-registered external function, register
it under `externalAsyncFunctions` instead of `externalFunctions`:

```dart
await Monty('result = await fetch(key)\nresult').run(
  inputs: {'key': 'token'},
  externalAsyncFunctions: {
    'fetch': (args, _) async => 'value-for-${args[0]}',
  },
);
// → MontyString('value-for-token')
```

`asyncio.gather` over multiple `externalAsyncFunctions` callbacks runs
them concurrently — all callbacks fire before the first
`MontyResolveFutures`, then resolve in argument order. Callbacks in
`externalFunctions` resolve eagerly Dart-side; Python `await ext()` on
one of those raises `TypeError`.

For the cell-by-cell contract across every API layer × backend, see
[`docs/deep-dives/async-matrix.md`][async-matrix].

[async-matrix]: docs/deep-dives/async-matrix.md

### External functions

Python calls Dart callbacks by name. The callback signature is
`(List<Object?> args, Map<String, Object?>? kwargs)` — positional args
by index, keyword args by name.

```dart
await Monty('compute("mul", 6, 7)').run(externalFunctions: {
  'compute': (args, _) async => switch (args[0]) {
    'mul' => (args[1] as int) * (args[2] as int),
    _ => 0,
  },
});
```

Use `externalAsyncFunctions` when Python needs to `await` the result
directly or when you want concurrent dispatch via `asyncio.gather`:

```dart
await Monty('result = await fetch(key)').run(
  inputs: {'key': 'token'},
  externalAsyncFunctions: {
    'fetch': (args, _) async => 'value-for-${args[0]}',
  },
);
```

Callbacks in `externalFunctions` are awaited Dart-side before Python
resumes (sync from Python's perspective). Callbacks in
`externalAsyncFunctions` hand Python a coroutine — Python `await`s it,
and `asyncio.gather` over multiple such calls runs them concurrently.

### OS calls

`pathlib`, `os.getenv`, `datetime.now`, `time.time` pause and call your
`OsCallHandler`. Optional — provide only when the script touches the OS.

```dart
await Monty('os.getenv("HOME")').run(
  osHandler: (op, args, kwargs) async => switch (op) {
    'os.getenv' => Platform.environment[args[0] as String],
    _ => throw OsCallException('not supported',
        pythonExceptionType: 'PermissionError'),
  },
);
```

`memoryMountedOsHandler` (`lib/src/mount/`) provides a ready-made in-memory
VFS with mount-based sandboxing.

### Resource limits

```dart
await Monty(code).run(
  limits: const MontyLimits(
    memoryBytes: 32 << 20,
    stackDepth: 200,
    timeoutMs: 5000,
  ),
);
```

JS-aligned spelling: `MontyLimits.jsAligned(maxMemory:, maxDurationSecs:,
maxRecursionDepth:)`.

## Backends

| | Selected when |
|---|---|
| `MontyFfi` | `dart.library.ffi` present (desktop / server / mobile) |
| `MontyWasm` | `dart.library.js_interop` present (web) |
| `createPlatformMonty()` | Auto-pick at compile time |

## Installation

> **0.17.0 builds the native FFI binary from source on `dart pub get`.**
> Every FFI consumer needs a Rust toolchain, including Flutter consumers
> coming in via [`dart_monty`](https://github.com/runyaga/dart_monty).

### Install (from pub.dev)

```bash
dart pub add dart_monty_core
```

Or pin in `pubspec.yaml`:

```yaml
dependencies:
  dart_monty_core: ^0.17.0
```

To track unreleased fixes on `main`, use a `git:` dependency
instead:

```yaml
dependencies:
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: main
```

### Prerequisites for FFI (desktop only)

`hook/build.dart` runs `cargo build --release --target <host-triple>`
on the consumer's machine during `pub get`. Required toolchain:

- **Rust** — install via [rustup](https://rustup.rs)
- **C linker** for the cdylib link step:
  - **macOS**: `xcode-select --install` (provides `clang`)
  - **Linux**: `sudo apt install build-essential` / `dnf install gcc` / equivalent
  - **Windows**: [Visual Studio Build Tools](https://visualstudio.microsoft.com/downloads/) with the C++ workload

Supported FFI host triples in v0.17.0: `aarch64-apple-darwin`,
`x86_64-apple-darwin`, `aarch64-unknown-linux-gnu`,
`x86_64-unknown-linux-gnu`, `aarch64-pc-windows-msvc`,
`x86_64-pc-windows-msvc`. **Mobile (iOS, Android) is not handled by this
package's hook** — the hook returns no native asset for those targets.
If you're using `dart_monty_core` directly and need Monty on mobile,
compiling and wiring the native crate into your Flutter project's iOS /
Android plugin is your responsibility. For a higher-level Flutter
integration, use [`dart_monty`](https://github.com/runyaga/dart_monty).

First `pub get` takes 1–3 minutes (compiling the native crate); subsequent
runs reuse cargo's cache.

### Web (WASM)

WASM ships pre-built — no toolchain required. Copy the three assets into
your `web/` and add a script tag:

```bash
# Locate the package cache (pub.dev hosted, or a git: dep):
SRC=$(find ~/.pub-cache/hosted/pub.dev ~/.pub-cache/git \
  -maxdepth 2 -type d -name 'dart_monty_core-*' 2>/dev/null | head -1)
cp "$SRC/lib/assets/dart_monty_core_bridge.js" web/
cp "$SRC/lib/assets/dart_monty_core_worker.js" web/
cp "$SRC/lib/assets/dart_monty_core_native.wasm" web/
```

```html
<script src="dart_monty_core_bridge.js"></script>
```

`packages/dart_monty_web/` in this repo demonstrates the full wiring.

### Other ecosystems

- **Flutter** — [`dart_monty`](https://github.com/runyaga/dart_monty) wraps this package with the Flutter integration layer (asset loading, plugin scaffolding). When using `dart_monty_core` directly, mobile (iOS / Android) compilation is your responsibility; `dart_monty` is the alternative.
- **JS / TS** — use [`@pydantic/monty`](https://www.npmjs.com/package/@pydantic/monty); the canonical npm package.

## Known upstream limitations

External functions can't be called from inside iterator-consuming C
builtins — `map(ext_fn, …)`, `filter(ext_fn, …)`, `sorted(…, key=ext_fn)`
raise `RuntimeError` upstream. First-class references work everywhere else.

## Stability and versioning

This package does **not** follow semantic versioning. Breaking changes can
land in any release. The [CHANGELOG](CHANGELOG.md) is kept up-to-date with
every breaking change, so pin to a specific version and read the changelog
before upgrading.

We expect to stabilise the API and adopt semver when the package goes into
production — roughly 1–3 months from now. If you are planning to depend on
this package, please open an issue so we can factor your use-case into the
stabilisation work.

## License

MIT.
