# dart_monty_core

Thin Dart binding for [pydantic/monty](https://github.com/pydantic/monty) —
a sandboxed Python interpreter written in Rust.

**No Flutter. No bridge. No plugin registry.**  
Works on VM (FFI), Web (WASM), and in isolates.

---

## What is Monty?

Monty is a sandboxed Python interpreter implemented in Rust. It executes a
safe subset of Python — arithmetic, data structures, functions, classes,
closures — with hard resource limits (memory, stack depth, timeout). It
cannot import arbitrary modules or access the filesystem unless your Dart
code explicitly allows it via an `OsCallHandler`.

`dart_monty_core` is the raw binding layer. If you want Flutter widgets,
reactive state, or a richer plugin system, see `dart_monty`.

---

## Quick start

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

// One-shot evaluation
final result = await Monty.exec('2 ** 10');
print(result.value); // MontyInt(1024)

// Persistent session — variables survive across calls
final monty = Monty();
await monty.run('x = 42');
await monty.run('y = x * 2');
final r = await monty.run('x + y');
print(r.value); // MontyInt(126)
await monty.dispose();
```

---

## Core API

### `Monty` — convenience facade

| Member | Description |
|---|---|
| `Monty({osHandler})` | Persistent interpreter, auto-detected backend |
| `Monty.withPlatform(platform)` | Explicit backend |
| `Monty.exec(code)` | One-shot: create → run → dispose |
| `monty.run(code, {callbacks})` | Execute Python, state persists |
| `monty.state` | Current globals as `Map<String, Object?>` |
| `monty.clearState()` | Reset globals |
| `monty.dispose()` | Free resources |

### `MontySession` — lower-level stateful execution

`MontySession` wraps any `MontyPlatform` and serializes globals between
calls. Use it directly when you need fine-grained control over the platform
or want to pass `MontyCallback` handlers:

```dart
final platform = createPlatformMonty(); // FFI or WASM
final session = MontySession(platform: platform);

final result = await session.run('greet("world")', callbacks: {
  'greet': (args) async => 'Hello, ${args['_0']}!',
});
print(result.value); // MontyString('Hello, world!')

await platform.dispose();
```

### `MontyRepl` — persistent Rust heap REPL

Unlike `MontySession`, `MontyRepl` keeps the interpreter alive between
calls — heap objects, closures, and generator state all persist without
serialization overhead:

```dart
final repl = MontyRepl();
await repl.feed('def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)');
final r = await repl.feed('fib(10)');
print(r.value); // MontyInt(55)
await repl.dispose();
```

Use `ReplPlatform` to adapt a `MontyRepl` to the `MontyPlatform` interface:

```dart
final platform = ReplPlatform(repl: MontyRepl());
final session = MontySession(platform: platform);
```

---

## MontyValue

Python values cross the boundary as typed `MontyValue` subclasses. Use
pattern matching:

```dart
switch (result.value) {
  case MontyInt(:final value):    print('int: $value');
  case MontyFloat(:final value):  print('float: $value');
  case MontyString(:final value): print('str: $value');
  case MontyBool(:final value):   print('bool: $value');
  case MontyNull():               print('None');
  case MontyList(:final items):   print('list[${items.length}]');
  case MontyDict(:final items):   print('dict keys: ${items.keys}');
  case MontyDate(:final year, :final month, :final day): ...
  case null:                      print('no return value');
}
```

Construct values from Dart with `MontyValue.fromDart(value)`.

---

## Errors

| Exception | When |
|---|---|
| `MontyScriptError` | Python raised an exception (`TypeError`, `ValueError`, …) |
| `MontyResourceError` | Memory or stack limit exceeded |

```dart
try {
  await monty.run('1 / 0');
} on MontyScriptError catch (e) {
  print(e.excType);       // ZeroDivisionError
  print(e.exception.traceback);
}
```

Recoverable errors (e.g. `NameError`) are also available as
`result.error` without throwing when using `MontySession.run()` directly.

---

## OS call handler

Python code that touches `pathlib`, `os.getenv`, or `datetime.now` pauses
and asks the host. Provide an `OsCallHandler` to service those calls:

```dart
final monty = Monty(osHandler: (op, args, kwargs) async {
  if (op == 'os.getenv') return Platform.environment[args[0] as String];
  throw OsCallException('not supported', pythonExceptionType: 'PermissionError');
});
```

---

## Backends

| Backend | How selected | Use case |
|---|---|---|
| `MontyFfi` | `dart.library.ffi` present | Desktop, server, mobile |
| `MontyWasm` | `dart.library.js_interop` present | Web (dart2js / dart2wasm) |
| `createPlatformMonty()` | Auto | Pick the right one at compile time |

---

## Resource limits

```dart
await monty.run(
  untrustedCode,
  limits: MontyLimits(
    memoryBytes: 32 * 1024 * 1024, // 32 MB
    stackDepth: 200,
    timeoutMs: 5000,
  ),
);
```

---

## Testing

The package ships 464 Python fixture files from the upstream
`pydantic/monty` test corpus. Tests run on two backends: **FFI** (VM, using
a native oracle binary as source of truth) and **WASM** (headless Chrome).

### Unit tests

```bash
dart test --exclude-tags=ffi,wasm,integration
```

### FFI conformance tests (464 fixtures)

```bash
# 1. Build the Rust oracle + native dylib (one-time, or after Cargo.toml change)
cd native && cargo build --release && cargo build --bin oracle && cd ..

# 2. Run all 464 oracle conformance tests
dart test test/integration/oracle_ffi_test.dart -p vm --run-skipped --tags=ffi
```

The oracle binary (`native/src/bin/oracle.rs`) is the source of truth. Each
fixture runs through both the oracle and the Dart FFI binding and the results
are compared. All 464 fixtures must pass.

### Rust tests and linting

```bash
cd native
cargo test                                       # 291 unit tests
cargo clippy --all-targets -- -D warnings        # zero warnings
```

### WASM conformance tests (378 pass, 86 skipped)

The WASM path requires Node.js, npm, and Chrome. The full pipeline is wrapped
in `tool/test_wasm.sh`:

```bash
# Full pipeline: compile Rust → WASM, bundle JS bridge, compile Dart runner,
# serve with COOP/COEP headers, run headless Chrome.
bash tool/test_wasm.sh

# Skip the cargo + npm build if assets are already built:
bash tool/test_wasm.sh --skip-build
```

**What the pipeline does:**

1. `cargo build --target wasm32-wasip1 --release` — builds `dart_monty_native.wasm`
2. `cd js && npm install && node build.js` — esbuild bundles `dart_monty_bridge.js` and `dart_monty_worker.js` into `assets/`
3. `dart compile js test/integration/wasm_runner.dart` — compiles the Dart fixture runner to JS
4. A Python COOP/COEP HTTP server serves `test/integration/web/fixtures.html`
5. Headless Chrome loads the page and runs all 378 active WASM fixtures

**Prerequisites:**

```bash
# Rust wasm32-wasip1 target
rustup target add wasm32-wasip1

# Node.js (for esbuild)
npm --version    # >= 18

# Chrome (detected automatically)
# macOS: /Applications/Google Chrome.app/...
# Linux: google-chrome or chromium
```

**Skipped fixtures (86):** Fixtures tagged `# call-external`, `# run-async`,
`# mount-fs`, or `# xfail=monty` are skipped on both backends.
An additional 17 fixtures are tagged `# xfail=wasm` for known gaps in the WASM
JS bridge (parse-time SyntaxErrors, relative/wildcard imports, cycle
detection). See `tool/` and the maintenance guide at `~/dev/plans/dart_monty_core_maintenance.md`
for the xfail backlog and fix strategy.

### All checks at once

```bash
# Rust
cd native && cargo test && cargo clippy --all-targets -- -D warnings && cd ..

# Dart static analysis
dart analyze --fatal-infos lib/

# Dart format check
dart format --set-exit-if-changed lib/ test/ tool/

# FFI conformance
dart test test/integration/oracle_ffi_test.dart -p vm --run-skipped --tags=ffi

# WASM conformance (requires Chrome + Node.js)
bash tool/test_wasm.sh --skip-build   # if assets already built
```

### dart2wasm Support & Benchmarks

The WASM backend supports both **dart2js** and **dart2wasm**. While `dart2js` is
currently the default, the project is fully compatible with `dart2wasm` via
`package:js_interop`.

The CI pipeline validates both compilers. Compilation commands:

```bash
# dart2js
dart compile js test/integration/wasm_runner.dart -o test/integration/web/wasm_runner.dart.js

# dart2wasm (using the dedicated WASM harness)
dart compile wasm test/integration/wasm_runner_wasm.dart -o test/integration/web/wasm_runner.wasm
```

#### Performance Benchmark (464 Fixtures)

Benchmark conducted on an Apple M5 Max (April 2026) using headless Chrome 147.
Execution time includes the full integration suite (440 passing fixtures).

| Compiler | Passed | Skipped | Failed | Time (ms) |
| :--- | :--- | :--- | :--- | :--- |
| **dart2js** | 440 | 24 | 0 | **3002** |
| **dart2wasm** | 440 | 24 | 0 | **2991** |

**Key Insights:**
- **Stricter Semantics:** `dart2wasm` provides superior numeric precision for
  Python compatibility, correctly distinguishing between `int` and `double`
  (e.g. `MontyInt(2)` vs `MontyFloat(2.0)`), whereas `dart2js` blurs these
  types into JavaScript numbers.
- **Worker Overhead:** Performance parity indicates that execution is currently
  bound by **JS Worker context-switching** and the underlying Rust-WASM engine
  rather than Dart logic. This allows for complex Dart-side extensions with
  minimal performance impact.
- **Interactive REPL:** A decoupled web demo is available in `packages/dart_monty_web`,
  demonstrating a persistent, stateful REPL in the browser using the new
  WASM bridge extensions.

---

## Native layer

The Rust crate in `native/` wraps `pydantic/monty@v0.0.12` and exposes a
C ABI consumed by the FFI binding and compiled to WASM for the web backend.
Bindings are generated via `ffigen`; regenerate with:

```bash
dart tool/generate_bindings.sh   # or: bash tool/generate_bindings.sh
```

---

## License

MIT
