# dart_monty_core

Thin Dart binding for [pydantic/monty](https://github.com/pydantic/monty) —
a sandboxed Python interpreter written in Rust.

**No Flutter. No bridge. No plugin registry.**  
Works on VM (FFI), Web (WASM), and in isolates.

> ### Pre-1.0 — pin exact versions
>
> `pydantic/monty` is iterating rapidly; upstream occasionally lands
> breaking changes to the Rust API, Python semantics, or bytecode format.
> `dart_monty_core` pins a specific upstream tag (currently **monty v0.0.14**)
> and bumps it deliberately.
>
> - Pin an exact version in your `pubspec.yaml` (`dart_monty_core: 0.0.14`,
>   not `^0.0.14`) — patch releases may track upstream breaking changes.
> - Public APIs may change without a deprecation cycle while we're pre-1.0.
> - The committed `assets/` (JS bridge + WASM) must stay in sync with the
>   committed `native/` Rust crate. CI enforces this; rebuild with
>   `bash tool/prebuild.sh` if you change either side.

---

## What is Monty?

Monty is a sandboxed Python interpreter implemented in Rust. It executes a
safe subset of Python — arithmetic, data structures, functions, closures,
comprehensions, exceptions, and a curated standard library (`math`, `re`,
`json`, `datetime`, `pathlib`) — with hard resource limits (memory, stack
depth, timeout). It cannot import arbitrary modules or access the filesystem
unless your Dart code explicitly allows it via an `OsCallHandler`.

Notable **unsupported** Python features: `class` keyword (user-defined
classes), `yield`/generators, `match`/`case`, `del`, decorators, and C
extensions. Use dicts and functions in place of classes.

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
monty.dispose();

// Pass per-invocation inputs (not persisted)
await monty.run('result = x * multiplier', inputs: {'x': 10, 'multiplier': 3});
```

---

## Core API

### `Monty` — convenience facade

| Member | Description |
|---|---|
| `Monty({osHandler, scriptName})` | Persistent interpreter, auto-detected backend |
| `Monty.exec(code)` | One-shot: create → run → dispose |
| `Monty.compile(code)` | Pre-compile to `Uint8List` bytes |
| `Monty.runPrecompiled(bytes)` | Run pre-compiled bytes (static, stateless) |
| `monty.run(code, {externals, inputs})` | Execute Python, state persists |
| `monty.clearState()` | Reset globals |
| `monty.dispose()` | Free resources (synchronous) |

### `MontySession` — lower-level stateful execution

`MontySession` is backed by the native Rust REPL heap — the same as `Monty`,
but exposed directly. Use it when you need the `externals` callback API,
`snapshot`/`restore`, or per-call `inputs` injection:

```dart
final session = MontySession();

final result = await session.run('greet("world")', externals: {
  'greet': (args) async => 'Hello, ${args['_0']}!',
});
print(result.value); // MontyString('Hello, world!')

session.dispose();
```

### `MontyRepl` — persistent Rust heap REPL

`MontyRepl` exposes the Rust REPL handle directly. Heap objects, closures, and
generator state all persist across calls:

```dart
final repl = MontyRepl();
await repl.feed('def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)');
final r = await repl.feed('fib(10)');
print(r.value); // MontyInt(55)
await repl.dispose();
```

#### Concurrent REPLs on WASM

Multiple `MontyRepl` instances can coexist concurrently on both FFI and WASM
backends. Each instance owns its own Rust heap handle — creating a second REPL
does not free or corrupt the first:

```dart
final repl1 = MontyRepl();
final repl2 = MontyRepl();

await repl1.feed('x = 10');
await repl2.feed('x = 99');

print((await repl1.feed('x')).value); // MontyInt(10)
print((await repl2.feed('x')).value); // MontyInt(99)

await repl1.dispose();
await repl2.dispose();
```

On WASM, each `MontyRepl` generates a unique `replId` that is threaded through
the JS bridge into the Web Worker, so independent Rust heap handles are
maintained in a `Map` rather than a single scalar.

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
  case MontyNone():               print('None');
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
| `MontySyntaxError` | Python parse/syntax error (`SyntaxError`) |
| `MontyScriptError` | Python runtime exception (`TypeError`, `ValueError`, …) |
| `MontyResourceError` | Memory or stack limit exceeded |

`MontySyntaxError` is a subtype of `MontyScriptError` — existing
`on MontyScriptError` catch blocks continue to catch it. Use it explicitly
when you want to distinguish parse errors from runtime errors:

```dart
try {
  await monty.run('def foo(  # unclosed paren');
} on MontySyntaxError catch (e) {
  print('Syntax error at line ${e.exception?.lineNumber}');
} on MontyScriptError catch (e) {
  print('${e.excType}: ${e.message}');
}
```

Runtime errors:

```dart
try {
  await monty.run('1 / 0');
} on MontyScriptError catch (e) {
  print(e.excType);       // ZeroDivisionError
  print(e.exception?.traceback);
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

Or use JS SDK-compatible field names:

```dart
await monty.run(
  untrustedCode,
  limits: MontyLimits.jsAligned(
    maxMemory: 32 * 1024 * 1024,
    maxDurationSecs: 5,
    maxRecursionDepth: 200,
  ),
);
```

---

## Passing inputs

Inject per-invocation variables before Python code runs. Inputs accept any
JSON-compatible Dart value (`int`, `double`, `bool`, `String`, `List`,
`Map`, `null`) and are **not persisted** across calls:

```dart
await monty.run(
  'output = [x * factor for x in data]',
  inputs: {
    'data': [1, 2, 3, 4, 5],
    'factor': 10,
  },
);
final r = await monty.run('output');
print(r.value); // MontyList([10, 20, 30, 40, 50])
```

Special float values are handled correctly:

```dart
await monty.run('y = x + 1', inputs: {'x': double.infinity});
// → y = float('inf') + 1
```

---

## Pre-compilation

Compile Python source once and reuse the bytecode across multiple runs.
Useful when running the same script with different inputs many times:

```dart
// Compile once — parsing happens here
final binary = await Monty.compile('output = [x * factor for x in data]');

// Run many times — no re-parsing
final monty = Monty();
await monty.runPrecompiled(binary);
```

Pre-compilation works on both **FFI** and **WASM** backends.

---

## Known upstream limitations

External functions **cannot** be invoked from inside these iterator-consuming
C builtins — the upstream `pydantic/monty` VM doesn't yet support suspending
for ext fn calls in those contexts:

- `map(ext_fn, ...)` — wrapping in a lambda does NOT help
- `filter(ext_fn, ...)`
- `sorted(..., key=ext_fn)`

The VM raises `RuntimeError: Internal error in monty: map(): external
functions are not yet supported in this context`. First-class references
work everywhere else (bare refs, user-defined HOFs, lists, conditionals).
Regression fixtures under `test/integration/_fixture_corpus.dart` with
the `_xfail` suffix encode this; they'll auto-fail when upstream fixes it.

---

## Installation

```yaml
dependencies:
  dart_monty_core: ^0.0.14
```

### FFI (native: macOS · Linux · Windows · iOS · Android)

Requires **Rust + cargo** installed. The `hook/build.dart` native-assets hook
compiles the Rust dylib automatically when you run `dart pub get` or
`flutter pub get`. No pre-built binaries are downloaded.

```bash
dart pub get   # triggers cargo build --release for your platform
```

### WASM (plain Dart web, no Flutter)

For plain-Dart web apps (no Flutter asset bundler), copy the three
asset files to your `web/` directory and add a `<script>` tag.
`packages/dart_monty_web/` in this repo demonstrates the full wiring:

```bash
# From your Dart web project
cp $(dart pub cache dir)/hosted/pub.dev/dart_monty_core-*/lib/assets/dart_monty_core_bridge.js web/
cp $(dart pub cache dir)/hosted/pub.dev/dart_monty_core-*/lib/assets/dart_monty_core_worker.js web/
cp $(dart pub cache dir)/hosted/pub.dev/dart_monty_core-*/lib/assets/dart_monty_core_native.wasm web/
```

```html
<!-- index.html — must load before your compiled Dart app -->
<script src="dart_monty_core_bridge.js"></script>
```

> **Note for JS/npm users**: If you are building a JavaScript or TypeScript
> application, use [`@pydantic/monty`](https://www.npmjs.com/package/@pydantic/monty)
> directly — that is the canonical npm package. `dart_monty_core` is for Dart
> developers who want the same interpreter through Dart APIs.

### Flutter (Web, iOS, Android, macOS, Linux, Windows)

Flutter consumers depend on [`dart_monty`](https://github.com/runyaga/dart_monty)
(the high-level API). `dart_monty_core` comes in transitively and
Flutter automatically bundles its declared `flutter.assets` — no
consumer-side redeclaration needed.

```yaml
# pubspec.yaml
dependencies:
  dart_monty: ^<version>   # dart_monty_core comes in transitively
```

```dart
// main.dart
import 'package:dart_monty/dart_monty.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DartMonty.ensureInitialized(); // loads bridge on web; no-op on native
  runApp(const MyApp());
}
```

`DartMonty.ensureInitialized()` dynamically injects
`<script src="assets/packages/dart_monty_core/lib/assets/dart_monty_core_bridge.js">`
into the document, awaits load, and verifies the bridge is ready. No
`<script>` tag in `web/index.html` is required; `--base-href` is
honoured automatically. The three built assets
(`dart_monty_core_bridge.js`, `dart_monty_core_worker.js`, and
`dart_monty_core_native.wasm`) live under `lib/assets/` so Flutter's
`packages/dart_monty_core/...` URI resolves against this package's
`lib/` root. They are committed to git and ship with both pub.dev
releases and `git:`/`path:` dependencies with no manual `cp` step.

### Building assets from source

Assets are committed to git but you can rebuild them from source when
the Rust crate or JS bridge changes. Requires Rust (with the
`wasm32-wasip1` target) and Node.js 20+.

```bash
bash tool/prebuild.sh
```

If you change `native/` or `js/` source, run `tool/prebuild.sh` and
commit the result in the same PR. CI runs the WASM/JS integration
suite on every PR, so a stale `assets/` that no longer parses or
runs will fail `test-wasm`. Byte-level drift-check (rebuild-and-compare)
is deferred pending a reproducible cross-host WASM build story.

---

## Testing

The package ships 464 Python fixture files from the upstream
`pydantic/monty` test corpus. Tests run on two backends: **FFI** (VM, using
a native oracle binary as source of truth) and **WASM** (headless Chrome).

### One-time setup

```bash
bash tool/install-hooks.sh        # pre-commit hooks (fmt, analyze, bindings check)
rustup target add wasm32-wasip1   # Rust target for WASM builds
```

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
cargo test                                       # 314 unit + integration tests
cargo clippy --all-targets -- -D warnings        # zero warnings
```

### WASM conformance tests (464/464)

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

1. `cargo build --target wasm32-wasip1 --release` — builds `dart_monty_core_native.wasm`, which `build.js` copies into `assets/`
2. `cd js && npm install --force && node build.js` — esbuild bundles `dart_monty_core_bridge.js` and `dart_monty_core_worker.js` into `assets/`
3. Copy WASI runtime: `cp js/node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs test/integration/web/@pydantic/monty-wasm32-wasi/` — required for dart2wasm; **not** done by `build.js`
4. `dart compile js test/integration/wasm_runner.dart` — compiles the dart2js fixture runner
5. A Python COOP/COEP HTTP server serves `test/integration/web/fixtures.html`
6. Headless Chrome loads the page and runs all 464 WASM fixtures

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

**All 464 fixtures pass — none are skipped.** The corpus was pre-filtered
from the upstream `pydantic/monty` test suite to include only fixtures
compatible with the Dart FFI and WASM backends.

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

### dart2wasm conformance tests (464/464)

The dart2wasm runner (`test/integration/wasm_runner_wasm.dart`) uses the same
464 fixture corpus. Run it manually after building the dart2wasm runner:

```bash
dart compile wasm \
  test/integration/wasm_runner_wasm.dart \
  -o test/integration/web/wasm_runner.wasm

# Copy WASI runtime (if not already done)
mkdir -p test/integration/web/@pydantic/monty-wasm32-wasi
cp js/node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
   test/integration/web/@pydantic/monty-wasm32-wasi/

# Run with headless Chrome (COOP/COEP server must be running on :8097)
bash tool/test_wasm.sh --skip-build --dart2wasm
```

**Expected**: `FIXTURE_DONE:{"total":464,"passed":464,"failed":0,"skipped":0}`

### Demos

```bash
# Web REPL (browser) — builds everything, opens http://localhost:8098
bash tool/serve_demo.sh

# dart2wasm variant
bash tool/serve_demo.sh --dart2wasm

# Flutter REPL (mobile/desktop) — requires FFI dylib (build step above)
bash tool/run_flutter_demo.sh [--device macos]
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
Execution time includes the full integration suite (464 passing fixtures).

| Compiler | Passed | Skipped | Failed | Time (ms) |
| :--- | :--- | :--- | :--- | :--- |
| **dart2js** | 464 | 0 | 0 | **3002** |
| **dart2wasm** | 464 | 0 | 0 | **2991** |

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

## Coming from @pydantic/monty (JS/TS)

If you know the JavaScript `@pydantic/monty` SDK, here is the Dart equivalent
for each common operation:

| Task | JS (`@pydantic/monty`) | Dart (`dart_monty_core`) |
|---|---|---|
| Pass inputs | `m.run({ inputs: {x: 10} })` | `await monty.run(code, inputs: {'x': 10})` |
| Set script name | `new Monty(code, {scriptName: 'x.py'})` | `Monty(scriptName: 'x.py')` |
| Pre-compile code | `const b = m.dump()` | `final b = await Monty.compile(code)` |
| Run pre-compiled | `Monty.load(b).run()` | `await monty.runPrecompiled(b)` |
| Catch syntax errors | `catch (e as MontySyntaxError)` | `on MontySyntaxError catch (e)` |
| JS-style limits | `{ maxDurationSecs: 5, maxMemory: 1e6 }` | `MontyLimits.jsAligned(maxDurationSecs: 5, maxMemory: 1000000)` |

### Conscious divergences

Some Dart API choices intentionally differ from JS:

| Dart API | Reason |
|---|---|
| `run(code)` — code passed at runtime | Externals binding and `inputs` injection happen at call time |
| `MontyValue` type hierarchy | Richer than raw JS values; enables exhaustive Dart pattern matching |
| `MontyProgress` sealed union | More expressive than JS `MontySnapshot instanceof` checks |
| `OsCallHandler` separate from externals | Intentional Dart extension for OS-call interception |

---

## Native layer

The Rust crate in `native/` wraps `pydantic/monty@v0.0.14` and exposes a
C ABI consumed by the FFI binding and compiled to WASM for the web backend.
Bindings are generated via `ffigen`; regenerate with:

```bash
dart tool/generate_bindings.sh   # or: bash tool/generate_bindings.sh
```

---

## License

MIT
