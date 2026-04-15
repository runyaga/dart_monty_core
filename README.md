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
`pydantic/monty` test corpus. Each fixture is run through both the Dart
binding and a native oracle binary, and the results are compared.

```bash
# Build the oracle (one-time)
cd native && cargo build --bin oracle

# Run all 464 FFI conformance tests
dart test test/integration/oracle_ffi_test.dart -p vm --run-skipped --tags=ffi

# Run WASM fixture tests (requires Chrome)
dart test test/integration/wasm_fixture_test.dart -p chrome --run-skipped --tags=wasm
```

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
