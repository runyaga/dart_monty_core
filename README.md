# dart_monty_core

<p align="center">
  <img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/assets/dart_monty.jpg" alt="dart_monty_core" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty_core/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty_core/actions/workflows/ci.yaml)
[![codecov](https://codecov.io/gh/runyaga/dart_monty_core/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty_core)

[GitHub](https://github.com/runyaga/dart_monty_core)

**dart_monty_core 0.110.0 · monty 1.1.0**

Run Python in Dart. Bindings for
[pydantic/monty](https://github.com/pydantic/monty), the sandboxed Python
interpreter from Pydantic, written in Rust.

The interpreter never runs in your process. Each session runs in a worker:
a child process on native platforms, a Web Worker in the browser. A crash in
the sandbox kills that worker, not your app, and a pool replaces it. This is
the model of upstream's own bindings (`pydantic_monty`'s `AsyncMonty`), and
the API follows theirs.

## Why

Dart is compiled, with no reflection: fast and tree-shakeable, but you cannot
ship new behaviour without shipping a new binary. Monty is a sandboxed Python
subset under hard resource limits, on native and on the web.

LLMs write good Python. Let them script your Dart app through code your app
type-checks, runs in a sandbox, lets reach only the host functions and OS
calls you provide, and reads back as typed values. Pydantic runs a bug bounty
at [hackmonty.com](https://hackmonty.com/) for the underlying interpreter.

## Quick start

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final value = await Monty.withPool(
    (monty) => monty.withSession((session) async {
      await session.feedRun('def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)');
      return session.feedRun('fib(10)');
    }),
  );
  print(value); // MontyInt(55)
}
```

`Monty.withPool` starts a pool of workers and closes it however the body
ends; `withSession` dedicates one worker to a session and gives it back
afterwards. A session keeps its globals, functions and imports from one feed
to the next. A live worker keeps the Dart process running, so a pool from
`Monty.start` and a session from `checkout` must each be closed.

## API

### `Monty`: the pool

| | |
|---|---|
| `Monty.start({minProcesses, maxProcesses, checkoutTimeout, requestTimeout, maxCheckoutsPerWorker, feedDurationLimitGrace, turnDurationLimitGrace, workerLocation})` | Start a pool (upstream `AsyncMonty`) |
| `Monty.withPool(body, {…})` | The same, closed when `body` ends |
| `checkout({scriptName, limits, typeCheck, typeCheckStubs, typeCheckFormat, typeCheckColor, assertMessageAnnotations, printFlushInterval, osPolicy})` | A session on its own worker |
| `withSession(body, {…})` | The same, closed when `body` ends |
| `close()` | Refuse new checkouts and end the idle workers |

`requestTimeout` bounds each protocol turn; a turn past it kills the worker
and the call fails with `MontyCrashedError` (`timedOut` is true).

### `MontySession`: one interpreter

| | |
|---|---|
| `feedRun(code, {inputs, externalLookup, printCallback, cwd, os, skipTypeCheck})` | Run to the end and return the value of the last expression, or `MontyNone` |
| `feedStart(code, {…})` | Run to the first suspension and return a `MontySnapshot` |
| `dump()` | The session as bytes, idle or suspended |
| `loadSession(bytes)` / `loadSnapshot(bytes, {externalLookup, printCallback, os})` | Restore a dump into a fresh session |
| `installDependencies(requirements)` | Empty list succeeds; any other throws `MontyRuntimeError` (core's worker is the pure-Monty sandbox, as upstream's) |
| `workerPid` | The worker's process id (null on the web) |
| `close()` | End the session; never throws |

### Inputs, host functions and print

```dart
final value = await session.feedRun(
  'f"{greeting}, {fetch(key)}!"',
  inputs: {'greeting': const MontyString('hello'), 'key': const MontyString('k')},
  externalLookup: {
    'fetch': MontyHostFunction(
      'fetch',
      (args, kwargs) async =>
          MontyString('value-for-${(args[0] as MontyString).value}'),
    ),
  },
);
print(value); // MontyString(hello, value-for-k!)
```

`inputs` are bound as global names before the code runs, each a `MontyValue`
(`MontyValue.fromDart` converts plain Dart data). A host object's wrappers,
`ClassInstance` and `ClassType`, are `MontyValue`s too, and the session serves
their members.

`externalLookup` resolves the names the code leaves undefined, when the code
reads one (upstream's `external_lookup`). Every entry is a `MontyValue`: a
host function (`MontyHostFunction`), or any other value, a host object
included, converted when the name is read and then bound as a global. A host
function's `fn` takes `(List<MontyValue> args, Map<String, MontyValue> kwargs)`
and returns a `MontyValue`, directly or as a future, which is awaited before
Python resumes; wrap `fn` in `coroutine(...)` to make it an `async def`
function, whose
calls Python awaits (`asyncio.gather` runs them at once). Throw
`ExternalException('ValueError', 'bad key')` to raise a chosen Python
exception; any other throw raises `Exception` with its text. `HostClass`
describes a Dart class to `ClassInstance` and `ClassType`.

`cwd` switches the sandbox's working directory (`os.getcwd()`, and what
relative paths resolve against) before the code runs; it lasts across feeds
until a feed switches it, and starts at `/`.

`printCallback` gets each run of printed text as `(stream, text)`, with
`stream` `'stdout'` or `'stderr'`. `CollectStreams` and `CollectString` are
ready-made callbacks that collect it under a byte cap:

```dart
final out = CollectString();
await session.feedRun('print("hi")', printCallback: out.call);
print(out.output); // hi
```

Without a callback, printed text goes to the process's stdout and stderr on
native and to the console in a browser.

### Snapshots: answering suspensions yourself

`feedStart` returns at each host function call, OS call, name lookup and
wait on pending futures. Answer each one and continue:

```dart
var snapshot = await session.feedStart('double(21)');
while (snapshot is! MontyComplete) {
  snapshot = switch (snapshot) {
    FunctionSnapshot s when s.functionName == 'double' =>
      await s.resume(ExternalReturnValue(MontyInt((s.args[0] as MontyInt).value * 2))),
    FunctionSnapshot s => await s.resumeAuto(),
    NameLookupSnapshot s => await s.resume(),
    FutureSnapshot s => await s.resumeAuto(),
    MontyComplete() => snapshot,
  };
}
print(snapshot.output); // MontyInt(42)
```

`resumeAuto()` answers from the `externalLookup` and `os` given to `feedStart`.
A suspended snapshot's `dump()` can be restored later, in another worker,
with `loadSnapshot`.

### OS calls

`pathlib`, `open()`, `os.getenv`, `datetime.now` and the like are OS calls.
Pass `os:`, an `OsHandler`, to answer them; without one they are declined.

```dart
await session.feedRun(
  'import os\nos.getenv("APP_MODE")',
  os: (name, args, kwargs) => switch (name) {
    'os.getenv' => const MontyString('demo'),
    _ => throw const OsCallNotHandledException(),
  },
);
```

The name is upstream's OS function name. Throwing `OsCallNotHandledException`
synchronously declines the call, and the worker raises its default:
`PermissionError` for a filesystem call, `RuntimeError` for the rest.

`OSAccess` provides an in-memory filesystem for the entire virtual namespace:

```dart
final os = OSAccess(
  files: [MemoryFile('/data/config.json', '{"debug": true}')],
  environ: {'APP_ENV': 'test'},
);
await session.feedRun("open('/data/config.json').read()", os: os);
```

Files contain a `String` or `Uint8List`. Writes update caller-held file objects,
and `os.files` also includes files created by Python. The handler owns its state
across feeds; create a new handler for a fresh filesystem. Memory filesystem
mount prefixes, read-only modes and byte budgets are no longer provided.
Customize an operation by wrapping the callable `OSAccess` and forwarding the
remaining calls. `StatResult.fileStat` and `dirStat` build stat responses for
custom handlers.

The clock, time zone, sleeps and random seed a session sees are set by
`checkout(osPolicy: OsPolicy(...))`.

#### Host-reaching virtual files

`package:dart_monty_core/unsafe_callback_file.dart` is a separate library on
purpose. `CallbackFile` backs a virtual file with host callbacks, which run
on the host with full access to its filesystem and network; one that touches
the real filesystem breaks the sandbox. Importing it is a security decision.
The separation is a signal, not a boundary: `AbstractFile` is an open interface,
so audit every `AbstractFile` that is not a `MemoryFile`.

### Resource limits and type checking

```dart
final session = await monty.checkout(
  limits: const ResourceLimits(
    maxMemory: 32 << 20,
    maxRecursionDepth: 200,
    maxFeedDuration: Duration(seconds: 5),
  ),
  typeCheck: true,
);
```

Each limit is optional; null means upstream's default. A limit hit raises a
Python exception (`MemoryError`, `RecursionError`, `TimeoutError`) that
arrives as `MontyRuntimeError`, and the session survives, except for a
worker that ran out of memory and exited, which is `MontyCrashedError`.
With `typeCheck: true` each snippet is type-checked first; one the check
rejects throws `MontyTypingError` without running.

### Errors

| | |
|---|---|
| `MontySyntaxError` | The code did not parse |
| `MontyRuntimeError` | The code raised an exception it did not catch, a limit included |
| `MontyTypingError` | The type check rejected the code, which did not run |
| `MontyCrashedError` | The worker is gone: it died, was killed at a deadline, or broke the protocol |

All four extend the sealed `MontyError`. `toString()` is upstream's `str()`;
`exception` is the inner Python exception as a `MontyExceptionValue`;
`MontySyntaxError` and `MontyRuntimeError` carry `traceback` (`List<Frame>`)
and `display(format)`.

### `MontyValue`: typed Python values

```dart
switch (value) {
  case MontyInt(:final value):
    print('int $value');
  case MontyString(:final value):
    print('str $value');
  case MontyList(:final items):
    print('list of ${items.length}');
  case MontyDict(:final pairs):
    print('dict of ${pairs.length}');
  case MontyClassProxy(:final classType, :final attrs):
    print('${classType.name} instance: ${attrs.keys}');
  case MontyNone():
    print('None');
  default:
    print(value);
}
```

Scalars (`MontyInt`, `MontyBigInt`, `MontyFloat`, `MontyString`, `MontyBool`,
`MontyNone`, `MontyEllipsis`, `MontyNotImplemented`), collections
(`MontyList`, `MontyTuple`, `MontyDict`, `MontySet`, `MontyFrozenSet`,
`MontyBytes`), date and time (`MontyDate`, `MontyDateTime`, `MontyTime`,
`MontyTimeDelta`, `MontyTimeZone`), and structured values (`MontyPath`,
`MontyNamedTuple`, `MontyFileHandle`, `MontyExceptionValue`,
`MontyClassProxy`, `MontyStdTypeProxy`).

A class defined in the sandbox comes back as `MontyClassProxy`; its
`classType` (`MontyClassTypeProxy`) names the class and says whether it is a
dataclass. A function or a type comes back as `MontyStdTypeProxy`, whose
`kind` is `'function'` or `'type'`.

### Testing

`package:dart_monty_core/dart_monty_core_testing.dart` exports
`FakeMontySession`, a `MontySession` with scripted answers that needs no
worker.

## Platforms

| | Worker | Needs |
|---|---|---|
| Native (VM, AOT) | a child process | a worker executable (below) |
| Web (dart2js, dart2wasm) | a Web Worker | nothing: the worker ships in `lib/assets/` |

### Native

The worker executable is not shipped on pub.dev. Either:

- **Opt in to the build hook** in your app's pubspec and build with
  `dart build cli`. The hook compiles the worker library from source (Rust
  via [rustup](https://rustup.rs) and a C linker are needed), and your app
  runs a copy of itself as the worker. Call `runMontyWorkerIfChild(args)` as
  the first statement of `main`:

  ```yaml
  hooks:
    user_defines:
      dart_monty_core:
        build_worker: true
  ```

  ```dart
  Future<void> main(List<String> args) async {
    runMontyWorkerIfChild(args);
    // ...
  }
  ```

  Distribute the whole `dart build cli` bundle directory. `tool/aot_worker/`
  in this repository is such a consumer.

- **Or pass `workerLocation`**, the path of a worker executable, to
  `Monty.start` or `Monty.withPool`. In this repository,
  `bash tool/build_worker.sh` builds one into `lib/src/bin/<os>-<arch>/`,
  where `dart run` and `dart test` find it without `workerLocation`.

### Web

No toolchain and no setup: with no `workerLocation`, the pool finds the
worker assets where a plain Dart web build (`packages/dart_monty_core/assets/`)
or a Flutter web build (`assets/packages/dart_monty_core/lib/assets/`) serves
them. Pass `workerLocation`, an asset base URL, to serve them from elsewhere.
`tool/consumers/` holds one probe app of each kind.

## Installation

```bash
dart pub add dart_monty_core
```

## Known upstream limitations

External functions cannot be called from inside iterator-consuming builtins:
`map(ext_fn, …)`, `filter(ext_fn, …)` and `sorted(…, key=ext_fn)` raise
`RuntimeError` upstream.

Dumps are not portable across a monty version: load a dump only into the
version that made it, from a source you trust.

## Contributing

Start with [`AGENTS.md`](AGENTS.md): build, test and gate commands.

```bash
bash tool/gate.sh     # the commit gate
```

Read the **exit code** and the verdict line, not the tail of the summary.

**Changelog.** Do not edit `CHANGELOG.md` in a PR. A PR that changes `lib/`
adds a fragment, `changes/<slug>.md` (format in
[`changes/README.md`](changes/README.md)); CI fails without one unless the PR
has the `no-changelog` label or a body line starting `no-changelog:`. At tag or
release time a maintainer folds the fragments into `CHANGELOG.md` and deletes
them: `dart tool/changelog_assemble.dart [--version X.Y.Z]`, in a PR labeled
`changelog-assembly`.

**Coverage baseline.** `tool/coverage-baseline.json` is not part of a PR. CI
fails a PR only if a file's coverage, or lib-wide coverage, drops below the
base branch's baseline; a rise needs no baseline edit. After a merge, a
maintainer runs `bash tool/record_coverage_baseline.sh` on main to record the
new baseline from main's CI coverage.

Further contributor docs:
[`docs/contributor/testing-philosophy.md`](docs/contributor/testing-philosophy.md)
(whether a test is worth running),
[`docs/contributor/testing-runbook.md`](docs/contributor/testing-runbook.md)
(what to run), [`docs/reference/execution-model.md`](docs/reference/execution-model.md)
(the fault boundary) and
[`docs/deep-dives/async-matrix.md`](docs/deep-dives/async-matrix.md)
(host functions and `async`).

## Stability and versioning

This package does **not** follow semantic versioning. The version tracks the
upstream monty it pins: upstream 1.1.0 is 0.110.x, and the patch is this
package's own fixes on that pin. `tool/check_version_pin.sh` enforces the
mapping. Breaking changes can land in any release; pin a version and read the
[CHANGELOG](CHANGELOG.md) before upgrading.

If you plan to depend on this package, please open an issue so we can take
your use case into account.

## License

MIT.
