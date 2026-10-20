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
and the call fails with `MontyCrashedError` (`timedOut` is true). An
execution turn — a feed, or a resume after a suspension — runs under the
earliest of three deadlines: `requestTimeout`, what the session's
`maxFeedDuration` has left plus `feedDurationLimitGrace`, and
`maxTurnDuration` plus `turnDurationLimitGrace`; the earliest of the three
wins, and one that is unset leaves its term out.

`Monty.start` spawns `minProcesses` workers at once and fails if any of them
cannot be located, spawned, or readied within 30 seconds — a
`MontyCrashedError` that names the cause. Sizing has a domain:
`minProcesses` is 0 or more, `maxProcesses` is 1 or more and at least
`minProcesses`, and `maxCheckoutsPerWorker` spans 0 (retire at first
release) to 2^32 - 1; every duration must be non-negative. When
`maxProcesses` is null it is the platform's default — the processor count on
native, the browser's hardware concurrency on the web — which can sit below
`minProcesses` (a small machine, a browser that reports little), making the
pool impossible; set `maxProcesses` explicitly there.

A checkout's deadlines are separate: `checkoutTimeout` bounds only the wait
for a free worker (forever when null); starting a new worker is bounded by the
30-second startup deadline, and the session's configure turn by
`requestTimeout` (unbounded when null). So a checkout that waits, spawns and
configures can take up to all three, and `checkoutTimeout` never cuts short a
spawn or a configure. `feedDurationLimitGrace` and `turnDurationLimitGrace`
run one second by default; null leaves that limit unguarded by the parent.

### `MontySession`: one interpreter

| | |
|---|---|
| `feedRun(code, {inputs, externalLookup, printCallback, mount, cwd, os, skipTypeCheck})` | Run to the end and return the value of the last expression, or `MontyNone` |
| `feedStart(code, {…})` | Run to the first suspension and return a `MontySnapshot` |
| `dump()` | The session as bytes, idle or suspended |
| `loadSession(bytes)` / `loadSnapshot(bytes, {mount, externalLookup, printCallback, os})` | Restore a dump into a fresh session |
| `installDependencies(requirements)` | Empty list succeeds; any other throws `MontyRuntimeError` (core's worker is the pure-Monty sandbox, as upstream's) |
| `workerPid` | The worker's process id (null on the web, while a protocol turn is in flight, and once the session is finished) |
| `close()` | End the session; never throws |

One call holds the session at a time: a second `feedRun` waits for the turn
in flight and fails with `StateError` once the first feed suspends on a
host call — a suspension wakes the waiting feeds at once and refuses each,
and a feed arriving while a suspension awaits is refused at once instead
of queueing. A close fails every waiting call as finished.

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
included, converted when the name is read and then bound as a global, so
later feeds see it without the lookup. Reading the name and calling it are
two steps, each its own suspension under `feedStart` (a `NameLookupSnapshot`,
then a `FunctionSnapshot`): the read binds the name, and the call runs the
entry. A host function's `fn` takes `(List<MontyValue> args,
Map<String, MontyValue> kwargs)`
and returns a `MontyValue`, directly or as a future, which is awaited before
Python resumes; wrap `fn` in `coroutine(...)` to make it an `async def`
function, whose calls Python awaits: one the sandbox awaits with nothing
else to run is awaited in place (a `FunctionSnapshot`'s `allowEagerAwait`
says so); any other gets a pending future, delivered once every task is
blocked, so `asyncio.gather` runs several at once. Throw
`ExternalException('ValueError', 'bad key')` to raise a chosen Python
exception; any other throw raises `Exception` with its text. `HostClass`
describes a Dart class to `ClassInstance` and `ClassType`.

`cwd` switches the sandbox's working directory (`os.getcwd()`, and what
relative paths resolve against) before the code runs. A fresh session defaults
to its first mount's virtual path, or `/` without mounts. A feed accepted past
type checking establishes cwd, even if it then raises a syntax or runtime error;
a typing rejection leaves it unset. Later feeds keep cwd unless explicitly
changed. Session and snapshot restores preserve the saved directory.
Invalid cwd is rejected before mount-table construction, leaving the session
usable and its default eligibility unchanged.

`printCallback` gets each run of printed text as `(stream, text)`, with
`stream` `'stdout'` or `'stderr'`. It is a callback of type
`FutureOr<void> Function(String stream, String text)`; one that returns a
future is awaited before the next run is delivered, so a slow sink holds
the feed back. A callback that never returns is cut off by the turn's
deadline — `requestTimeout` or a duration backstop, whichever comes
first — or by `close`; each kills the worker. `CollectStreams` and
`CollectString` are ready-made callbacks that collect it under a byte cap:

```dart
final out = CollectString();
await session.feedRun('print("hi")', printCallback: out.call);
print(out.output); // hi
```

A collector outlives the feed it served: it keeps the prints of every feed
it is passed to, and its cap covers them all, so a collector reused across
feeds fills up. Reading `output` does not drain it; a new collector starts
empty.

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
    // resume(value:) binds the name; the first arm answers the call.
    NameLookupSnapshot s => await s.resume(
      value: MontyHostFunction('double', (args, kwargs) => const MontyNone()),
    ),
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
A handler is a callback of type that returns the answer:

```dart
FutureOr<MontyValue> Function(
  String name,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
)
```

```dart
await session.feedRun(
  'import os\nos.getenv("APP_MODE", "prod")',
  os: (name, args, kwargs) => switch (name) {
    'os.getenv' => (args[0] as MontyString).value == 'APP_MODE'
        ? const MontyString('demo')
        : args[1], // the default the call carried
    _ => throw const OsCallNotHandledException(),
  },
);
```

The name is upstream's OS function name. Throwing `OsCallNotHandledException`
synchronously declines the call, and the worker raises its default:
`PermissionError` for a filesystem call, `RuntimeError` for the rest. The
handler sees every argument: `os.getenv` receives the key and the default
(`None` without one). The `OsHandler` API reference lists all 29 names with
their argument shapes and answers; a write or append answers the count
written — characters for `Path.write_text` and `Path.append_text`, bytes for
the `bytes` forms.

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
`StatResult.fileStat` and `dirStat` build stat responses for custom handlers.
Customize an operation by wrapping the callable `OSAccess` and forwarding the
remaining calls:

```dart
final inner = OSAccess(
  files: [MemoryFile('/data/config.json', '{"debug": true}')],
  environ: {'APP_ENV': 'test'},
);
await session.feedRun(
  "open('/data/config.json').read()",
  os: (name, args, kwargs) => switch (name) {
    'os.getenv' => const MontyString('demo'), // answer one call here
    _ => inner(name, args, kwargs),           // OSAccess is callable
  },
);
```

The clock, time zone, sleeps and random seed a session sees are set by
`checkout(osPolicy: OsPolicy(...))`.

#### Host directories (native)

`MountDir` opens a host directory and maps it into the sandbox through upstream
`monty-fs`. Pass a list to `mount:` on `feedRun`, `feedStart`, or `loadSnapshot`:

```dart
final mount = MountDir(hostPath: '/host/data', virtualPath: '/data');
try {
  await session.feedRun("open('/data/config.json').read()", mount: [mount]);
} finally {
  mount.close();
}
```

Use the mount's absolute virtual path in fed code: a relative one resolves
against the session's working directory, which the first mount supplies only
before that directory is established. Pass `cwd:` to set it explicitly.

The default `mode: 'overlay'` discards writes at feed completion. Choose
`'read-only'` to reject writes or `'read-write'` to persist them on the host.
Mounts answer before `os:`; a missing path inside a mount remains a mount error.
An in-progress feed keeps its mount table across snapshot resumes. A restored
snapshot needs `mount:` again and starts with a fresh overlay; dumps contain
neither mounts nor overlay contents. `FunctionSnapshot.resumeAuto()` uses the
captured mounts and handler, while `resume(result)` answers directly.

`feedStart` surfaces both system sleep calls, `system.sleep` and
`system.async_sleep`, for manual answering or dispatch through `resumeAuto()`
and `os:` — a `resumeAuto()` sends them to the mounts and the OS handler
rather than waiting them. `feedRun` waits system sleeps itself, cut to the
OS policy's maximum. `FakeMontySession` uses the same host dispatch for its
scripted calls.

The constructor throws `UnsupportedError` on the web, and on native without
the mount library. Lookup uses the code asset built with `build_worker: true`,
then the cdylib beside the package's own worker executable in
`lib/src/bin/<os>-<arch>/`; the worker named by `workerLocation` and the
published worker cache are not searched. A bad path or mode throws
`ArgumentError`, a negative limit `RangeError`. Repository tests use
`tool/build_worker.sh`, which builds the library there.
See [host directory mounts](docs/reference/host-directory-mounts.md) for
lifetime, error, budget, discovery and routing details.

#### Host-reaching virtual files

`package:dart_monty_core/unsafe_callback_file.dart` is a separate library on
purpose. `CallbackFile` backs a virtual file with host callbacks, which run
on the host with full access to its filesystem and network; one that touches
the real filesystem breaks the sandbox. Importing it is a security decision.
The separation is a signal, not a boundary: `AbstractFile` is an open interface,
so audit every `AbstractFile` that is not a `MemoryFile`.

A `CallbackFile` seeds an `OSAccess` namespace like a `MemoryFile` does; the
callbacks run on every read (and every `stat`, which sizes the content) and
write, with nothing cached (native, reading a real log file):

```dart
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/unsafe_callback_file.dart';

final os = OSAccess(files: [
  CallbackFile(
    '/data/app.log',                                         // virtual
    (path) => File('/var/log/app.log').readAsStringSync(),   // every read
    (path, content) =>
        File('/var/log/app.log').writeAsStringSync('$content'), // writes
  ),
]);
await session.feedRun("open('/data/app.log').read()", os: os);
```

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

Each limit is optional. Null means upstream's default. A limit hit raises a
Python exception (`MemoryError`, `RecursionError`, `TimeoutError`) that
arrives as `MontyRuntimeError`, and the session survives. Two of them,
`maxSuspensions` and `maxTotalSleep`, are enforced by the parent, not the
interpreter: suspensions and system sleep add up over the whole checkout,
across every feed and resume — 1000 suspensions by default, no sleep budget
unless set — and their aborts (`RuntimeError`, `TimeoutError`) cannot be
caught by sandbox code. A worker that exits
after its allocator refused an allocation over the hard limit raises
`MontyRuntimeError` carrying `MemoryError` and ends the session. On dart2js
and dart2wasm, a session that keeps the allocation which exhausted `maxMemory`
raises `MemoryError` on every later feed until a feed drops that allocation.
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

Scalars (`MontyInt`, `MontyBigInt`, `MontyFloat`, `MontyComplex`,
`MontyString`, `MontyBool`, `MontyNone`, `MontyEllipsis`,
`MontyNotImplemented`), collections
(`MontyList`, `MontyTuple`, `MontyDict`, `MontySet`, `MontyFrozenSet`,
`MontyBytes`), date and time (`MontyDate`, `MontyDateTime`, `MontyTime`,
`MontyTimeDelta`, `MontyTimeZone`), and structured values (`MontyPath`,
`MontyNamedTuple`, `MontyFileHandle`, `MontyExceptionValue`,
`MontyClassProxy`, `MontyStdTypeProxy`).

A class defined in the sandbox comes back as `MontyClassProxy`; its
`classType` (`MontyClassTypeProxy`) names the class and says whether it is a
dataclass. A function or a type comes back as `MontyStdTypeProxy`, whose
`kind` is `'function'` or `'type'`.

### Telemetry

`instrumentTelemetry` installs an adapter for the isolate's lifetime: every
pool and session in the isolate then reports its spans, logs and
measurements through it. Monty owns no exporter, so the adapter is yours: it
receives the records and hands them to your own SDK.

```dart
class LoggingTelemetry implements MontyTelemetry {
  @override
  Object? currentContext() => null;

  @override
  Object? contextWithSpan(Object? context, Object span) => context;

  @override
  Object startSpan(
    String name,
    Object? parent,
    Map<String, Object> attributes, {
    required BigInt startTimeUnixNanos,
  }) => name;

  @override
  void endSpan(
    Object span,
    Map<String, Object> attributes, {
    required BigInt endTimeUnixNanos,
  }) {}

  @override
  void emitLog(
    Object? span,
    String severity,
    String body,
    Map<String, Object> attributes, {
    required BigInt timestampUnixNanos,
    required int severityNumber,
  }) {
    print('[$severity] $body');
  }

  @override
  void recordMetric(
    String name,
    String kind,
    String unit,
    String description,
    num value,
    Map<String, Object> attributes, {
    required Object? context,
  }) {
    print('$name: $value');
  }

  @override
  R runInContext<R>(Object? context, R Function() body) => body();
}

void main() {
  instrumentTelemetry(LoggingTelemetry());
}
```

The contract:

- The context and the span are your own tokens: Monty hands them back and
  reads nothing in them. `currentContext` gives the parent of a session's
  spans, `startSpan` opens a span under a parent and returns its token, and
  `endSpan` and `emitLog` take that token again. An adapter that ignores
  spans returns any token and ignores it thereafter.
- `runInContext` runs a host callback with the context current, including
  its asynchronous continuations. The callback runs once whatever the
  adapter does: one that does not call it has it run anyway.
- Every measurement carries an explicitly empty context (`context` is
  null): use your SDK's empty context, not the ambient span. The name, kind,
  unit and description are upstream's instrument names.
- Attribute values are strings, integers, doubles or booleans. Delivery is
  synchronous; there is nothing to flush.
- A signal that throws — spans, logs or metrics — is disabled for the rest
  of the isolate and reported once through the zone `instrumentTelemetry`
  was called in. The other signals keep working.

Without an adapter, no records are made and a snapshot's trace context is
null. A second `instrumentTelemetry` call throws `StateError`: the
installation cannot be undone.

### Testing

`package:dart_monty_core/dart_monty_core_testing.dart` exports
`FakeMontySession`, a `MontySession` with scripted answers that needs no
worker.

```dart
final session = FakeMontySession()..willReturn(const MontyInt(42));
expect(await session.feedRun('1 + 1'), const MontyInt(42));
expect(session.feeds, ['1 + 1']);
```

A test queues what each feed's Python does: the host calls (`willCall`),
OS calls (`willCallOs`), name lookups (`willLookUp`), the futures it
awaits (`willAwait`), its prints, and how the feed ends (`willReturn`,
`willRaise`, `willCrash`). The session answers each suspension as a
worker-backed session does, and records the host's answers in `answers`: a
record of the call's id, the futures batch it went out in and the answer
itself.

The fake does not run Python and does not type-check, so it never raises a
`MontyTypingError`, and it cannot send a host object. See
[the fake session](docs/reference/fake-session.md) for the scripting API,
the OS calls it knows with their arguments, and its limits.

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
  import 'package:dart_monty_core/dart_monty_core.dart';

  Future<void> main(List<String> args) async {
    runMontyWorkerIfChild(args);
    // ...
  }
  ```

  Arming is isolate-local: a pool started in another isolate, such as one
  running under `Isolate.run`, cannot relaunch unless that isolate calls
  `runMontyWorkerIfChild` before it locates a worker.

  Distribute the whole `dart build cli` bundle directory. `tool/aot_worker/`
  in this repository is such a consumer.

- **Or pass `workerLocation`**, the path of a worker executable, to
  `Monty.start` or `Monty.withPool`. In this repository,
  `bash tool/build_worker.sh` builds one into `lib/src/bin/<os>-<arch>/`,
  where `dart run` and `dart test` find it without `workerLocation`.

#### Worker integrity and warm start

Published cached workers are unsigned. Installation verifies the worker's
SHA-256 in full, which provides the integrity guarantee, then records its
size, modification time, and change time beside it. On macOS and Linux, the
change time additionally catches a same-size modification with the mtime
restored. On Windows, `FileStat.changed` is the file creation time rather than
the metadata change time, so the fingerprint is size, mtime, and creation time.
Later runs compare that fingerprint and re-hash in full when the record is
missing or corrupt, a field changes, or a different manifest entry selected the
worker. On Windows, a same-size modification with the mtime restored is not
detected until the next full hash.

#### Flutter desktop (macOS)

A Flutter macOS app has no package-relative worker, and the self-relaunch
above is meant for `dart build cli` apps. Put the worker in the app bundle and
pass its path:

```dart
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final helper = '${File(Platform.resolvedExecutable).parent.parent.path}'
      '/Helpers/dart_monty_worker';
  final monty = await Monty.start(workerLocation: helper);
}
```

`tool/flutter_macos/embed_worker.sh` places the worker at
`Contents/Helpers/dart_monty_worker`. It refuses a worker whose SHA-256 does
not match the `--sha256` you give it, signs the helper with the app's
identity (`EXPANDED_CODE_SIGN_IDENTITY` in an Xcode Run Script phase, ad hoc
otherwise) and refuses anything that is not a thin arm64 executable. Run it
as a Run Script phase before the code-sign phase, or after the build with
`--resign-app`. Only macOS arm64 workers are published in 0.110, and a
universal Flutter release build is fine because the helper is not a build
hook output. `tool/flutter_macos/probe.sh` builds a throwaway app and checks
all of this without opening a window.

#### Unsigned workers

The 0.110 workers are not signed with a developer identity or notarised on
any platform. On macOS the linker adds an ad-hoc signature and nothing more. The
SHA-256 check is the integrity guarantee. The build hook checks the archive
and the unpacked file against the manifest before it installs anything, and
the runtime checks the cached file again before it starts it.

What the operating systems did with a worker downloaded by Dart code, measured
on GitHub-hosted runners with the probes in `tool/consumers/native/`:

- **macOS.** A file written by `HttpClient` has no `com.apple.quarantine`
  attribute, and the worker starts. The
  worker carries only the linker's ad-hoc signature, and `spctl --assess`
  rejects it. With the quarantine attribute added by hand, `Process.run`
  still started it on the runner. That session had no desktop, so a Finder
  launch, which can show the "cannot be opened" dialog, was not tried.
- **Windows.** A file written by `HttpClient` has no Zone.Identifier stream
  (Mark of the Web), so there is no mark for SmartScreen to read. A browser
  download does carry one. With `ZoneId=3` added to a copy, `Process.run`
  (CreateProcess) started it and exited 0, but `Start-Process`, which goes
  through ShellExecute, failed with "The operation was canceled by the user".
  After `Unblock-File` it started. The package starts the worker with
  `Process.start`. I measured `Process.run`, which makes the same
  CreateProcess call. A worker you copied out of a browser download and
  start through the shell may need `Unblock-File` first.
- **Linux.** A downloaded worker started normally. I found no quarantine
  mechanism to test.

A build hook sees `HOME` and `PATH` on Linux and macOS and, on Windows, also
`LOCALAPPDATA`, `USERPROFILE`, `SYSTEMROOT`, `TEMP` and `TMP`. That is why
the cache root is derived from `HOME` or `LOCALAPPDATA` and never from
`XDG_CACHE_HOME`.

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

**Coverage baseline.** `tool/coverage-baseline.json` is not part of a feature PR. CI
fails a PR only if a file's coverage, or lib-wide coverage, drops below the
base branch's baseline; a rise needs no baseline edit. After a merge, a
maintainer refreshes the baseline once per release, in the release PR
(`bash tool/record_coverage_baseline.sh --no-commit` on main records it from
main's CI coverage); it is not recorded after every merge.

Further contributor docs:
[`docs/README.md`](docs/README.md) (the documentation index),
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
