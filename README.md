# dart_monty_core

Run Python in Dart. A thin binding for
[pydantic/monty](https://github.com/pydantic/monty) — the sandboxed Python
interpreter from Pydantic, written in Rust.

`dart_monty_core` is the raw binding layer — `Monty`, `MontyRepl`,
`MontyValue`, the FFI/WASM platform glue. For a higher-level API
(Flutter integration, asset auto-loading, plugin scaffolding) see
[`dart_monty`](https://github.com/runyaga/dart_monty), which depends
on this package.

> **Pre-1.0** — pin exact (`dart_monty_core: 0.17.0`); minor version mirrors the upstream `monty` patch (`0.X.0 ↔ monty v0.0.X`).

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
    'fetchWeather': (args) async => weatherApi.get(args['_0'] as String),
    'log': (args) async { logger.info(args['_0']); return null; },
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
| `run({inputs, externalFunctions, limits, osHandler, printCallback})` | Run in a fresh interpreter |
| `Monty.exec(code, {…})` | One-shot wrapper |
| `Monty.compile(code)` / `Monty.runPrecompiled(bytes, {…})` | Pre-compile and replay |
| `Monty.typeCheck(code, {prefixCode, scriptName})` | Static type analysis → `List<MontyTypingError>` |

### `MontyRepl` — stateful REPL

| | |
|---|---|
| `MontyRepl({scriptName, preamble})` | Auto-detected backend |
| `feedRun(code, {inputs, externalFunctions, osHandler, printCallback})` | State persists |
| `feedStart(code) + resume / resumeWithError` | Iterative externals + OS calls |
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

`run()` / `feedRun()` surface Python-level exceptions in `MontyResult.error`
rather than throwing — the interpreter stays alive. Resource limits and
disposal still throw.

### External functions

Python calls Dart callbacks by name. Positional args at `_0`, `_1`, …;
kwargs by Python name. Sync or async.

```dart
await Monty('compute("mul", 6, 7)').run(externalFunctions: {
  'compute': (args) async => switch (args['_0']) {
    'mul' => (args['_1'] as int) * (args['_2'] as int),
    _ => 0,
  },
});
```

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

```yaml
dependencies:
  dart_monty_core: 0.17.0
```

**Native (FFI)** — needs Rust + Cargo; the native-assets hook compiles the
dylib on `pub get`.

**Web (WASM)** — copy the three assets from `lib/assets/` into your `web/`
and add `<script src="dart_monty_core_bridge.js"></script>`.
`packages/dart_monty_web/` demonstrates the full wiring.

**Flutter** — depend on [`dart_monty`](https://github.com/runyaga/dart_monty);
assets are bundled automatically. JS / TS apps should use
[`@pydantic/monty`](https://www.npmjs.com/package/@pydantic/monty) directly.

## Known upstream limitations

External functions can't be called from inside iterator-consuming C
builtins — `map(ext_fn, …)`, `filter(ext_fn, …)`, `sorted(…, key=ext_fn)`
raise `RuntimeError` upstream. First-class references work everywhere else.

## License

MIT.
