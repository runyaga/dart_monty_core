# Changelog

## Unreleased

## 0.120.1 - 2026-10-30

### Fixed

- Windows: the build hook no longer fails with `LOCALAPPDATA must be an absolute path`. The Dart hooks runner filters the hook environment to an allowlist that omits `LOCALAPPDATA`, so the worker cache root now falls back to `%USERPROFILE%\AppData\Local` (`USERPROFILE` is allowlisted) when `LOCALAPPDATA` is absent or relative. This unblocks `dart run` / `dart build` / `dart test` on Windows with SDKs whose hooks runner filters `LOCALAPPDATA` (seen on Dart 3.10.0, which Flutter stable bundles; Dart 3.13.5 passes it through).
- The worker executable and mount library are unchanged from 0.120.0: the bundled manifest still installs the `v0.120.0` release binaries, and the worker crate stays at 0.120.0.

### Internal

- CI builds the Windows worker and mount library once (`worker-windows`, `windows-2025`) and uploads them as `dart_monty_worker-windows-x64`, the Windows counterpart of worker-rust's linux-x64 artefact. Windows test jobs download it and check its stamp with `build_worker.sh --check` instead of building again.
- New job `test-worker-windows` runs `test/integration/worker/mount_windows_io_test.dart` on those binaries: junction, file-symlink, `\..\`, drive-letter, rename-out, reserved-device-name and trailing-dot/space cases against a host `MountDir` in all three modes, held to a test-count floor. It is the first job that runs tests on Windows.


## 0.120.0 - 2026-10-29

### Added

- A documentation guide for host modules: `docs/reference/host-modules.md`
  states how a host builds an `ExternalModule`, registers it with the
  `externalModules` parameter of `Monty.withSession` or `Monty.checkout`,
  and how the sandbox imports and calls it. It covers the nested modules,
  the protected attributes, the `.pyi` stubs and the stub request the worker
  sends before it type checks a feed, the factories and their lifetime,
  the failures of a stub ask and what each of them leaves installed, the
  routing of the import and stub requests before the mounts and the OS
  handler, and the difference between a module and the `externalLookup`
  values of a feed, whose values outlive the map that carried them.

- The GitHub Pages site runs Python in the browser: a REPL in a JavaScript
  and a WebAssembly build, with a persistent session and a persistent
  in-memory filesystem under `/work`, typed errors, Reset, and runnable
  examples from `packages/dart_monty_web/web/examples.json` (host modules,
  the 1.2.0 standard library modules, `os.walk` and `Path.glob`, `open()`
  newlines, CSV across runs, a dataclass, type checking). Matrix pages
  measure host-feature probes and the upstream corpus in the browser.
  `tool/build_pages.py` builds the site, `bash tool/test_pages.sh --offline`
  drives every page in headless Chrome, and `deploy-pages.yml` builds on any
  ref and deploys only from `main`.

### Changed

- `ExternalModule` and the `externalModules` parameter of `Monty.checkout`
  and `Monty.withSession` now document the module contract: the public
  attributes and the protected ones, the nested modules, the host functions,
  the optional `.pyi` stubs, the shallow copy of the attribute mapping and
  the deferred conversion of a value. The claim that a module never changes
  is qualified: its attribute mapping is copied, but the mutable objects
  that mapping holds are shared with the host's own, so a host change to
  one of them reaches the sandbox the next time the value is converted, and
  a value already imported is not changed. A compact usage example shows a
  module given to a session through `Monty.withPool`.
- The `Monty` class documentation now states the whole contract of the
  module map: the map is read live, an entry is a module or a factory, a
  factory may return a future, a factory that succeeds is cached for the
  session and one that fails is not, so the next request runs it again.

- Upgraded to upstream pydantic/monty 1.2.0 (the `v1.2.0` tag). The worker
  protocol moves from version 5 to version 6: the driver now sends
  `protocolVersion` 6, the pinned worker answers it, and a worker that
  speaks a version the driver does not serve is still refused with upstream's
  `monty worker protocol error`.
- Python can import a host module: the worker asks the host for a module (the
  `import` OS call) and for the stubs of the modules it is about to type check
  (the `import_stubs` OS call), and the host answers both from the session's
  module map. A host module travels as a module value, not as a plain
  dictionary, and a module that cannot be named raises `ValueError` while a
  missing one raises `ModuleNotFoundError` in the sandbox.
- The worker can ask the host to scan a path subtree (the `scan` OS call), so
  `os.walk`, `os.scandir`, `Path.walk` and `Path.glob` see the mounted tree
  instead of an empty one.
- `open()` follows CPython's text-mode semantics as upstream 1.2.0 pins them:
  the `newline` argument is validated after the file is opened, so a missing
  file still raises `FileNotFoundError` and a write mode still creates the
  file before the `ValueError`; `None`, `''` and an explicit terminator read
  and write what CPython reads and writes.
- A restored session keeps the destination's ceilings: the dump's resource
  limits and the loader's are tightened into the stricter of the two, so a
  session loaded under a feed or turn duration limit is still bounded by it.
  Upstream 1.1.0 forgot the destination's limits; 1.2.0 keeps them.
- The browser worker module grew with the release: its gzip -9 download
  budget is 6.25 MB, and the 1.2.0 build measures 5.98 MB.

### Fixed

- A Python exception now carries its structured payload: the codec error
  fields of a `UnicodeDecodeError` or `UnicodeEncodeError` (encoding, the
  failing object, the failing range and CPython's reason) and the message,
  document, position, line and column of a `JSONDecodeError`. The host
  rebuilds the real exception from them instead of a message-only fallback.
- A string that starts with a byte-order mark keeps it. The native side sends
  Rust strings, and `String::from_utf8` keeps a leading U+FEFF, while
  package:protobuf's reader dropped it; the frame reader now decodes strings
  the way the native side does, so a BOM in a path, a file name or a printed
  line survives the round trip.

### Internal

- CI's `PARITY_PIN` moves to parity `7bfc6c1`, the suite's port to upstream
  1.2.0 and core 0.120. It handles `ExternalModule`, copies core's 1.2.0
  upstream pins, and regenerates its expected outcomes.


## 0.110.0-dev.4 - 2026-10-20

### Breaking

- `MontyValue.fromDart` converts a `Uint8List` to `MontyBytes` (a copy), at the top level and nested. A `Uint8List` handed back from `dartValue` reaches the sandbox as `bytes`, not a `list` of ints.
- `MontyValue.fromDart` throws an `ArgumentError` for the map that `dartValue` returns for `MontyNamedTuple`, `MontyTimeZone`, `MontyComplex`, `MontyFileHandle`, `MontyExceptionValue`, `MontyClassProxy` and `MontyClassTypeProxy`, at the top level or nested in a list or map. Pass the `MontyValue` itself. A map built by the caller converts to a dict whatever its keys, including a copy of such a map, as `pydantic_monty` converts every host dict.

### Added

- `MontyHostFunction.parity` and `parityCoroutine` convert host function and coroutine results under Monty 1.1.0 parity rules: `null` becomes Python `None`, and an unconvertible object raises Python `TypeError` with `Cannot convert <T> to Monty value — wrap class instances in pydantic_monty.ClassInstance(...)`.

- Export `FrameTooLargeException` from `package:dart_monty_core/dart_monty_core.dart`.

### Changed

- The package declares its API reference with a `documentation` key in pubspec.yaml, and the Markdown documentation is checked in CI.

### Fixed

- Guard worker-pool factory rollback (`_openEach`), startup cleanup (`_startAll`), startup timeout cancellation (`_ready`), and `PendingSpawn` late start/kill paths so secondary cleanup failures and losing sibling failures do not mask the primary error or escape as unhandled zone errors, recording suppressed failures in an internal bounded sink.

- Dartdoc and error text now state what the code does. Worker-location errors name `workerLocation`, the `MontyBigInt` doc gives the 2^53 boundary, and the `MontyValue`, `MontyError` and `FakeMontySession` docs match the API.

## 0.110.0-dev.3 - 2026-10-17

### Added

- The native build hook installs published worker release assets into the
  per-user cache, verifies them, and publishes them atomically with an
  installation lock and stale-staging sweep.

### Changed

- `MontyComplete.output` builds its value on every read, as upstream does, including the first. The structure of the value is still checked when the turn ends, so a malformed frame ends the session with `MontyCrashedError`. A value that fails to convert, such as a `timedelta` over 999999999 days, now throws from the `output` getter or `toString()` and leaves the session usable.

- `OSAccess` handles its arguments as upstream's `OSAccess` does. A `MontyFileHandle` is a path only for `Path.read_text`, `Path.read_bytes`, `Path.write_text`, `Path.write_bytes`, `Path.append_text` and `Path.append_bytes`, and any other call refuses it with a `TypeError` (`Path.is_symlink` answers `False` without reading its argument). `Path.mkdir` raises `AssertionError` for more than two keywords and reads `parents` and `exist_ok` by Python truthiness. The write and append calls take text or bytes in either operation and keep the type they were given.

- `dart_monty_core` now looks for a verified per-user worker cache before the
  package-relative worker when running with JIT. The cache uses `HOME` on
  macOS and Linux, `LOCALAPPDATA` on Windows, and verifies worker files with
  SHA-256 before launch.

- The `worker_mirror` user-define overrides the worker release mirror for
  build-hook installations.

A missing or unloadable bundled worker library now fails with the library path
and a remedy. The self-relaunch child exits with status 78 and names the
library.

- The package embeds the manifest of the v0.110.0-dev.3 worker release assets.
  On macOS arm64, Linux x64, Linux arm64 and Windows x64 the build hook
  installs the verified worker from the GitHub release into the per-user cache.

- Cached workers are hashed in full at installation, then later runs compare a
  recorded size, mtime, and change time fingerprint and re-hash only on a
  mismatch. On macOS and Linux, the change time additionally catches a
  same-size modification with the mtime restored. On Windows,
  `FileStat.changed` is the file creation time rather than the metadata change
  time, so the fingerprint is size, mtime, and creation time. A same-size
  Windows modification with the mtime restored is not detected until the next
  full hash.

### Removed

- `SourceRange.unknown` is no longer public. A suspension from a worker that sent no position still reports an empty file name and an empty range at offset 0, and `==`, `hashCode` and `toString()` are unchanged.

### Fixed

- A failure while preparing a host answer to a suspended call, such as a host exception whose attributes cannot be read, discards the worker and finishes the session in `feedRun`, `FunctionSnapshot.resumeAuto` and `FutureSnapshot.resumeAuto`, as upstream does.

- Dump operations now surface typing diagnostics without ending the session.

- Build hooks skip unsupported mobile targets before evaluating the worker opt-in.

- `OSAccess` raises `UnicodeEncodeError` for text with an unpaired UTF-16 surrogate when `Path.read_bytes`, `Path.append_bytes` or `Path.stat` needs its UTF-8 bytes, as upstream does. It no longer encodes the surrogate as U+FFFD.

- Restored sessions now use the dump's reported feed execution when scheduling feed deadlines.

- Convert failures while reading a called external lookup entry into Python exceptions.

- Self-relaunched AOT worker children now report an unloadable bundled worker library before exiting.

### Internal

- The DCM analysis and metrics ratchets scan `hook/` as well as `lib/` and `test/`. `hook/build.dart` has one fewer type argument and `_buildWorker` is split so it is under the line limit.

- Added a schema-1 worker artifact manifest for published worker releases.


## 0.110.0-dev.2 - 2026-10-16

### Breaking

- Replace the mounted memory filesystem with upstream's callable `OSAccess`.
  Pass it to `os:` on feeds; seed files with `String` or `Uint8List` content.
  It serves the entire virtual namespace and exposes created files through
  `files`. Files retain mutable permissions; callback reads and writes are
  settable. Names remain final and deletion is observable through a getter.
- Match upstream path normalization, binary open seeds, stat permissions and
  timestamps, Unicode write counts, and filesystem error messages. File rename
  preserves upstream's stale-path/unlink quirk; callback paths remain fixed at
  construction, including writes after directory renames.
- Migration table (old name → new name):

| Old name | New name / replacement |
| --- | --- |
| `memoryMountedOsHandler` | `OSAccess` |
| `MontyMemoryFile` | `MemoryFile` |
| `MontyMemoryFile.withContent` | `MemoryFile(path, content)` |
| `VfsFile` | `AbstractFile` (`readContent`, `writeContent`, `delete`) |
| `VfsCallbackFile` | `CallbackFile` in `unsafe_callback_file.dart` |
| `VfsReadCallback` | Inline `Object Function(String)` |
| `VfsWriteCallback` | Inline `void Function(String, Object)` |
| `VfsCallbackFile.content` | `readContent()` / `writeContent(content)` |
| `VfsCallbackFile.seededPath` | Private construction path; no public replacement |
| `VfsContent`, `VfsText`, `VfsBytes` | `Object`: `String` or `Uint8List` |
| `MountDir` (memory-backed) | Removed; the native host-directory `MountDir` (see Added) replaces it in this release |
| `MountMode` | Removed with memory mount policy |
| `resolveOpenCall` | Private implementation inside `OSAccess` |
| `mounts`, `fallthrough` | Whole namespace; compose handlers explicitly |
| Memory `writeBytesLimit`, `memoryUsageLimit`, read-only mounts | Sandbox policy moves to dm |
| Custom stat tuple construction | `StatResult.fileStat` / `StatResult.dirStat` |

- Delete the internal VFS tree, path, accounting and limit types. The unsafe
  library exports one name. CI's `PARITY_PIN` was moved in separate pin PRs after
  this change (see Internal; the final value is `ed4432a`).

### Added

- Native `MountDir` opens a host directory with overlay, read-only, or read-write access and per-feed write and memory budgets. `feedRun`, `feedStart`, and `loadSnapshot` accept `mount:`; mounts answer before the OS handler and retain their table through snapshot resumes. Browser construction throws `UnsupportedError`.
- A fresh session defaults cwd to its first mount until a feed passes type checking. Session and snapshot restores preserve their saved cwd; invalid cwd is rejected before mount-table construction without consuming the default.

- Add `MontyTelemetry` and `instrumentTelemetry` for host telemetry adapters on native and web: session, execution and suspension spans, logs, callback context, and `SuspendedSnapshot.traceContext()`. Installation lasts for the isolate; adapter failures disable only the failing signal and report once without interrupting execution.

- Reject a queued worker completion when the process exits before its request
  finishes flushing, including when process cleanup masks the pipe's write error.

- Record the 14 upstream telemetry metrics through `MontyTelemetry`, including pool lifetimes, execution and host-call durations, suspensions, print and snapshot bytes, and complete wire-frame sizes. Measurements use an explicit empty context and preserve upstream instrument metadata and attribute vocabularies on native and browser workers.

### Changed

- The `OSAccess` and `checkout` doc comments say that an in-memory filesystem is one namespace (a `..` stays inside it) and that the type check runs under the feed duration limit, so set one for untrusted source.

### Fixed

- Release feed mount tables immediately when automatic name lookup or unresolved-future resumption terminates the session. Abandoned tables also have a native finalizer backstop, including on isolate shutdown.

- Publish rebuilt native mount libraries atomically so existing mappings retain their bytes.

- Match upstream OSAccess behavior for leading UTF-8 BOMs in text reads and appends, missing rename sources with relative paths, and directly dispatched NaN sleeps with a cap.

- Browser workers deliver prints as they flush, await print callbacks before completing a turn, and apply a 4 MiB acknowledgement window when JSPI is available.
- Browser memory limits no longer charge request frames during execution or retain a turn's printed output in wasm memory. Hard allocator breaches now report `MemoryError`, as on native workers.

- Discard browser workers and release their pool slots when streamed print batches contain truncated or oversized frames.

- Keep pool worker gauges balanced when `instrumentTelemetry` is installed after pools start or while sessions are checked out.

- Deliver error, typing-error, and standalone-completion log timing attributes
  as integers to telemetry adapters, matching upstream. Preserve unsigned
  span attributes as decimal strings.

- Preserve exact telemetry integers, using decimal strings beyond ±2^53 on dart2js, and match upstream float text in OS defaults and future results.

- `MontyTime` equality and `hashCode` for aware times subtract each offset in whole seconds, as upstream does, instead of flooring it to whole minutes: `time(1, 0, 30, tzinfo=+00:00:30) == time(1, 0, 0, tzinfo=UTC)` is now true.
- `FakeMontySession` raises `TypeError` when an OS call scripted with `eager: true` that is not `asyncio.sleep` or `system.async_sleep` is answered with a plain value, as the worker session does; only the sleeps accept it.

### Internal

- Session boundary tests on the VM, dart2js and dart2wasm pin outcomes recorded from upstream 1.1.0: aggregate and input memory limits, feed and turn limits, the type-check deadline, restore of dumps of another version and of modified bytes, the limits a dump carries, and the paths an OS handler receives, and idle dumps moving between upstream and core in both directions (`tool/generate_dump_oracle.py`). `tool/check_worker_wasm_layout.py` checks that the worker module places its stack first.

- Add a native host-directory service backed by pinned upstream monty-fs 1.1.0, with per-feed overlays and budgets, capability lifetime management, and protobuf replies. Build and distribute its worker cdylib alongside the executable, resolving it through the bundled code asset or the package worker directory. No public API changes.

- Accept Firefox's "too much recursion" text for the wasm stack-overflow crash detail in the worker channel web test.

- Restore the strict VM mount-fixture adjudicator, including read-only, closed-mount and lying-handler controls. The native corpus now runs the pinned upstream mount fixtures through real host directories and `MountDir` overlays.

- Raise the test-count floors at the M6 close: unit 3173, unit (web) 6212, worker 598, worker (web) 461.

- Split native mount bindings and extend acquisition-failure, browser refusal, and platform-specific mount tests.

- CI's `PARITY_PIN` moves to parity `ed4432a`: parity: host MountDir on the VM, refused on the web; mount cases; draft M6 target (P-F2) (#47)

- CI's `PARITY_PIN` moves to parity `f944558`: P-F1: parity runner on core F-1 memory-fs names (#45). The later move to `ed4432a` supersedes it.

- Refactor telemetry rendering and callback state without changing the public API. Check adapter failure diagnostics across compilers and exercise host telemetry, lazy attributes, asynchronous methods, error encodings, and worker stream failures.

- Keep streamed-print assertions in the shared telemetry test body, and separate native turn recording and crash classification to meet code metrics without changing runtime behaviour.

- Spec tests for the codec: the arena writer and reader, Python key equality, the error family's frames and display text, structured exception payloads and the refusals a session makes before it sends.

- Restore measured VM coverage for self-relaunch arming and symbol resolution,
  and test the initial working directory of raw worker feed steps. Keep real
  unbundled-library checks isolated from process-wide native mount symbols.


## 0.110.0-dev.1 - 2026-10-15

This section gathers every change since 0.23.1 in the order it landed, including the internal groundwork that preceded the cutover. Where an earlier entry and a later one disagree, the later one and `### Breaking` describe this release. In particular: the web worker assets are `dart_monty_core_worker.{js,wasm}` (the `dart_monty_core_proto_worker` names and `tool/prebuild.sh --worker-only` belong to the groundwork); `complex` values, class types as values and file positions above 2^53 decode (no `UnsupportedError`); and an asynchronous OS handler that declines a call, `asyncio.sleep` included, raises `TypeError` in the sandbox, as upstream.

### Breaking

- Engine: Python now runs on upstream monty 1.1.0 in a worker process (native) or a Web Worker (web). The in-process 0.0.23 engine is gone. Native `dart run` and `dart test` need a worker executable, found through `workerLocation` or the usual places, until native delivery lands; an AOT program can relaunch itself as the worker with `runMontyWorkerIfChild(args)` and the hook's `build_worker` opt-in.
- `Monty` is upstream's pool: `Monty.start(...)`, `Monty.withPool(body, ...)`, `checkout(...)`, `withSession(body, ...)` and `close()`, with upstream's keyword arguments as named parameters. `MontySession` is a checked-out session: `feedRun`, `feedStart`, `dump`, `loadSession`, `loadSnapshot`, `workerPid`, `close`.
- Removed: `assignmentPattern`, `captureLastExpression`, `extractAssignmentTargets`, `isExpression`, `statementPrefixes`, `ReplContinuationMode`, `MockCallHistory`, `MockMontyPlatform`, `MontyCallback`, `MontyDataclass`, `MontyDisposedError`, `MontyException`, `MontyFutureCapable`, `MontyOpaqueKind`, `MontyPanicError`, `MontyPlatform`, `MontyResourceError`, `MontyResourceUsage`, `MontyResult`, `MontySuspensionBudgetExceeded`, `OsCallException`, `osCallNoHandlerDefault`, `ReplPlatform`, and the old `Monty` members `run`, `exec`, `typeCheck`, `scriptName` and its constructor.
- Renamed: `MontyRepl` to `MontySession`; `MontyProgress` to `MontySnapshot`; `MontyOsCall` and `MontyPending` to `FunctionSnapshot`; `MontyNameLookup` to `NameLookupSnapshot`; `MontyResolveFutures` to `FutureSnapshot`; `MontyScriptError` to `MontyRuntimeError`; `MontyCrashError` to `MontyCrashedError`; `MontyStackFrame` to `Frame`; `MontyLimits` to `ResourceLimits`; `OsCallHandler` to `OsHandler`; `MontyClassInstance` to `MontyClassProxy`; `MontyClassType` to `MontyClassTypeProxy`; `MontyOpaque` to `MontyStdTypeProxy`.
- Members of the renamed classes: `MontySession` is an interface obtained from a `Monty` pool (`checkout`, `withSession`) and ended with `close()` (was `MontyRepl(scriptName:, preamble:, limits:)` and `dispose()`); `MontyRepl.clearState`, `detectContinuation`, `scriptName`, `snapshot`/`restore` (use `dump`/`loadSession`) and the session-level `resume`, `resumeAsFuture`, `resumeNotFound`, `resumeWithError`, `resumeWithException` and `resolveFutures` are gone: a suspension is resumed on its snapshot (`FunctionSnapshot.resume`, `resumeAuto`, `resumeNotHandled`; `NameLookupSnapshot.resume`; `FutureSnapshot.resume`). `Frame` fields: `startLine` to `line`, `startColumn` to `column`, `frameName` to `functionName`, `previewLine` to `sourceLine`; its constructor, `hideCaret`, `hideFrameName`, `fromJson`, `listFromJson`, `toJson` and value equality (`==`, `hashCode`) are gone. `FunctionSnapshot.functionName` replaces `MontyOsCall.operationName` (`isOsFunction` tells the two kinds apart); `MontyPending.methodCall` is gone. Every snapshot class and `MontyComplete` lose `fromJson`, `toJson` and value equality. `MontyRuntimeError` and `MontySyntaxError` have no `excType` (use `exception.excType`); `MontyTypingError` loses `listFromJson` and its fields (use `display()`). `ResourceLimits` has no `jsAligned` or `hasEngineLimits`. `MontyStdTypeProxy` has no public constructor (was `MontyOpaque(...)`). Host answers take a `MontyValue`: `ExternalReturnValue(x)` becomes `ExternalReturnValue(MontyValue.fromDart(x))`, and `NameLookupSnapshot.resume(value: x)` becomes `resume(value: MontyValue.fromDart(x))`; a `ClassInstance`, `ClassType` or other `MontyValue` passes unchanged.
- No longer public: `createPlatformMonty`, `inputsToCode`, `toPythonLiteral`, `defaultMemoryUsageLimit`, `entryMemoryUsage`, `formatBytesPretty`, `MontyInternalError`, `VfsDir`, `VfsNode`.
- Added: `ExternalResult`, `ExternalSettledResult`, `ExternalReturnValue`, `ExternalException`, `ExternalFuture`, `CollectStreams`, `CollectString`, `SourceRange`, `ClassInstance`, `ClassType`, `runMontyWorkerIfChild`, `OsPolicy`, `TimeZone`, `RandomSeed`; `FakeMontySession` in `dart_monty_core_testing.dart`, which no longer re-exports the main library.
- Errors: `MontyError` is sealed with `MontySyntaxError`, `MontyRuntimeError`, `MontyTypingError` and `MontyCrashedError`, none publicly constructible. `message` is gone: use `toString()` (upstream's `str()`) or `exception.message`. `MontySyntaxError` and `MontyRuntimeError` carry `traceback` and `display([format])`; `MontyTypingError.display()` replaces its fields; `MontyCrashedError` has `timedOut` and `exitStatus`. Protocol violations and spawn failures are `MontyCrashedError`, so `on MontyError` catches more than upstream's `except MontyError`.
- `ResourceLimits` takes upstream's seven limits as `Duration`s and `int`s; the old fields, `toJson` and `fromJson` are gone.
- `MontyComplete` exposes only `output`; snapshots and `MontyComplete` have no public constructors.
- `OsHandler` takes and returns `MontyValue`s; a handler declines a call by throwing `OsCallNotHandledException()` synchronously, which no longer carries `fnName`. `memoryMountedOsHandler` takes and returns an `OsHandler`.
- Values: `toJson` and `MontyClassProxy.dartAttrs` are internal; `MontyValue.fromJson`, `encodeForWire`, `MontyDict.ofStrings`, `asStringMap`, `keys`, `values`, `length`, `isEmpty`, `isNotEmpty`, and `MontyClassProxy.name`, `isDataclass`, `hydrate` are gone (use `pairs` and `classType`). `MontyClassProxy` and `MontyClassTypeProxy` have no public constructors. `MontyStdTypeProxy.kind` is a `String` (`'function'` or `'type'`), `text` is `name`, and its `toString` and hash follow upstream. `MontyExceptionValue(excType, [message, attributes])` carries the exception's attributes, compared in `==`.
- Assets: the web worker is `lib/assets/dart_monty_core_worker.{js,wasm}`; `dart_monty_core_native.wasm` and `dart_monty_core_bridge.js` are gone.
- Package version `0.110.0-dev.1`, following upstream 1.1.0.

- `ExternalReturnValue` takes and holds a `MontyValue` (`const ExternalReturnValue(MontyValue value)`, `final MontyValue value`), and `NameLookupSnapshot.resume` takes `{MontyValue? value}`; both were typed `Object`. Convert a plain Dart value with `MontyValue.fromDart` first. A host object's `ClassInstance` or `ClassType` wrapper is a `MontyValue` and is still accepted.

- `MontySession.feedRun`, `feedStart` and `loadSnapshot` take `externalLookup` (upstream's `external_lookup`) in place of `externals`. It is a `Map<String, MontyValue>`, as `inputs` now is: an entry is a host function (`MontyHostFunction`, whose `fn` is called), or any other value (a `ClassInstance` or a `ClassType` among them) converted when the code reads the name and then bound as a global. A host function read by name is named by its key, its docstring kept. A call to a name whose entry is a value raises `TypeError` ("'int' object is not callable"), as upstream's does. A value the converter refuses (a cyclic list, an unpaired surrogate) fails the feed with `MontyRuntimeError` and finishes the session, as upstream discards the checkout. A builtin type in `externalLookup` (a `MontyStdTypeProxy` of kind `type`, such as `int`) called directly by name raises `TypeError`, where upstream runs the type on the host; read the name first (`t = p; t("42")`) and it runs in the sandbox, as upstream's does.

- `MontyValue` gains five subtypes, all in the value library: `MontyComplex`, `MontyClassTypeProxy`, `ClassInstance`, `ClassType` and `MontyHostFunction`. An exhaustive `switch` over `MontyValue` needs an arm for each. `MontyHostFunction` is input-only: a decoded result never holds one, so its arm may throw.
- Equality is Python's. The numeric classes (`MontyBool`, `MontyInt`, `MontyBigInt`, `MontyFloat`, `MontyComplex`) compare and hash as one tower: `MontyBool(true) == MontyInt(1) == MontyFloat(1) == MontyComplex(1, 0)`, exactly (an integer never goes through a double). A named tuple equals a tuple of the same items, a set equals a frozenset with the same members, aware datetimes and times compare by instant (a naive one never equals an aware one; `fold` is ignored), and time zones compare by offset. A set or dict built with repeated members or keys compares as Python builds it: each member once; each key once, at its first position, with its last value. NaN still equals NaN, and exception values and file handles still compare their fields.
- `MontyFileHandle(path, mode, {BigInt? position})`: positional path and mode, as upstream's constructor. The mode is parsed and stored in canonical form (`rt` is `r`); a mode upstream refuses, a path with an unpaired surrogate, or a position outside 0..2^64-1 throws `ArgumentError` with upstream's message. `position` is a `BigInt`. `toString` is upstream's repr, `MontyFileHandle(path='/x', mode='r')`.
- `MontyPath(value)` is no longer `const`: the path is normalised as `PurePosixPath` at construction, so `MontyPath('a//b') == MontyPath('a/b')`.
- `MontyClassTypeProxy` compares by class id only, as upstream's; `MontyClassProxy` compares class name, dataclass flag and attributes, not the instance id.
- `MontyDateTime.dartValue` of an aware datetime is a UTC `DateTime` at its instant (a naive one stays local from its fields). `MontyValue.fromDart(DateTime)` keeps the offset: a local `DateTime` arrives in Python with its UTC offset, a UTC one with offset zero.
- `MontyTimeDelta.dartValue` throws `StateError` when a `Duration` cannot hold the timedelta exactly, instead of truncating.
- A registered host object or class returned by the sandbox decodes to its `ClassInstance` or `ClassType` wrapper; an unregistered class sent as a value decodes to a `MontyClassTypeProxy`, and `complex` values decode, where they used to throw `UnsupportedError`.
- `resolveOpenCall` builds the handle before any side effect, as upstream: an update mode (`r+`) now raises `ValueError`, as upstream's `FileMode` does.

### Added

- Internal groundwork for running Python in a separate worker process
  (native) or Web Worker (browser) that speaks upstream monty's `monty-proto`
  wire protocol: Dart bindings generated from upstream's `monty.proto` at the
  pinned 1.1.0 commit, and the protocol's length-prefixed framing. Everything
  lives under `lib/src/worker/` and nothing is exported, so there is no new
  public API. `tool/generate_proto.sh` regenerates the bindings and CI's
  `proto-drift` job fails if the committed copy differs.
- Internal groundwork, continued: a pure-Dart driver for one Python session
  on a worker (configure with limits, feed with typed inputs, external
  function and OS call answers, print streaming, reset), and a value arena
  that keeps shared sub-objects shared in both directions and nests without
  recursion. Still under `lib/src/worker/` and not exported.
- Internal browser channel for that worker: a Web Worker runs a new committed
  asset, `lib/assets/dart_monty_core_proto_worker.wasm` (the worker crate
  built for `wasm32-wasip1` with a size-tuned profile, a 2 MiB stack and the
  Dart SDK's `wasm-opt -Os`), from a hand-written
  `lib/assets/dart_monty_core_proto_worker.js`. The page compiles the module
  once and shares it with every Worker; dispatch runs under JSPI where the
  browser supports it, with a probe and a direct-call fallback. A wasm trap,
  a kill or a protocol mismatch surfaces as a typed crash error. Still
  internal: nothing is exported. `tool/prebuild.sh --worker-only` rebuilds
  the module, `tool/check_asset_freshness.sh` now also hashes `native/worker/`,
  and `tool/check_worker_wasm_size.sh` holds it to 5.75 MB gzipped. The
  existing in-process assets are unchanged.
- Internal `ProcessChannel`: drives a worker executable over framed stdio,
  one turn at a time, and reports a dead worker as a typed
  `MontyCrashedError` (`outOfMemory` for exit 65, `fatal` for a
  `FatalError`, `vanished` for EOF, a torn frame or a signal, `killed` for
  the parent's kill) with the exit code and the last 4 KiB of stderr. The
  worker starts with an empty environment (plus `SystemRoot` on Windows).
  `tool/build_worker.sh` builds the executable into the gitignored
  `lib/src/bin/<os>-<arch>/`; it is not shipped in this release. Not
  exported. Its tests carry the `worker` tag, now excluded from the VM unit
  runs, and run in CI's `test-worker-vm` job and the gate's `worker_vm`
  step.
- CI's new `parity-e0` job runs the pinned parity suite's E0 cases through
  the worker on vm, dart2js and dart2wasm. Every counted case must match
  upstream on each backend; `complex` is deferred and reported, not counted.
  The job also runs the suite's worker crash tests: a deadline kill, a native
  stack overflow, and a wasm trap under JSPI and under the fallback. Each must
  surface as a typed `MontyCrashedError`, after which a fresh worker must
  answer. `PARITY_PIN` is now one workflow-level value, shared with the
  `parity` job.
- CI's `parity-e0` job also asserts the pinned parity suite's worker value
  rows: the value cases run through the worker on vm, dart2js and dart2wasm.
  Every pre-cutover case must match upstream. Each recorded divergence must
  differ exactly as recorded: an exception value with no argument, and a
  `KeyError` repr under a newer Unicode table. The cutover cases (complex
  values, file positions above 2^53) must run, and each negative control
  must turn a match into a difference. `PARITY_PIN` moves to that suite.
- Internal self-relaunch for `dart build cli` apps: the app runs a copy of
  itself as its worker, served by a worker library the build hook bundles.
  The hook builds that library ONLY when the root package opts in with
  `hooks: user_defines: dart_monty_core: build_worker: true` in its
  pubspec; without it the hook runs the same single cargo build and emits
  the same single asset as before. The app must call
  `runMontyWorkerIfChild(args)` first in `main`. Not exported: nothing
  outside `lib/src/worker/` can reach it yet. CI's `test-aot` job builds a
  consumer that opts in (`tool/aot_worker/`) and runs E0 case s10 through
  the relaunched worker against upstream's recorded outcome, and checks that
  the existing probe, which does not opt in, bundles one library only.
- Worker groundwork (internal, no public API): the worker's value-arena
  reader decodes every node kind upstream sends, into today's value
  classes: ellipsis, `NotImplemented`, named tuples, dates, datetimes,
  times, timedeltas, time zones, exception values, builtin types and
  functions (as `MontyOpaque`), class instances (two instances of one class
  share one `MontyClassType`), paths (normalized as `PurePosixPath`), file
  handles (canonical mode), and `repr`, `cycle` and output function nodes
  (as their text). It is as strict as upstream's decoder and no stricter:
  every node, reachable or not, is checked with upstream's rules and
  messages, then the references, then the rules of the Python objects
  upstream builds (dict keys and set members collapse as Python's do and
  must be hashable; named tuples need valid names and lengths; timedeltas
  stay within 999999999 days). A failure is a `FormatException`. A
  `complex`, a class type as a value, and a file position an `int` cannot
  hold exactly (above 2^63-1, or 2^53 on dart2js) have no value class yet;
  reaching one is an `UnsupportedError`. `tool/generate_proto.sh` declares
  `Type.origin` as `int32` (a fifth substitution), so an unknown origin
  number reaches the reader as sent.
- Worker groundwork, continued (internal, no public API): the arena writer
  sends every kind the worker accepts as input (ellipsis, `NotImplemented`,
  named tuples, dates, datetimes, times, timedeltas, time zones, exception
  values, builtin types and functions, file handles, class instances), and
  shares nodes as upstream's encoder does: containers and class instances
  once per Dart object across every `add`, leaves fresh at each reference,
  and an attribute-less class once per class id. It refuses with
  `ArgumentError`, before anything is sent, what the worker would reject or
  protobuf would silently change: bytes outside 0..255, strings with an
  unpaired surrogate, out-of-range dates, times and offsets, a zone name
  without an offset, unnormalized timedeltas, unknown exception, type and
  builtin names, invalid file modes and positions, named tuples Python
  could not build, and dict keys or set members Python could not hash. As upstream does, an exception message with an unpaired
  surrogate is converted lossily (a `KeyError`'s as its `repr`) and such a
  time zone name is dropped, keeping the offset. Values that used to be
  memoised wholesale now follow upstream's sharing, so a leaf referenced
  twice is two nodes. `MontyValue.fromDart` is unchanged. The reader takes
  an internal hook through which a registry of host objects can resolve
  class and instance nodes to registered objects.
- Worker groundwork, continued (internal, no public API): every frame from
  the worker is pre-scanned with upstream's decoder rules before
  package:protobuf parses it, on both channels. A frame upstream rejects is
  now rejected here too, and the worker is discarded as a `vanished` crash.
  That covers malformed or overflowing varints, field keys beyond 32 bits, a
  known field with the wrong wire type, invalid UTF-8 in any string, nested
  unknown groups past prost's recursion limit, an invalid node anywhere
  (including in an event arm a later arm replaces), a `FunctionCall.object_id`
  that is not 16 bytes, and a frame whose decoding would exceed upstream's
  1 GiB allocation budget. The budget is charged as upstream charges it.
  Two kinds of value that package:protobuf would misread are rewritten in
  place first: a boolean whose low 32 bits are zero but which is not zero,
  and a `PrintStream` number no member names. Strings keep a leading U+FEFF,
  which Dart's UTF-8 decoder would drop, and a function call's position
  filename is cut to 256 bytes, as upstream's decoder cuts it. Unknown
  fields are dropped before the parse, as prost drops them, so they cannot
  make the parent hold memory upstream's budget never counted. An outbound frame's length is
  now computed before the frame is encoded. An oversized request throws
  `FrameTooLargeException` without the body being built, and nothing is
  sent.
- Worker groundwork (internal, no public API): a pure-Dart worker pool
  following upstream `monty-pool`'s lifecycle on every backend. It starts
  `minProcesses` workers and fails fast; it reuses idle workers, discards
  ones that died idle, reserves a slot before spawning, and waits up to a
  checkout timeout at `maxProcesses`. Releasing sends `Reset` and returns
  the worker, or retires it after `maxCheckoutsPerWorker`. Each checkout
  holds one single-use lease, so its slot is given back exactly once. A
  worker not ready within 30 s is cancelled and fails as
  `MontyCrashedError`, which covers a Web Worker that loads but never
  greets. Closing the pool refuses new checkouts and reaps idle workers; a
  checked-out worker is killed when released. One conditional import picks
  the channel: a process on native, a Web Worker on the web. On the web the
  Worker's assets are found in Flutter's layout, then the package's, with
  no init call. The web default for `maxProcesses` is
  `navigator.hardwareConcurrency` (4 when the browser hides it). Not
  exported until the API cutover.
- The internal `ProcessChannel` bounds its read-ahead. Past 4 MiB of
  received, unread frames it stops reading the worker's stdout, so a
  worker that prints faster than it is read blocks on its pipe, as under
  upstream's pool. The frame being received when the limit is reached
  always completes, and frames that arrive between turns stay queued for
  the next one.
- Worker groundwork (internal, no public API): a port of upstream's
  traceback renderer, `display()` in its three formats (`'traceback'`,
  `'type-msg'`, `'msg'`; any other format is an `ArgumentError` with
  upstream's text) over the frames a raised exception carries on the wire.
  It keeps upstream's rules: more than 3 identical consecutive frames
  collapse into `[Previous line repeated N more times]`, the caret padding
  counts a stripped non-ASCII indent in UTF-8 bytes, a span over several
  lines prints its block without carets, and an absent message renders as
  `Type` where an empty one renders as `Type: `. Checked byte for byte
  against pydantic-monty 1.1.0's own renderings of the parity suite's 19
  display cases on the VM, dart2js and dart2wasm; CI's `parity` job checks
  the baked cases (`tool/generate_display_fixtures.py`) against the pinned
  suite.
- Internal session mechanics over the worker pool, in the shape of
  upstream's `AsyncMonty` and `AsyncMontySession`. Nothing is exported
  until the API cutover.
  - A pool can be started, checked out and closed; `withPool` and
    `withSession` close what they open on every exit path. Each takes
    one internal options record for now.
  - `feedRun` takes inputs, host functions and OS calls. Feeds on one
    session are serialized as upstream's are. A second feed waits for
    the turn in flight, then runs if the first feed has finished. It
    fails if the first feed is suspended on a host call, or if the
    session has closed.
  - Closing a session sends `Reset` and returns its worker to the pool.
    If a host callback is running at the time, the call fails as finished
    at once; the callback is not interrupted, and its result is dropped.
    A turn in flight is killed.
  - `requestTimeout` bounds each protocol turn, print delivery included,
    but never host callbacks. Upstream's feed and turn duration backstops
    apply to execution turns.
  - A worker that exits with code 65 surfaces as a `MemoryError` and ends
    its session.
  - Upstream's suspension budget is enforced. Past `maxSuspensions` host
    calls (1000 by default) the feed is aborted with an in-sandbox
    `RuntimeError`.
  - A `time.sleep` is waited by the session itself. It is cut to the OS
    policy's maximum, which is 10 s by default.
  - Type checking and the OS policy are passed through to the worker as
    internal records until their public shapes exist. A type-check
    rejection does not end the session.
  - Print callbacks may be async. Each one is awaited, in order, before
    the next event is read. With no callback, printed text goes to the
    process's own stdout and stderr on native (written non-blocking, each
    flush awaited) and to the console in a browser.
  - CI's `parity-e0` job also runs the pinned parity suite's E0 cases
    through the session on vm, dart2js and dart2wasm. Every counted case
    must match upstream on each backend. `PARITY_PIN` moves to the suite
    that adds the session engine.
- Worker groundwork (internal, no public API): upstream's four session
  settings types, `ResourceLimits`, `OsPolicy`, `TimeZone` and `RandomSeed`,
  replace the session's internal records. Nothing is exported until the API
  cutover.
  - Literals are strings, durations are `Duration`s, and a field that is a
    mode or a value is two parameters (`datetime` and `fixedDatetime`,
    `timezone` and `fixedTimezone`, `randomStart` and `randomSeed`).
  - Each setting upstream refuses is an `ArgumentError` with upstream's
    message, raised at checkout before a worker is taken: negative limits
    and durations, unknown modes and type-check formats (ASCII case
    ignored, as upstream), `sleepSystemMax` with a sleep mode other than
    `'system'`, a fixed zone a day or more from UTC, a non-finite float
    seed, an assert-annotation length outside 0..2^32 - 1. An IANA zone
    name is resolved by the worker; one it does not know is an
    `ArgumentError` carrying the worker's refusal.
  - A frozen clock also sets the sandbox's zone, as upstream's: UTC for a
    UTC `DateTime`, else the `DateTime`'s own offset and zone name, unless
    a zone is given.
  - `maxTotalSleep` is enforced by the session, as upstream's pool does:
    each system sleep is charged at its capped length, in nanoseconds,
    before it is waited, and the one that would pass the limit aborts the
    feed with an uncatchable `TimeoutError` ("sleep limit exceeded: 150ms >
    100ms", in Rust's `Duration` format).
  - Checked against pydantic-monty 1.1.0 on 55 cases (one per refusal, and
    each policy field's effect in the sandbox: frozen clocks and zones,
    seeds of every kind, call-host modes, the process clock, sleep modes
    and the sleep budget), on the VM, dart2js and dart2wasm.
    `tool/generate_config_oracle.py` records the cases.
  - `PARITY_PIN` moves to the parity suite that builds the worker's limits
    as `ResourceLimits`.
- Worker groundwork (internal, no public API): upstream's error family
  for sessions, `MontyError` (sealed) with `MontySyntaxError`,
  `MontyRuntimeError`, `MontyTypingError` and `MontyCrashedError`, and
  `Frame`. The worker path throws them in place of `MontyScriptError`, the
  internal typing error and the internal crash error; today's public errors
  are unchanged until the API cutover.
  - `message` and `toString()` are upstream's `str()`: `Type: message` (or
    `Type`) for a runtime error, the message for a syntax error, the
    rendered diagnostics for a typing error. `exception` is upstream's
    `exception()`, with `''` for an absent message; a crash's is
    `RuntimeError`. Syntax and runtime errors carry `traceback` (`Frame`s)
    and `display()`; a typing error's `display()` is the worker's rendering.
  - `MontyCrashedError` has upstream's `timedOut` (any deadline kill:
    "monty worker killed after exceeding request timeout of 500ms") and
    `exitStatus` (the exit code the OS reported; `null` for a signal or a
    kill), and upstream's message: "monty worker crashed: <reason>" for a
    worker that announced its end, "monty worker crashed while waiting for
    a reply" for one that vanished, each with the exit status
    ("(exit status: 1)", "(signal: 9 (SIGKILL))") when known.
  - A worker that answers against the protocol is discarded and the call
    throws `MontyCrashedError` with upstream's message, "monty worker
    protocol error: ...": an event that cannot follow the request, an
    `Error` with no exception, a result that does not decode, and a raised
    exception that fails upstream's checks (an unknown type, a frame
    without both positions, an end column before the start or more than 2
    past a one-line preview). Upstream raises a plain `RuntimeError` here;
    this is the one place `MontyError` catches more.
  - Checked against pydantic-monty 1.1.0: each of the parity suite's 19
    display cases now also compares the error class, `str()`,
    `exception()` and every `Frame` with upstream's, on the VM, dart2js
    and dart2wasm (`tool/generate_display_fixtures.py` bakes them); a
    rejected snippet's rendering in the `full`, `concise`, `json` and
    `jsonlines` formats, and a `requestTimeout` kill's fields, against
    real workers on the three compilers.
  - `PARITY_PIN` moves to the parity suite whose worker engine records
    the error family's errors.
- Internal session failure paths, following upstream's pool binding.
  Still not exported.
  - A print callback that throws no longer kills the worker at once. Later
    text is not delivered to it, the turn is read to its end, and then the
    callback's error is thrown in place of the turn's outcome, a Python
    exception or a crash included. The session runs on after a turn that
    completed or raised. It is discarded when the turn ended suspended on a
    host call, which no one would then answer.
  - A close while a host callback runs now fails the pending call at once,
    instead of when the callback returns; the callback's late result is
    dropped.
  - A request over the 256 MiB frame limit is refused before it is sent,
    with `MontyRuntimeError` (`RuntimeError: request frame of N bytes
    exceeds the maximum of M bytes`). Oversized inputs leave the session usable. An oversized
    answer from a host function leaves the suspension pending: later feeds
    fail with `StateError` until the session is closed, which resets the
    worker.
  - New tests gate the session's failure paths on the VM, dart2js and
    dart2wasm, against the real worker on native and in the browser:
    - a print callback that never completes, ended by `requestTimeout` and
      by `close`, after which the freed slot serves a new checkout;
    - `close` during a turn (after `feedRun(...).timeout`), during a host
      call that never returns, and twice.
    On native, two more gates:
    - a stalled callback holds the worker's output at the 4 MiB read-ahead
      bound;
    - with no callback and the app's own stdout left undrained, timers keep
      running, and `requestTimeout` and `close` still end the stalled call.
- Internal step-by-step driving of a pool session, in the shape of
  upstream's `feed_start` and its async snapshots. Nothing is exported
  until the API cutover.
  - `feedStart` returns at each suspension: a function snapshot (a host
    call or an OS call, with its name, arguments, call id, eager-await bit
    and source position), a name-lookup snapshot or a future snapshot, or
    the completion. Each is resumed once: with a value, an exception or a
    future; as not handled (OS calls); or automatically from the feed's
    host functions and OS handler. An answer is checked before the
    snapshot is spent, so a refused one leaves it resumable. While a
    snapshot is unanswered the session refuses a new feed, as upstream's
    does.
  - Pending futures settle incrementally: a future snapshot takes results
    for some of its call ids and reports the rest again.
  - Host functions can be coroutines. One the sandbox awaits with nothing
    else to run is awaited in place; any other gets a pending future,
    settled as it completes. `asyncio.sleep` is waited the same way, so
    gathered sleeps overlap.
  - The OS handler gets every OS call with upstream's name and arguments,
    not only the path calls, except the system sleeps a `feedRun` waits
    itself (a snapshot's `resumeAuto` hands those to the handler too); a
    handler's future is awaited and its value is the answer, except for
    `asyncio.sleep`.
  - The sleep budget now charges `asyncio.sleep` as well as `time.sleep`,
    as upstream's pool does, and a worker reply can tighten the suspension
    budget too. The suspension budget counts snapshot turns.
  - A manual answer too large to send fails with upstream's
    `RuntimeError`; the snapshot is spent and the call stays pending.
  - Closing a session ends its sleeps at once, a running `feedRun`'s as
    well as a held snapshot's: no timer outlives the session, and the feed
    fails as finished.
  - An async OS handler that declines `asyncio.sleep` (null, or
    `OsCallNotHandledException`) leaves the sleep's `None`; it no longer
    raises `RuntimeError`.
  - CI's `parity-e0` job asserts the parity suite's C1 gate through the
    session on vm, dart2js and dart2wasm, now with the snapshot, futures,
    OS-call and budget rows. `PARITY_PIN` moves to that suite.

- `MontySession.installDependencies(requirements)`, upstream's `install_dependencies`. Core's worker is the pure-Monty sandbox, which has no host interpreter to install for, so an empty list succeeds and any other list throws `MontyRuntimeError` (`RuntimeError`: "dependency installation is only supported by the CPython worker") and the session runs on. As upstream's pool checks first, a blank requirement, or one that starts with `-` after trimming, throws `MontyRuntimeError` (`ValueError`) with upstream's text, and one with an unpaired surrogate throws `ArgumentError` (upstream's `UnicodeEncodeError`). While a suspension is unanswered it throws `StateError`. `FakeMontySession` answers the same way. Outcomes are recorded from upstream by `tool/generate_session_oracle.py`.

- `feedRun` and `feedStart` take `cwd` (upstream's `cwd`): the sandbox's working directory, switched before the code runs and kept across feeds. A relative path or one with a NUL throws `MontyRuntimeError` (`ValueError`, upstream's text) and the session runs on; one with an unpaired surrogate throws `ArgumentError`.
- `coroutine` is exported: it marks a host function as an `async def` function, whose calls the sandbox awaits (`asyncio.gather` runs them at once).
- `HostClass` is exported, so a `ClassInstance` or `ClassType` can be built from the public library.

- `MontyComplex(real, imag)`, `MontyHostFunction(name, fn, {docstring})`, and `MontyFileHandle.binary`, `.readable` and `.writable`.

### Changed

- New runtime dependencies: `protobuf` (^6.1.0) and `fixnum` (^1.1.0). The
  bindings are reachable from no public library, so compiled web apps do not
  grow until a public path uses them.
- Tooling only, no library change: `tool/check_export_boundary.dart` now
  also records the public members of every declaration the exported names
  reach in `tool/export-golden.txt`. Each declaration is listed once, under
  the library that declares it. The record covers kinds, modifiers (`const`,
  `factory`, `static`, class modifiers), type parameters and bounds,
  supertypes, a sealed class's subtypes (private ones included), whether a
  field has a setter, and each parameter's position, name, type and
  default. A type is named with its library wherever the name alone could
  mean another declaration. A change to any of them now fails the check
  until the golden is updated. The tool prints signatures itself from the
  analyzer's element model, so an analyzer upgrade does not change the
  golden through formatting.

- A worker that cannot start throws `MontyCrashedError` with upstream's text,
  `failed to spawn monty worker: <detail>` (`timedOut` false, `exitStatus`
  null). This replaces the `ProcessException` from a native launch and the
  `StateError` raised when no worker executable or web asset was found.
- A checkout that waits past `checkoutTimeout` throws `TimeoutException` with
  upstream's fixed message, `no monty worker became available within the
  checkout timeout`. The limit is still on `TimeoutException.duration`.
- When a worker frame does not decode, the `MontyCrashedError` text now matches
  upstream's: `monty worker protocol error: invalid payload from worker:
  failed to decode Protobuf message: <fields>: <reason>`.
- A host call whose argument arena upstream rejects is a protocol violation
  when the call suspends. `feedStart` and `resume` throw `MontyCrashedError`
  and do not return a `FunctionSnapshot`. Before, the snapshot's `arguments`
  threw `FormatException` when read.

### Fixed

- Worker groundwork (internal, no public API): the value writer now sends a
  class met again through its own attributes (a class constant that is an
  instance of the class) as the class without attributes, as upstream's
  encoder does, instead of refusing it as a cycle. A named tuple's field
  names are sent as they are, `rename=True`'s `_0` included, since upstream's
  encoder and worker accept any names; only a value count that differs from
  the field count is refused, with the worker's message.
- Worker groundwork (internal, no public API): an exception value without a
  message is sent with an argument, as upstream's encoder sends `str(exc)`:
  `''`, so the sandbox sees `RuntimeError('')`, not `RuntimeError()`; for
  `SyntaxError`, `'None'`. `PARITY_PIN` moves to the parity suite that
  asserts this case (`i_exception`) as a match.
- Worker groundwork (internal, no public API): integers and floats in the
  worker's value arena are now exact. `tool/generate_proto.sh` declares four
  fields of its working copy of `monty.proto` with raw 64-bit types
  (`MontyNode.int` as `uint64`, `MontyNode.float`, `Complex.real` and
  `Complex.imag` as `fixed64`; the wire bytes are unchanged), and the arena
  reader and writer do the conversions package:protobuf got wrong: zigzag
  with a logical shift, so `2**63 - 1` no longer arrives as `-1` and every
  integer of magnitude 2^62 or more decodes exactly; and doubles through
  their bits, so a NaN from Python keeps its sign and payload there and
  back (on dart2js, a Dart double cannot be relied on to show them, but a
  NaN passed back to Python keeps the bits it arrived with). A NaN made in
  Dart, such as `double.nan`, is sent as Python's `float('nan')`, whatever
  the host's own NaN bits are. A big integer's
  magnitude converts in one step instead of one shift per byte (1 MiB:
  minutes before, about 0.2 s now). On dart2js, a `MontyInt` outside the
  64-bit range is now sent as a big integer instead of being truncated.
- `MontyValue`'s `==`, `hashCode`, `toJson` and `dartValue` no longer hang on
  shared values or overflow the stack on deep ones. A value whose parts are
  shared, as `x = [x, x]` repeated in Python makes it, used to cost 2^d (24
  levels took 0.3–3 s, 40 hung); 10,000 levels of nesting overflowed the
  stack (2,000 on dart2js). Each operation now recurses within a budget (400
  levels, 2^22 visits) and past it continues as a memoised walk on an
  explicit stack: a 10,000-level shared value takes a few milliseconds and
  100,000 levels of nesting tens of milliseconds. On ordinary values the
  results are unchanged, including hash values, except that a set's hash now
  mixes each element's hash before summing. `toJson` and `dartValue` build a
  shared part once, so it is one object in the output (`json.encode` of that
  output still writes it out each time). Attribute maps compare their
  entries as before, whatever the maps' own key equality. A value a host
  builds to contain itself equals itself; otherwise `==`, `hashCode`, `toJson` and `dartValue`
  on it throw `StateError`. Work is not bounded for crafted values: many
  colliding hashes, or equal values shared differently on alternating levels.
- `MontyValue.fromDart` no longer recurses, so deep `List`s and `Map`s
  convert; a Dart object reached twice becomes one shared value, and a `List`
  or `Map` that contains itself is an `ArgumentError` instead of a stack
  overflow. `-0.0` and the infinities become `MontyFloat` on dart2js too
  (they became `MontyInt` there, including in callback return values). A `DateTime` keeps its milliseconds;
  only the microseconds within the millisecond were kept.
- `MontyClassInstance.toString` shows the class name and attribute count
  instead of every attribute, which expanded shared values and overflowed on
  deep ones.
- Worker groundwork (internal, no public API): the wasm module frees the
  previous turn's reply before running the next one, so it no longer counts
  against that turn's `max_memory` (two consecutive large replies raised a
  spurious `MemoryError`). `tool/check_worker_mirror.py` now accepts a
  source-less `Cargo.lock` entry only for the worker crate itself, checks
  the monty crates' crates.io checksums, and rejects `[patch]`/`[replace]`,
  path/git dependencies and cargo-config source overrides. The protoc plugin
  is compiled from a committed lockfile (`tool/proto_gen/pubspec.lock`).
- The committed wasm no longer embeds build-machine paths:
  `lib/assets/dart_monty_core_native.wasm` carried the builder's
  absolute cargo paths in its panic locations. Both wasm recipes now remap
  them through `tool/rust_remap.sh` (the in-process one lives in the new
  `tool/build_native_wasm.sh`, and both are hashed into the asset
  provenance). `tool/test_wasm.sh` and `tool/serve_demo.sh`, which also
  write `lib/assets/` when run without `--skip-build`, now build through
  that recipe. `tool/check_asset_freshness.sh` fails if any
  `lib/assets/*.wasm` contains a home-directory path or a Rust source path
  outside the remapped prefixes. Behaviour is unchanged.

- `dart compile wasm` no longer aborts with "Conversion between non-reference
  types (from f64 to i64)" in an app that reaches the worker pool's value
  conversion. The pool's check for an unpaired surrogate is written as a loop
  in place of a tear-off passed to `Iterable.any`, which the Dart 3.13.5 wasm
  compiler could not compile. Behaviour is unchanged.

- A host function or method call whose argument arena upstream rejects (a node referencing one not below it, a class instance whose class is no class type, an argument or keyword root outside the arena) now ends the feed with `MontyCrashedError` (`monty worker protocol error: invalid payload from worker: <detail>`) and discards the worker, as upstream's conversion on arrival does. It used to raise `Exception` in the sandbox and keep the worker. A failure building the Python values from a valid arena still fails the call in Python.
- An OS call with no arm, or a `getenv` with no arena or a default root outside it, is a protocol violation in `feedRun` too (`monty worker protocol error: invalid OS call payload: <detail>`), with upstream's detail text (`missing required field OsCall.call`, `missing required field OsCall.values`). `feedStart`'s message no longer repeats the `invalid OS call payload` prefix.
- An OS handler's `Future` that fails with `OsCallNotHandledException` raises `TypeError` with upstream's conversion-refusal text, naming the Dart classes: `Cannot convert OsCallNotHandledException to Monty value — wrap class instances in ClassInstance(...)`.

- Closing a busy `MontySession` fails the call in flight with `MontyCrashedError` reading `monty worker killed: the session was closed during a turn`; the message used to omit that the worker was killed.
- `FakeMontySession.willRaise` checks each attribute value as the wire writer does, and throws `ArgumentError` at the call for a value a worker could not send (a string with an unpaired surrogate, say), as `willReturn` and `willCall` already did.

- A host function, OS handler or print callback that throws `ExternalException('SyntaxError')` with no message now raises `SyntaxError: None`, as upstream reads `str(SyntaxError())`; a thrown object whose `toString()` throws now raises `Exception` with no message. A print callback's `json.JSONDecodeError` keeps its `msg`, `doc`, `pos`, `lineno` and `colno` as given, a `pos` past `doc` too, as upstream keeps a live exception's.

### Internal

- `AGENTS.md` is rewritten for the worker stack: fresh-clone commands, which test command for which change, test-count floors, the gates CI does not run, generated files and the oracle recipe, baselines and pins, and the toolchain pins. `CLAUDE.md` now imports it with `@AGENTS.md`.

- The old engine's CI jobs, scripts, crate and bindings are deleted; the parity, AOT, gate and coverage jobs run on the worker; the export boundary runs its post-cutover rule; the worker crate's dependencies pass `cargo deny`, with BlueOak-1.0.0 allowed for `minicbor`.

- Consumer startup probes (`tool/consumers/`): a plain Dart web app and a
  Flutter web app depend on the package by path, start the worker pool with no
  `workerLocation` and no init call, run `1 + 1` in headless Chrome and assert
  `2`, on dart2js, dart2wasm, `flutter build web` and `flutter build web
  --wasm`. A driver fails a build whose worker assets are missing or served
  from the wrong base. They run in the `Consumer startup` workflow on the
  paths they cover and nightly; the Flutter SDK is pinned to a release that
  bundles the repo's Dart, and `tool/check_sdk_pin.sh` checks it.

- The upstream pydantic-monty 1.1.0 test corpus (643 files, pinned by the git tree hash in `tool/upstream/upstream-pin.json`) runs on the worker: one session per file through the pool, judged by the strict adjudicator, on Linux and macOS natively and in Chrome and Firefox under dart2js and dart2wasm. Every file the worker fails is listed in a manifest with a divergence ID, and a run fails on any difference from it. A crash test kills a worker and checks the same one-worker pool serves the next checkout. The old corpus runner is untouched.

- The `spec_values_*` tests pass DCM again (the local `tool/dcm_ratchet.sh` gate): locals replace repeated constructions, list destructuring replaces indexed access and `.single`, and a small `spec_values_support.dart` holds two helpers. The tests assert exactly what they did before.

- Worker sessions dump and load, as upstream's async session does: `dump` on a session (idle or suspended) and on a suspended snapshot, `loadSession` for a dump taken between feeds, and `loadSnapshot` for one taken mid-feed, which returns the re-announced suspension under the dump's script name. A load is only for a fresh session; the wrong kind of dump finishes the session; bytes the worker cannot load are refused and the session runs on. The dump brings its own globals, limits, type check and working directory: the next feed keeps the dump's directory, and a typing rejection after a load is a `MontyTypingError` whatever the session's own type check. As upstream, the session's suspension and sleep limits stay as ceilings on the dump's and both counts restart, while its feed and turn duration budgets are forgotten and the dump's adopted (O9). A dump runs between a feed's protocol turns, so a host function may dump its own session while its call waits; it keeps a pending suspension pending. `workerPid` is the worker's process id (null on the web). A session collected without `close` has its worker killed and its slot freed by a best-effort finalizer. The cases are checked against real workers on the VM, dart2js and dart2wasm, with outcomes recorded from upstream by `tool/generate_restore_oracle.py`. Internal until the cutover.

- Worker sessions read a raised Unicode or JSON decode error's structured data into its exception's attributes, sanitised as upstream drops a bad payload (the Unicode range rule, 64 KiB caps, zero line or column, a position past the document). Without its data such an error reads as `ValueError`, as upstream's host object does. Attributes take part in `==`, `hashCode` and the value walk's budget. Internal until the cutover.
- `ExternalException(excType, [message, attributes])` (internal): a `json.JSONDecodeError`'s `msg`, `doc`, `pos`, `lineno` and `colno` are sent as upstream sends a live exception's (a `doc` over 64 KiB left out); other types' attributes stay on the host. It has value equality and can be thrown from a host function.
- The writer's refusals that Python makes too surface by path as upstream's binding does: a cycle (`ValueError: Circular reference detected`) or an unpaired surrogate (`UnicodeEncodeError`) throws `MontyRuntimeError` at an input or a manual resume, which leaves the snapshot retryable, and is raised in the sandbox for an automatic answer. Values Python cannot build stay `ArgumentError`s.

- `FakeMontySession`, a scriptable session for testing host code without a
  worker, is built internally (`lib/src/fake_monty_session.dart`); the
  testing library exports it at the cutover. A test queues what each feed's
  Python does (host calls, OS calls, name lookups, awaits, prints, and the
  end), and the session's own driver answers each suspension as it would
  against a worker; the fake records the feeds and the host's answers.
- A contract suite (`test/contract/`) runs each scenario as Python on a
  worker-backed session and as a script on the fake, and requires the same
  host calls, prints, snapshots, answers and end on both, on vm, dart2js and
  dart2wasm.

- Worker sessions send `Feed` as upstream's pool does: the first feed of a session (and the first after a reset, or after a feed the type check refused) switches the sandbox to `/`, later feeds keep the working directory (`os.chdir` included), the input arena is always sent, and an input at index zero no longer carries an explicit zero. A request's encoded size, and so an oversized request's message, now matches upstream's.

- The default-sink stall probe and the flood test under a full stdout no longer assert a read-ahead peak under twice the limit. Reading pauses between deliveries of the worker's stdout, and the VM can hand over about 4 MiB as one delivery, so a valid peak reached 8.5 MB on a loaded runner. They now assert the bound the pause logic gives: the limit plus twice the largest delivery and twice the largest frame, recorded by the channel. The channel's documentation states that bound.

- The worker-channel test "a descendant writing after the worker exits stays
  bounded" no longer times out on a loaded machine. Its fake worker exited
  after a fixed 2 s, so a descendant slower to start than that plus the drain
  grace had written nothing when the drain ended, and the test waited for a
  read-ahead that could not arrive. The fake worker now exits only once the
  descendant has written 3 MiB, and the descendant starts late on
  purpose so the test covers the slow case every run. The channel itself is
  unchanged.

- CI: the export-boundary self-test (about 10.5 of the `gate · source-only · no-browser` job's 11.5 minutes, which kept hitting its 12-minute limit) runs as six parallel `gate · export-boundary self-test (shard N/6)` jobs. `tool/check_export_boundary.dart --self-test --shard <i>/<n>` runs the controls at positions congruent to `i` mod `n`; the shards are every control exactly once, and the job fails if the matrix is not six shards. The source-only job now asserts 24 checks and has an 8-minute limit; `tool/gate.sh` still runs the full self-test (step count unchanged).

- `hook/build.dart` builds the opted-in worker library (`build_worker: true`)
  whether or not the in-process crate's `native/Cargo.toml` is present, and
  declares `native/rust-toolchain.toml` as one of the worker's own inputs.
  Consumers that do not opt in see no change.
- The coverage ratchet reports a baseline file that the change deletes
  (`git diff --diff-filter=D` against `RATCHET_BASE_REF`) as `DELETED`, not
  `VANISHED`, and compares the lib-wide total with the baseline's total over
  the files the change keeps. `--self-test` runs its controls, in the gate and
  in CI.
- CI's `Dart test (JIT)` job and the gate's `unit_tests` step provide the
  worker executable first, so an untagged unit test may start a real pool.

- `tool/generate_os_handler_oracle.py` records upstream's outcome for 24 OS-handler cases (sync and async declines, async values and raises, across file, env, clock and sleep calls) into `test/unit/worker/_os_handler_oracle.g.dart`; the pool suites run them on the VM, dart2js and dart2wasm.

- Worker sessions answer host code as upstream's async binding does. The OS handler (`OsHandler`, internal) takes and returns `MontyValue`s: a returned `MontyNone` is `None`, and it declines only by throwing `OsCallNotHandledException`, which sends upstream's `not_handled` arm so the worker raises the call's own default (`PermissionError` naming the path for a filesystem call, `RuntimeError` for the rest). Only a synchronous throw declines, as only a synchronously returned `NOT_HANDLED` does upstream: a returned future that fails with it raises `TypeError` in the sandbox, as upstream's coroutine returning `NOT_HANDLED` does (`asyncio.sleep` included, which used to read the decline as `None`). A thrown `ExternalException` raises its type, with an empty message when it has none, as a raised Python exception always carries one; a manual resume without a message still sends none, as upstream's `{'exc_type': ...}` form does. An unknown `excType` is an `ArgumentError` at a manual resume, and thrown from host code it is raised as any other throw. Any other throw now raises `Exception` with its text (was `RuntimeError`), the class upstream gives a host exception with no built-in counterpart. Internal until the cutover; the public `OsCallHandler`, `OsCallException` and the FFI/WASM paths are unchanged.

- Host objects for the worker sessions: `ClassInstance` and `ClassType` wrappers (pydantic-monty 1.1.0's policies: eager and lazy attributes, allowed methods, construction, the `convert_value` hook) over a `HostClass` that names a Dart class's members, and a per-session registry that routes the sandbox's method calls and lazy attribute reads to them, with upstream's member guard, alias and restore rules. A lazy attribute that raises now raises in the sandbox, closing the worker corpus's `lookup-cannot-raise` divergence. The wrappers compare and hash by identity (divergence `host-wrapper-identity-eq`: upstream's compare fields and are unhashable). Internal until the cutover.

- The local gate is green again on `main`. `FakeMontySession` keeps its public
  API with its scripting methods and its lifecycle in two private classes, so
  it is back under the class method-count limit; the worker fixture reads its
  `writer` arguments with a pattern in place of an unchecked index. No
  behaviour changes.

- Unit tests in `test/unit/mount/` now cover the lines only the mount-fs corpus adjudicator reached: `mkdir(parents=True)` through a file raises `NotADirectoryError`, renaming a directory moves its descendants' memory charges, and `OsCallNotHandledException.toString` in both of its shapes. Test-only; no library change.

- `tool/check_oracles.sh` runs `--check` for every `tool/generate_*_oracle.py`, found by glob, in a cached Python 3.12 venv with the pydantic-monty version from `tool/upstream/requirements.lock`. `tool/gate.sh` runs it as step `oracle_check` and CI runs it in the `upstream-pin` job, so a stale oracle `.g.dart` fails both instead of being caught by hand.

- CI's `PARITY_PIN` moves to parity `399676d`, which records an exception's structured data through the worker and session engines and lands the C3-4 gate stage.

- The parity suite pin moves to the commit that adds the C3-4, C3-5 and C3-6
  cases: writer refusals, `ExternalException` and `OsPolicy`, and the
  suspension and sleep budgets, each checked against upstream 1.1.0.

- The worker pool and session settings (unexported until the cutover) match
  pydantic-monty 1.1.0. Closing a pool lets a checkout already waiting or
  starting finish, on a worker released after close if there is one; a
  worker released with no checkout waiting is killed. A negative
  `minProcesses` or `maxProcesses`, a negative
  `checkoutTimeout`, `requestTimeout` or duration-limit grace is an
  `ArgumentError` at pool start, and `maxCheckoutsPerWorker` takes
  0..2^32-1 (0 retires a worker at its first release). An unknown IANA zone
  name is refused before any worker is taken, checked against the host's
  zoneinfo directory where a native worker reads one, else a generated list
  of the zones every worker's tz database holds
  (`tool/generate_tz_names.py`, checked by the gate and CI); an `Error`
  reply to `Configure` is raised as any error is. A `TypingError` event is
  `MontyTypingError` whatever the session's type check. A whole frame that
  does not decode is a protocol violation (`monty worker protocol error:
  invalid payload from worker: ...`), not a lost worker. A closed idle
  worker gets upstream's 500 ms to exit. `TimeZone` reports an offset
  outside `i32` and an unencodable name as upstream does; an integer and a
  float `RandomSeed` of equal value are equal; a string seed with no UTF-8
  form is refused. `SessionComplete.output` is decoded on each read and its
  `toString` is `MontyComplete(output=...)`. `SourceRange` takes
  `filename`, `start` and `end` by name and prints as upstream's repr, and a
  decoded position's file name is cut to 256 UTF-8 bytes on every
  suspension kind. Outcomes are recorded from pydantic-monty 1.1.0 by
  `tool/generate_config_oracle.py`, `tool/generate_pool_oracle.py` and
  `tool/generate_worker_class_oracle.py`.

- CI: the merged-coverage ratchet on a push to main (and on a manual run) now compares with the commit's first parent, so a merge that deletes library files counts them as deleted instead of vanished; before, such a merge failed the run before the merged tracefile was uploaded, and the after-merge baseline could not be recorded. Pull requests are compared with their base branch as before. A `release` label on a pull request, or `force_all: true` on a manual run, makes the `changes` job report `code=true`, so every job runs on a Markdown-only change.

- Test and tool cleanups ahead of the cutover, with no change to the package: the corpus test helpers pass the dcm rules ratchet again; the export-boundary self-test's fixtures edit `src/externals.dart`, which survives the old engine's removal; and the worker-only hook test writes its Cargo configuration fixture instead of copying the checkout's.

- Print collectors for the worker sessions: `CollectStreams` (each fragment as a `(stream, text)` record) and `CollectString` (both streams as one string), callable as a feed's print callback, as pydantic-monty 1.1.0's are passed as `print_callback`. Each has a byte cap (10 MiB by default, `maxBytes: null` for none; `CollectStreams` charges 64 bytes per record beyond its text) and refuses an overflowing fragment whole with `MontyRuntimeError` carrying Python `MemoryError` (`memory limit exceeded: <used> bytes > <limit> bytes`), which the feed then fails with. `call` accepts only `'stdout'` and `'stderr'`; `toString` is upstream's `repr`. A negative `maxBytes` throws `ArgumentError`. Internal until the cutover.
- A print callback that throws now fails its feed with a `MontyError` instead of rethrowing the thrown object, as upstream raises a print-callback failure: the Python exception is classified as a host function's throw is (an `ExternalException` raises its type and message, anything else `Exception` with its `toString()`), as `MontySyntaxError` for a `SyntaxError` and `MontyRuntimeError` otherwise. A collector's overflow is raised as the collector threw it.

- Removed the tracked `native/lcov.info` coverage artifact (now ignored) and reworded comments and defaults in `tool/` scripts and `native/tests/integration.rs` that embedded a personal home path or account name. `check_vfs_regression.sh` and `dmc_container.sh` now default to `$HOME`-relative paths; both still honour their existing environment overrides.

- The breaking-change ledger (`tool/breaking-ledger.tsv`) and its check
  (`tool/check_breaking_recorded.sh`, the `Breaking changes announced` CI job
  and the `breaking_rec` gate step) are retired. Breaking changes are recorded
  in the release notes only; the existing `CHANGELOG.md` entries are the
  history.

- Worker sessions keep upstream's suspension and sleep budgets in one place (`SessionBudget`, internal), counted per checkout as upstream's pool counts them. It also holds upstream's rules for loading a dump, for the dump/load work to apply: the checkout's `maxSuspensions` and `maxTotalSleep` stay as ceilings on the dump's limits, both counts restart, and a re-announced suspension is counted and charged again; a load the worker refuses, or one never answered, leaves the budget as it was. A worker reply reporting a suspension limit past 2^63 (a u64 such as `u64::MAX`) no longer reads as negative and aborts the next suspension; as upstream, it leaves the limit unchanged. The budget cases (exhaustion, an uncatchable sandbox `try`, a budget of 0, name lookups counted, the default 1000, the count across feeds) are checked against real workers on the VM, dart2js and dart2wasm, with outcomes recorded from upstream. Internal until the cutover; `MontySuspensionBudgetExceeded` and the FFI/WASM paths are unchanged.

- Every export line of `dart_monty_core.dart` now has a `show` list naming exactly what it exports today; the public API is unchanged (`tool/export-golden.txt` is byte-identical). A name added to a file under `lib/src/` stays internal until it is listed.
- `ResourceLimits.validate`/`toProto` and `MontyCrashedError.context` (both classes still internal) move into the extensions `ResourceLimitsInternal` and `MontyCrashedErrorInternal`, which the public `show` lists will leave out.
- `tool/check_export_boundary.dart --post-cutover` applies the boundary rule for after the cutover: a name declared under `lib/src/worker/` may be exported only when it is in the golden's names sections, and nothing from the protobuf, arena, channel, frame-scanner or wire-helper libraries may be exported or named in a public signature. Five new self-test controls cover it, plus one for the `show` lists. The `gate` CI job's timeout goes from 8 to 12 minutes.
- `tool/metrics_ratchet.sh` reads dcm's per-declaration results. A `number-of-parameters` violation listed in `tool/dcm-param-exceptions.txt` (empty for now; at most ten lines) is exempt; a stale or changed line fails. Under `RATCHET_BASE_REF`, regressions are compared with the base branch's baseline and the PR's own baseline must equal a fresh `--update`. `--self-test` (nine controls, no dcm needed) runs in the gate and CI.

- 102 requirement tests for the value family (`test/unit/platform/spec_values_*_test.dart`): toString formats, equality and hash fields, `fromDart` identity and refusals, cycle refusals, the 400-level and 2^22-visit budget, and dart2js integral-double dispatch. The unit floors in CI are raised to 2690 (VM) and 5350 (web).

- Worker classes (unexported until the cutover) match pydantic-monty 1.1.0's
  members: `ExternalReturnValue` compares by value; `Frame.toString()` is
  upstream's `str(frame)`; `FunctionSnapshot.kwargs` is one mutable map,
  cached on first read; `SourceRange` rejects an offset outside 0..2^32-1
  with `ArgumentError`; a registered host object is a dict key or set member
  by its own `==` and `hashCode`, not by identity. Outcomes are recorded from
  pydantic-monty 1.1.0 by `tool/generate_worker_class_oracle.py`.


## 0.23.1

Git tag only (not published to pub.dev): the M0 stabilisation work. Still
requires `monty` v0.0.23.

### Added

- `package:dart_monty_core/dart_monty_core_testing.dart`, a public entry for
  test doubles (core#165). It exports `MockMontyPlatform` and its
  `MockCallHistory`, and re-exports `dart_monty_core.dart` so the types the
  mock is configured with come with one import. Downstream packages imported
  the mock from `src/platform/mock_monty_platform.dart`; use this entry
  instead. No other `src/` declaration becomes public through it.

### Changed

- CI now builds the AOT consumer probe with `dart build cli`, bundling the
  native library from `hook/build.dart`, and runs it to verify its assertions.
  Documented the build/run commands and the complete bundle consumers must ship.
### Breaking

- **The precompile API is removed**: `Monty.compile`, `Monty.runPrecompiled`,
  and `MontyPlatform.compileCode` / `runPrecompiled` / `startPrecompiled`, with
  their implementations on every platform (`MontyFfi`, `MontyWasm`,
  `ReplPlatform`, `MockMontyPlatform` and its `compileCode`/`runPrecompiled`/
  `startPrecompiled` history lists). No deprecation and no replacement.

  It never worked. `Monty.compile` snapshots a one-shot handle, and the native
  handle refuses that unconditionally on every target, so every call threw
  "snapshot is not supported on the one-shot handle" — and `runPrecompiled`
  fails the same way on restore (core#152). The only tests that passed were
  written against `MockMontyPlatform`. Code that called it was already failing
  at runtime; it now fails to compile instead. To run the same source
  repeatedly, hold it in `Monty(code)` and call `run()`; for state that
  survives between runs, use `MontyRepl` and its `snapshot()`/`restore()`.

  `tool/check_api_absent.sh` (a gate step and a CI check) fails if any of the
  removed names becomes callable again.

## 0.23.0

Requires `monty` v0.0.23.

This package's minor version tracks the monty patch it pins: v0.0.17 -> 0.17.x,
v0.0.18 -> 0.18.1, v0.0.19 -> 0.19.0. This section opened as 0.19.0 and the pin
moved to v0.0.23 inside the unreleased window (`e1e4eda`) without the version
following, so it was renumbered to 0.23.0 when that drift was noticed. The
0.19-era notes below are kept as written: they describe changes that really did
land, and renumbering the heading does not make them untrue.
`tool/check_version_pin.sh` now makes this class of drift impossible to repeat.

The `monty` crate's public surface was split in 0.19 — it went from 1321 to 306
public items and most of what this package uses moved to the new `monty-types`
crate — so this is a substantial internal change with a small consumer-facing
surface.

### Wire format — now versioned, and at v5

The host/sandbox envelope is now versioned. `main` (0.18.1) has no
`WIRE_FORMAT_VERSION` constant at all, so upgrading from the last release means
adopting a versioned wire AND five format changes at once. Nothing in this file
recorded that, which for a serialisation boundary is the omission that matters
most.

`native/src/convert.rs:65` declares it; `lib/src/ffi/native_bindings.dart:253`
must equal it; `tool/check_wire_version.sh` fails if they drift
(`OK: wire format v5 in both ...`).

How it got to 5, each step a real decoder change rather than a bump:

| v | commit | change |
|---|---|---|
| 1 -> 2 | `2808edb` | tag every dict, and reject what the decoder cannot name (core#136) |
| 2 -> 3 | `55d3ac2` | a bare string means `str`, and nothing else (core#134 + 4 siblings) |
| 3 -> 4 | `de7444b` | carry the ambiguous numbers as text, closing core#128 on the web |
| 4 -> 5 | `c91bcc3` | `MontyClassInstance`, plus three decoder gaps an audit found |

**Consumer impact.** A host and a sandbox built from different sides of any of
these will disagree about what a value means — the failure mode each commit
exists to prevent is a value silently decoding as the wrong type, not a crash.
Rebuild both halves together. `docs/WIRE-CONTRACT.md` describes the envelope and
`tool/check_wire_contract.sh` checks the document against the encoder in both
directions.

### Mount lifetime and mode — read this if you are porting from `pydantic_monty`

Three behaviours that were true but documented nowhere. None is a change; all
three surprise people, and one of them differs from upstream's default.

- **Our default mount mode is `readWrite`. Upstream's is `overlay`.** Pass no
  `mode` and writes **persist** for the life of the handler. Upstream's
  `MountDir(mode='overlay')` — its default (`_monty.pyi:90`) — captures writes
  in memory and **discards them at feed end**. We have no overlay mode
  (`MountMode` is `readOnly | readWrite`) because upstream's overlay falls
  through to a real host directory and our mounts have no host path: our tree
  *is* the filesystem, so there is nothing to fall through to.

  In practice the two are **indistinguishable within one feed over a mount with
  nothing underneath it** — which is why both of upstream's own
  `OverlayMemory`-generated `mount_fs` fixtures pass green against our
  `readWrite` tree.

- **Mount state is scoped to the HANDLER, not to a feed.** Upstream discards by
  dropping a per-feed mount table; our equivalent is dropping the handler.
  Because `osHandler` is a per-feed parameter, **constructing a fresh handler
  over fresh files per feed reproduces upstream's overlay behaviour exactly**,
  with no extra API. Reusing one handler across feeds gives persistence.

- **Seeded `VfsFile` objects are mutated IN PLACE by sandboxed code.** This is
  upstream's contract (`os_access.py:608`, *"When Monty code writes to this
  file, the content attribute is updated"*) and it is what makes output capture
  work: seed `MontyMemoryFile('/out.txt', '')`, run, read `.content` back.

  The consequence to know about: a fresh handler over **reused** seed objects
  gives a *half* discard — files the sandbox created are gone, but your own
  objects stay rewritten. If you want a clean slate, construct fresh
  `MontyMemoryFile`s, not just a fresh handler. Pinned by
  `memory_mounted_os_handler_test.dart`, "a fresh handler over REUSED seeds
  half-discards, on purpose".

### Added

- **`ReplBindings`, `CoreRunResult`, `CoreProgressResult` and `WireJson` are
  now exported.** They were already public by reachability —
  `MontyRepl.withBindings({required ReplBindings bindings, ...})` is a public
  constructor, and `ReplBindings`' members return the two result types and take
  a `WireJson` — but none of the four could be NAMED from
  `package:dart_monty_core/dart_monty_core.dart`. A consumer could see the
  constructor and had no way to call it.

  Measured before the fix, compiling a file that imports only the barrel and
  implements `ReplBindings`: five analyzer errors, starting with "Classes and
  mixins can only implement other classes and mixins" because `ReplBindings`
  was not a visible type. After: compiles.

  `monty_core_bindings.dart` is exported with `show CoreProgressResult,
  CoreRunResult` rather than wholesale. `MontyCoreBindings` itself is the
  backend-adapter interface and is reached only through the unexported
  `BaseMontyPlatform`, so it stays internal — the same reasoning already
  applied to `VfsAccountant` and `vfs_limits.dart` above it.

  Additive: no name is removed or changed, and none of the four added top-level
  names (`ReplBindings`, `CoreRunResult`, `CoreProgressResult`, `WireJson`)
  collides with one the barrel already exported. `WireJson`'s factories are
  members, not separate top-level names. The one way this can still disturb a
  consumer is the generic hazard of any new export: code that imports the
  barrel unprefixed alongside another library declaring one of these four names
  now has an ambiguous reference. That is not a semver break and carries no
  `!` marker. `dcm check-exports-completeness` goes from 4 defects to none.

- **Wire format v5.** `WIRE_FORMAT_VERSION` is 5. New public types:
  `MontyClassInstance`, `MontyClassType`, `MontyTime`, `MontyNotImplemented`.

- **`MontyDataclass` is encode-only.** v0.0.23 dropped the dataclass variant, so
  every class instance now decodes as `MontyClassInstance` — read
  `classType.isDataclass` to tell them apart. Encoding is unchanged.

- **`MontyRepl.restore()` works.** It was a silent no-op on FFI: it never set
  the created flag, so the session kept its old heap and reported success. It
  now also applies the caller's limits and external functions instead of
  inheriting the snapshot's.

- **`FfiCoreBindings.resumeNameLookupValue` is implemented.** The stub claimed
  the FFI backend did not support it; the Rust export, header and generated
  binding all existed.

- **`docs/WIRE-CONTRACT.md` exists.** Ten sites cited it as normative and it had
  never been written. Its row table is generated from the assertions that run,
  not authored.

- **`monty_alloc` / `monty_dealloc` declared in the C header.** Exported and
  called 49 times by the Worker while absent from the header, so ffigen
  generated no binding for them.

- **`monty_snapshot` reports why it failed** instead of returning a bare NULL
  that left Dart and the Worker each inventing a reason.

- **`package:dart_monty_core/unsafe_callback_file.dart` — host-reaching virtual
  files.** `VfsCallbackFile(path, read:, write:)` backs a virtual file with
  host callbacks, mirroring upstream's `CallbackFile` (`os_access.py:676`). It
  ships in a **separate library** because importing it is a security decision:
  the callbacks run on the host with full access to the filesystem, network and
  every other system resource, and one that touches the real filesystem breaks
  the Monty sandbox. Upstream's warning is repeated on the class.

  The callback always receives the path the file was **seeded** at, never its
  live `path`. A rename rewrites the live path of every file in the moved
  subtree, so passing that to the callback would let sandboxed Python choose the
  argument the host receives simply by renaming inside the mount.

  **This separation is a signal, not a boundary, and the distinction is worth
  your attention.** `VfsFile` is an open interface, so a host-reaching backing
  can be written against the main library with no import at all — that was true
  before this release and remains true. The reviewer's rule is *audit every
  `VfsFile` that is not a `MontyMemoryFile`*; this library makes the common case
  greppable and does not replace that rule.

### Internal

- **Every WASM restore was failing silently.** `monty_repl_restore` grew from
  three C parameters to five; the Worker kept calling it with three. JS pads a
  short WebAssembly call with `0` rather than throwing, so `outError.ptr` bound
  to the `limits_json` slot and the error channel went NULL — invisible to every
  compiler and linter, and green across the whole FFI suite.
  `tool/check_wasm_arity.mjs` now checks all 167 Worker call sites against the
  shipped wasm.

- **`MontyReplHandle::restore` is now `restore_keeping_snapshot_limits`.**
  Rust-crate only, no Dart binding, every caller in this repo's tests — so no
  consumer surface moved and the commit's `!` marker should not have been there.
  The old name passed `limits: None`, meaning whoever supplied the bytes chose
  the resource limits.

- **Two conformance fixtures were blamed on monty and were ours.**
  `dataclass__call_field_error.py` and `dataclass__get_missing_attr_error.py`
  were listed in `knownBrokenExtFixtures` as a "monty v0.0.23 regression:
  dataclass attribute errors are not surfaced ... excType is null". The FFI
  dispatch loop simply had no branch for an unknown METHOD on a host dataclass,
  so it returned a SKIP where the WASM loop raised `AttributeError` — nothing
  ever raised, hence the null. Both fixtures now run and pass on both backends
  (`oracle_ffi_ext` +48 ~9 -> +51 ~7). The two loops answer identically; this
  was the third time they had drifted.

- **`dataclass__basic.py` diagnosed, and it stays declared.** It fails
  identically on FFI and WASM because monty v0.0.23 sends an EMPTY argument
  list for a method call and passes the receiver as `FunctionCall.object_id`,
  which `repl_handle.rs:848` reduces to `object_id.is_some()` — so the
  `AttributeError` cannot name the receiver's type. Validated against
  `pydantic-monty` 0.0.23 directly: with the receiver resolved by `object_id`,
  every assertion in the fixture passes. The fixture is correct and monty is
  correct; fixing it is a wire change.

- **Declared-failure lists are now checked in both directions.** A list saying
  "skip this, it is broken" is write-only: the day the thing is fixed, the skip
  persists and the fixture silently stops running. `oracle_ffi_ext_test.dart`
  gains "every knownBrokenExtFixtures entry STILL fails", which found the two
  stale entries above the moment it was written.

- **`tool/check_dcm_exclusions.sh`** (gate, 0s): every `dcm_options.yaml`
  exclusion naming a concrete path must exist on disk. Five dormant exclusions
  were deleted across four rules — two of them naming
  `lib/src/monty_session.dart`, removed in `22cbe08` months earlier and still
  excluded, one of them carrying a comment about parameters of a file not in
  the tree. `--deep` (CI only, needs the DCM credentials) additionally re-runs
  the analyzer with exclusions stripped to catch entries that name a real file
  but hide nothing.

- **DCM is now enforced on `lib/` for three rules it had been excluded from.**
  `avoid-non-null-assertion` (12 sites: field reads hoisted into promotable
  locals, which is stricter than the `!` it replaces, plus an explicit error at
  the JS boundary), `avoid-dynamic` (21 sites, all `List<dynamic>` at
  json.decode boundaries, now `List<Object?>` — no public signature changed;
  every site is a local, a switch pattern, or a private factory), and
  `prefer-declaring-const-constructor` (whose three exclusions each rested on a
  claim that turned out to be false — extension types *can* be const,
  `NativeBindingsFfi` has no fields, and `Monty._` never touched
  `MontySession`). The const constructors let three call sites become `const`.

### Breaking

- **The backend-adapter layer is no longer exported**, and
  `MontyRepl.withBindings` is gone. Unexported: `CoreProgressResult`,
  `CoreRunResult`, `ReplBindings` and `WireJson`. Consumers use `MontyProgress`
  and `MontyResult`, which `BaseMontyPlatform` translates the DTOs into.

  Dropping only the two DTOs would not have worked. `ReplBindings` was exported
  and nine of its methods return them, so an outside implementer would have
  been asked to write signatures naming types it could no longer name.
  `WireJson` was exported for the same reason and its doc said so.

  That whole surface existed to serve `MontyRepl.withBindings`, which let an
  outside caller supply their own bindings. It had **no callers** — not in
  `lib/`, `test/`, `example/` or `tool/` — so it is removed rather than
  preserved, and the adapter contract becomes internal in fact and not just by
  directory. What remains free to change is the DTO shape, which the progress
  translator work needs.

  Two in-package integration tests that drive the adapter directly now import
  `src/platform/wire_json.dart` explicitly.
- **An omitted `maxSuspensions` now applies a budget of 1000, not none.**
  `MontyLimits`' doc said "All fields are optional — omitted limits are
  unconstrained". That is no longer true of suspensions, and matching upstream
  mattered more than the sentence: `pydantic-monty` gets the same bound from
  `monty-pool`, a crate this package does not depend on, so a direct binding
  that is its own pool had to supply it.

  `MontyRepl._driveLoop` was an unbounded `while (true)`, and `timeoutMs`
  could not help — that limit bounds INTERPRETER time, while a suspension
  spends its time in Dart. A script calling an external function in a loop ran
  5,000,000 callbacks before stopping on its own, 11.7x past a 3s watchdog,
  with `timeoutMs: 500` set.

  Exceeding the budget throws `MontySuspensionBudgetExceeded`, a new
  `MontyError` — not `MontyResourceError`, which is for limits the ENGINE
  enforces and reports. It is not resumed back into the sandbox, so a
  `try/except` there cannot buy more callbacks.

  As upstream, the budget cannot be disabled: a negative `maxSuspensions`
  throws `ArgumentError`. `0` refuses the first suspension while still
  permitting work that never suspends. Because the
  budget is host-enforced it needs no backend support, so it applies on the
  web backend too, where engine-enforced session limits still throw
  `UnsupportedError` (#140).

- **`MontyCallback` and `OsCallHandler` now return `FutureOr<Object?>`**, was
  `Future<Object?>`. Supplying a callback gets strictly easier: a
  `Future`-returning function is still assignable, and one that simply computes
  a value no longer has to be `async` to satisfy the signature. Every host
  callback in this repo that had nothing to await has dropped it.

  What breaks is CONSUMING the result as a Future. Code that calls a
  typedef-typed callback and then `.then(...)`, `.catchError(...)`, or assigns
  to a `Future<Object?>` variable no longer compiles; `await` is unaffected,
  because awaiting a non-Future is valid. Failures from a now-synchronous
  callback arrive as a synchronous throw rather than a rejected Future — both
  dispatch paths in `monty_repl.dart` already catch both.

  The old signature was a workaround wearing a contract: it forced asynchrony
  on callbacks that had none, and the resulting `async` bodies were suppressed
  from `avoid-unnecessary-futures` across nine test files as "false positives".
  They were not false positives; the signature was wrong.

#### `MontySet` and `MontyFrozenSet` compare and hash order-insensitively

`MontySet([MontyInt(1), MontyInt(2)])` and `MontySet([MontyInt(2), MontyInt(1)])`
were UNEQUAL and hashed differently. They are now equal, because they are the
same Python set. Same for `MontyFrozenSet`.

Breaking in the direction that matters: code relying on order-sensitive set
comparison was relying on a defect, and any `Map` or `Set` keyed by a
`MontySet`/`MontyFrozenSet` will now collide entries it previously kept apart —
which is the correct behaviour, and worth checking if you keyed a cache that way.

`operator==` compared `items` with `DeepCollectionEquality`, which compares a
`List` IN ORDER. This is the same defect the two dict classes had, immediately
above: `MontyDict` was fixed and the sets were left behind, so the file
contradicted itself 20 lines apart. The sandbox settles it —
`crates/monty/src/types/set.rs:412` compares with a length check plus a
per-element `contains`, and `:1435` hashes a frozenset by XOR "so the hash is
independent of insertion order".

One deliberate divergence from upstream: hashes fold with `+`, not XOR. XOR
cancels duplicates, so a forged `{"__type": "set", "value": [1, 1]}` would hash
identically to the EMPTY set. Monty collapses equal elements before the wire so
upstream never sees a duplicate; this decoder parses whatever arrives.

#### `MontyPairsDict` is gone; `MontyDict` holds pairs

A Python dict now decodes to ONE type whatever its keys are. `MontyPairsDict`
is deleted and `MontyDict.entries` (`Map<String, MontyValue>`) is replaced by
`MontyDict.pairs` (`List<(MontyValue, MontyValue)>`) — the shape monty itself
uses (`DictPairs(Vec<(MontyObject, MontyObject)>)`).

THE REASON IS A CORRECTNESS DEFECT, not tidiness. The two classes disagreed
about what dict equality MEANS, and which one you got was decided by whether
the keys happened to be strings:

```
{'x':1,'y':2} == {'y':2,'x':1}   ->  true    (MontyDict, compared as a Map)
{1:'a',2:'b'} == {2:'b',1:'a'}   ->  false   (MontyPairsDict, compared as a List)
```

The sandbox answers `True` for both, so the second was wrong. Both behaviours
were pinned by tests asserting opposite things about the same Python type.
`MontyDict.==` is now order-insensitive for every key type, and `hashCode`
folds commutatively to match.

Porting:

- `d.entries` -> `d.asStringMap` (returns `null` unless EVERY key is a string,
  so the assumption is explicit) or iterate `d.pairs`.
- `case MontyPairsDict(:final pairs)` -> fold into `case MontyDict(:final pairs)`.
- `MontyDict({'a': v})` -> `MontyDict.ofStrings({'a': v})`, or
  `MontyDict([(MontyString('a'), v)])`.
- `d.length` / `d.isEmpty` / `d.keys` / `d.values` are available directly.

UNCHANGED: the wire. Both envelope shapes are still emitted and accepted
byte-identically (`value` for all-string keys, `entries` otherwise), so no
native change was needed. `dartValue` also keeps its existing contract — a
`Map` when every key is a string, a pair list otherwise.

ALSO FIXED: `MontyValue.fromDart` forced every map key through `k.toString()`,
silently turning the Dart map `{1: 'one'}` into the Python dict `{'1': 'one'}`.
Keys now convert the same way values do.


- **A negative or wrong-typed resource limit is now an error.**
  `parse_limits_json` read each axis with `and_then(Value::as_u64)`, which
  yields `None` for anything that is not a non-negative integer — so
  `{"memory_bytes": -1}`, `"1000"`, `1.5` and `true` all left that limit UNSET
  and ran **unbounded** while reporting success. Absent and `null` still mean
  "no limit"; a present-but-unusable value now fails loudly. If you see this
  error, you were not getting the limit you asked for.

- **On the web, `restore(limitsJson:)` and `restore(extFns:)` throw
  `UnsupportedError`** rather than accepting and ignoring them — the Worker
  cannot carry either across the message boundary yet. A silently unbounded
  restored session is worse than a refusal.

- **`open()` parses its mode, and rejects a malformed one.**
  `resolveOpenCall` string-compared the mode and treated *everything*
  unrecognised as append: `open(p, 'wxyz')`, `open(p, 'x')` and even
  `open(p, '')` fell through to create-if-missing. It now parses the mode
  before any side effect and raises `ValueError: invalid mode: '<mode>'`,
  which is what upstream does and for the reason upstream states
  (`os_access.py:870-876`) — a direct caller must not be able to trigger the
  truncate/create branch with a mode that was never valid.

  Two consequences beyond the rejection. `b`, `t` and `+` are now understood as
  orthogonal to the open-time action, so `r+`, `rt` and `rb+` are read actions
  that check existence instead of silently creating, and `w+`/`wt`/`wb+`
  truncate. And `x` (exclusive create) is rejected rather than treated as
  append — upstream's own code asserts the action is one of `r`/`w`/`a`
  (`os_access.py:896`), so accepting it would invent a semantic neither side
  implements.

  Found by porting upstream's `test_os_access.py`, whose own test for this is a
  named data-loss regression guard.

- **`MountDir.writeBytesLimit` is now CUMULATIVE, not per-write.** It capped a
  single call, which bounds nothing an attacker cares about:
  `write_bytes(b'x' * limit)` in a loop passed every check and exhausted host
  memory. Measured against the old code, a limit of 100 bytes let **all ten** of
  ten 30-byte writes through.

  Upstream's parameter of the same name has always been cumulative — *"Cap on
  cumulative bytes written through the mount within one feed"*
  (`_monty.pyi:111-113`) — so the old behaviour was a silent contract mismatch
  for anyone porting from `pydantic_monty`. It is monotonic: deleting a file
  does not buy budget back, because the bytes were still written.

  The message now matches upstream's too:
  `OSError: disk write limit of 10 bytes exceeded` (was
  `Write exceeds mount limit (100 > 10 bytes): /path`).

- **New: `MountDir.memoryUsageLimit`, defaulting to 100 MB.** Bounds the bytes
  a mount **currently retains**, where `writeBytesLimit` bounds what has flowed
  through. Deleting refunds this one. Exceeding it raises
  `MemoryError: mount memory usage limit of 100 MB exceeded`.

  Ported from upstream rather than invented: the default matches
  `DEFAULT_MEMORY_USAGE_LIMIT` (`monty-fs/src/mount_table.rs:18`), and each node
  is charged `entryMemoryUsage` (256 bytes) plus its content, matching
  `ENTRY_MEMORY_USAGE` (`monty-fs/src/overlay_state.rs:21`). The per-entry
  charge is what stops a million empty files, which cost no content bytes and a
  great deal of real memory.

  Two deliberate scoping choices, both documented on `VfsAccountant`: content
  **seeded** through `files:` is not charged, because the budget exists to bound
  what untrusted code makes us retain rather than what the consumer handed us;
  and a host-reaching file's content is never charged *or measured*, since
  asking it for a size would fire a host callback — accounting must not have
  side effects.

  Because we have no feed boundary to hang state on, both limits are scoped to
  the handler instance. For a one-shot `run()` that is identical to upstream;
  for a long-lived REPL it is stricter.

- **A `rename` TARGET outside every mount is absent too, not denied.** The rule
  below was never carried through to the second path of a two-path call. A
  target outside every mount declined instead, which with no fallthrough
  surfaced as `PermissionError: Permission denied: '<target>'` — so sandboxed
  code could map the sandbox by comparing exceptions: `PermissionError` meant
  "outside your mounts", `FileNotFoundError` meant "just missing". It now
  raises `FileNotFoundError: [Errno 2] No such file or directory: '<target>'`,
  the same message a target whose parent is simply missing already gets, which
  is what makes the two indistinguishable.

  Upstream does not pin this case — `route_call` propagates "no mount" as a
  non-answer (`monty-fs/src/mount_table.rs:125`) and upstream's own security
  test accepts either outcome outright (`monty-fs/tests/fs_security.rs:1078`:
  `None => {} // Also acceptable`).

  Also fixed in the same place: declining to a `fallthrough` rewrote the call to
  a single argument, so a fallthrough handler received `Path.rename` with its
  **source dropped**. It now forwards both. (Upstream's `on_no_handler` names
  the source for a rename, never the target — `monty-types/src/os.rs:241`.)

- **A path outside every mount is reported as absent, not denied.**
  `memoryMountedOsHandler` raised `PermissionError` for anything it does not
  mount, which made `Path('/nonexistent').exists()` unusable.

  - `exists`, `is_file`, `is_dir`, `is_symlink` return `false`.
  - Every other operation raises
    `FileNotFoundError: [Errno 2] No such file or directory: '<path>'`.

  The second half is the part to notice if you relied on the old wording. It
  is deliberate: reporting `exists() == False` and `PermissionError` about the
  same path contradicts itself, and `Permission denied` leaks more — it
  confirms the path is worth denying. A configured `fallthrough` still gets
  first refusal, and a handler that *declines* with
  `OsCallNotHandledException` is unaffected: it still gets upstream's
  `on_no_handler` wording.

- **CPython path semantics: name length, codepoint counts, `resolve` returns a
  Path.** With these, both `mount_fs__ops.py` and `mount_fs__errors.py` pass.

  - Paths with a component over **255 bytes**, or a total over **4096 bytes**,
    raise `OSError: [Errno 36] File name too long: '<path>'` from
    read/write/append/stat/mkdir/open. `exists`, `is_file`, `is_dir` and
    `is_symlink` swallow it and return `false`, as CPython does. Bytes, not
    characters.
  - `write_text` and `append_text` return **codepoints**. They returned Dart's
    `String.length`, i.e. UTF-16 code units, so a single emoji reported 2.
  - `resolve` and `absolute` return a `MontyPath`. They returned a bare
    `String`, so Python received a `str` and `.name` raised `AttributeError`.
  - `mkdir(parents=True)` through a file raises `NotADirectoryError` rather
    than surfacing an internal `StateError` as `RuntimeError: Bad state:`.

- **`rename` follows CPython's full matrix.** It had two behaviours; there are
  six, and which one applies depends on what is at *both* ends.

  | source | destination | result |
  | --- | --- | --- |
  | missing | — | `FileNotFoundError`, naming the source |
  | file | missing | move |
  | file | file | **overwrites silently** (POSIX) |
  | file | directory | `IsADirectoryError` `[Errno 21]` |
  | directory | file | `NotADirectoryError` `[Errno 20]` |
  | directory | non-empty directory | `OSError` `[Errno 39]` |
  | directory | empty directory | move, replacing it |

  Previously any existing destination was refused with
  `Rename target already exists: <path>`, which was neither CPython's wording
  nor its behaviour.

- **`iterdir`, `unlink` and `mkdir` answer directory questions honestly.**

  - `iterdir` of a **missing** path raised nothing and returned an empty list,
    which is indistinguishable from a successful listing of an empty
    directory. It now raises `FileNotFoundError`. Of a **file**, it now raises
    `NotADirectoryError: [Errno 20] Not a directory: '<path>'`.
  - `unlink` of a **directory** raised `FileNotFoundError`, naming a path that
    exists. It now raises `IsADirectoryError`.
  - `mkdir` on an existing **directory** said `Directory exists: <path>`. It
    now says `[Errno 17] File exists: '<path>'` — CPython uses one message for
    both the file and directory cases.

- **Writing to a directory raises instead of destroying it.** This was silent
  data loss: `write_text` on a directory path succeeded, replacing the
  directory node with a file and discarding everything beneath it.

      files: [MontyMemoryFile('/m/d/keep.txt', 'precious')]
      Path.write_text('/m/d', 'clobber')   // returned 7
      Path.read_text('/m/d/keep.txt')      // FileNotFoundError

  `read_text`, `read_bytes`, `write_text`, `write_bytes`, `append_text`,
  `append_bytes` and `open(dir, 'w')` now all raise
  `IsADirectoryError: [Errno 21] Is a directory: '<path>'`. Reads of a
  directory previously reported `FileNotFoundError`, which named an existing
  path as missing.

- **Directories are real, and that changes two things consumers can see.**
  The mount's store is a tree (`VfsNode` = `VfsDir` | `VfsFile`) rather than a
  flat path map, so an empty directory exists: `mkdir` creates one and
  `Path.exists` reports `true` before anything is written into it. Previously
  it reported `false` until a child appeared.

  - `VfsFile` moved from `vfs_file.dart` to `vfs_node.dart` and gained a
    `path` **setter** — renaming a directory rewrites the path of every file
    beneath it, so a caller holding one sees the new path. `MontyMemoryFile`
    is now in `monty_memory_file.dart`. Both are still exported from
    `package:dart_monty_core/dart_monty_core.dart`, so only direct
    `src/`-path imports break.
  - `resolveOpenCall`'s `exists` callback now means **"a node is here"**, not
    "a file is here", and `isDirectory` is checked independently rather than
    only when `exists` is false. A custom handler passing a file-only
    `exists` still behaves correctly; one that relied on the old nesting to
    report `IsADirectoryError` must supply `isDirectory`.

  Writing a file whose parent directory does not exist raises
  `FileNotFoundError` again. That check was added and reverted earlier in this
  same unreleased cycle because `mkdir` could not create the parent it
  demanded; it can now.

- **`memoryMountedOsHandler` takes `files:`, not a `vfs:` map.** The parameter
  `vfs: Map<String, String>` is replaced by `files: List<VfsFile>`, matching
  upstream's `OSAccess([MemoryFile(...)])`. There is no compatibility shim.

      // before
      final vfs = <String, String>{'/data/in.txt': 'hello'};
      final h = memoryMountedOsHandler(mounts: [...], vfs: vfs);
      ...
      print(vfs['/data/out.txt']);

      // after
      final out = MontyMemoryFile('/data/out.txt', '');
      final h = memoryMountedOsHandler(
        mounts: [...],
        files: [MontyMemoryFile('/data/in.txt', 'hello'), out],
      );
      ...
      print(out.content.text);

  A write updates the `VfsFile` you passed in rather than replacing it, so the
  reference you hold stays live — that is upstream's documented contract for
  `MemoryFile`. Reading back a file you did NOT seed is not supported, by
  design and in upstream too; assert through `Path.exists` / `Path.read_text`
  instead.

  Two behaviour changes come with it, both fixes:

  - **Binary content survives a round trip.** The old store held a `String` and
    decoded at write time with `allowMalformed: true`, so `write_bytes([0xFF])`
    stored U+FFFD and `read_bytes` returned three bytes, not one. Content is now
    a sealed `VfsText | VfsBytes` and bytes are stored verbatim.
  - **`read_text` can now raise `UnicodeDecodeError`.** It previously could not,
    even in principle, because invalid bytes were destroyed before any read.

- **A write no longer requires its parent directory to exist — added and
  reverted within this unreleased cycle.** Relative to 0.18 nothing changed, so
  there is no migration; it is recorded because the behaviour moved twice inside
  the branch and a bisect would otherwise be confusing. The check rejected
  `write_text('/mnt/typo/file.txt')` when `/mnt/typo` did not exist, which is
  correct in principle, but the in-memory VFS cannot represent an empty
  directory: `mkdir` inserts nothing, so `mkdir` followed by writing into that
  directory failed. It returns once directories are first-class.

- **Declining an OS call now raises the call's own default, not `NameError`.**
  `OsCallNotHandledException` was routed through the *external-function* "not
  found" verb, so declining `Path.read_text` produced

      NameError: name 'Path.read_text' is not defined

  which turned a sandbox refusal into a missing-function message. It now raises
  what upstream raises for an unhandled call
  (`OsFunctionCall::on_no_handler`): `PermissionError: Permission denied:
  '<path>'` for a filesystem operation, and `RuntimeError: '<op>' is not
  supported in this environment` for anything else.

  `memoryMountedOsHandler` used the same wording for every unserved call —
  `PermissionError: Path is outside any mount: <arg>` — which was wrong three
  ways: it called `os.getenv`'s variable name a path, printed `null` for calls
  carrying no path, and claimed a file that provably *existed inside* a mount
  was outside it (that message is raised after the mount check, so it could
  never be true there). It now reports the same defaults, which also stops
  disclosing mount topology to sandboxed code.

  Migration: catch the same exception classes; only the message text and, for
  non-filesystem operations, the class (`NameError` → `RuntimeError`) change.

- **The web backends no longer lose numbers (#128).** Three distinct defects,
  all from the same cause — a JSON number's *text* is where the information
  lives, and the JS bridge reparses it:

  | Python | was, on dart2js/dart2wasm | now |
  |---|---|---|
  | `4.0` | `MontyInt(4)` — `JSON.parse("4.0") === 4` | `MontyFloat(4.0)` |
  | `-0.0` | `MontyFloat(0.0)` — `JSON.stringify(-0) === "0"` | `MontyFloat(-0.0)` |
  | `2**62` | `4611686018427388000` (rounded) | exact |

  Those three shapes now travel as tagged **text**, which no reparse can damage.
  Every other finite number stays a plain JSON number, so the corpus does not
  grow — tagging *all* numbers was measured at 6.52× bytes and 17.4× round-trip
  latency and rejected.

- **Integers beyond 2⁵³ are `MontyBigInt` on every backend, including the VM.**
  Previously anything inside i64 was a `MontyInt`. On dart2js Dart's `int` IS a
  double, so past 2⁵³ such a value cannot be a `MontyInt` there at all; making
  the type depend on the backend would be worse than moving the boundary. The
  value is exact either way.

  ```dart
  // was, on the VM: MontyInt(4611686018427387904)
  // now, everywhere: MontyBigInt(4611686018427387904)
  ```

- **Wire format is now 4.**

- **A bare JSON string now means Python `str` and nothing else (#134 + four
  more).** Seven value types used to collapse onto a bare string, so a value's
  Dart type depended on whether some *other* type happened to produce the same
  characters. Each now travels tagged:

  | Python | was | now |
  |---|---|---|
  | `2**63` (beyond i64) | `MontyString` | **`MontyBigInt`** (exact `BigInt`) |
  | `ValueError("boom")` | `MontyString('ValueError: boom')` | **`MontyExceptionValue`** |
  | `float('nan')`, `inf`, `-inf` | `MontyString('NaN')` … | `MontyFloat` (tagged on the wire) |
  | `int` (a class) | `MontyString('int')` | **`MontyOpaque(type, 'int')`** |
  | `abs` | `MontyString('Abs')` ← Rust `Debug`! | **`MontyOpaque(builtin, 'abs')`** |
  | an object's `repr()` | `MontyString` | **`MontyOpaque(repr, …)`** |
  | a cycle marker `[...]` | `MontyString('[...]')` | **`MontyOpaque(cycle, '[...]')`** |

  Two of these were worse than lossy. `ValueError("boom")` was **byte-identical**
  to the Python string `"ValueError: boom"`, so nothing downstream could tell an
  exception from prose describing one — and a message containing `": "` could not
  be recovered at all. And `abs` arrived as `"Abs"`, Rust's `Debug` rendering of
  an internal enum, where every reader would expect the Python name.

  The string `"NaN"` is now a string. It used to decode as `MontyFloat(NaN)`,
  because non-finite floats travelled as bare text and the decoder parsed any
  string that looked like one.

  **Three new variants on the sealed `MontyValue`** — `MontyBigInt`,
  `MontyExceptionValue`, `MontyOpaque` — so exhaustive `switch`es stop compiling
  until each gains an arm. Loud, and the analyzer names every site.

  `MontyExceptionValue` is deliberately *not* called `MontyException`: that name
  is already the exception this package THROWS. Reusing it would leave
  `catch (e) { if (e is MontyException) }` compiling and silently never matching.

- **`MontyOpaque` cannot be sent back into the interpreter.** `type`, `function`,
  `repr` and `cycle` are host-side renderings, not constructible values, so
  decoding one is an error rather than an approximation. `builtin` is the
  exception — its Python name identifies it, so it round-trips exactly.

- **Wire format is now 3.** Asserted at init on both backends.

- **Sandbox escape fixed: sandboxed Python could mint any host type (#136).**
  Returning the plain dict `{"__type": "path", "value": "/etc/passwd"}` from
  Python arrived in Dart as a genuine `MontyPath` — untrusted code choosing its
  own host class by writing a dict key. Closed in **both** directions; the two
  halves landed separately and the second is described in the next entry.

  The cause: only 13 of 27 value types carried a `__type` envelope, so a Python
  dict and a type envelope were **byte-identical on the wire**. Now every dict is
  tagged, and its contents live in a payload the decoder never re-dispatches:

  ```
  {"a": 1}                          →  {"__type":"dict","value":{"a":1}}
  {1: "a"}   (non-string keys)      →  {"__type":"dict","entries":[[1,"a"]]}
  ```

  `MontyValue.toJson()` output changes shape accordingly. If you persisted it, or
  wrote your own decoder against it, both need updating. `WIRE_FORMAT_VERSION` is
  now 2 and is asserted at init, so a stale committed asset fails loudly rather
  than mis-decoding.

- **The other half of #136: a host callback's return value is now encoded, so
  the sandbox can no longer pick its own type through an echo (#139).** The dict
  tagging above closed **Python → Dart**. **Dart → Python** was still open: three
  sites in the self-driven drive loop sent a callback's return with a raw
  `jsonEncode`, so a payload the *sandbox* authored reached the interpreter
  unwrapped.

  ```dart
  // was: Python sees _io.TextIOWrapper, and f.write() reaches the osHandler
  //      as Path.append_text with NO preceding open() to refuse
  // now: Python sees a dict
  await Monty('''
  f = echo({"__type": "filehandle", "path": "/etc/shadow", "mode": "w"})
  ''').run(externalFunctions: {'echo': (args, kwargs) async => args[0]});
  ```

  The host here is an *echo*, and so is any transform, cache, lookup or
  validation callback — it authors nothing. So the advice given for the
  hand-built-envelope entry below ("don't spell envelopes by hand") never
  applied to this: there was nothing a consumer could do.

  The forged **file handle** is the severe case, not the forged path. A path
  grants nothing — sandboxed Python can already write `pathlib.Path(...)`, and
  every path operation reaches the `osHandler` with the path as an argument. A
  file handle skips the authorisation point entirely.

  The fix is a type, not a test: the internal bindings methods that carry a
  value now take `WireJson`, which only `MontyValue`'s encoder can mint, so a
  raw `jsonEncode` at those sites **does not compile**. That caught a fourth,
  unencoded site no audit had listed — it passed a literal, so no grep for
  `jsonEncode` would ever have found it. `core_bindings` is not exported, so
  the public API is unchanged — `resume`, `resolveFutures` and `MontyCallback`
  still take `Object?`.

  Why it survived three tiers, a 17-step gate and green CI: every instrument in
  this package reads values *out* of Python. Nothing tested inbound. There is
  now an inbound probe on both backends where the sandbox authors the payload
  and observation leaves via `print`, never via the value codec under test.

- **`Monty.run(limits:)` was silently ignored, and `MontyLimits` is
  session-scoped (#138).** Measured before: `timeoutMs: 50` on
  `sum(range(20000000))` completed in **483 ms with `error == null`**. In a
  sandboxing library that is the wrong direction to fail — the caller who asks
  for a cap is exactly the caller who believes they have one. Now:
  `TimeoutError: time limit exceeded`.

  Limits attach to a **session**, not a call, because upstream's do:
  `monty-python`'s `checkout(limits=…)` configures a REPL session and `feed_run`
  takes no limits. So the constructor is where they go:

  ```dart
  // one-shot: unchanged, and now actually enforced
  await Monty(code).run(limits: MontyLimits(timeoutMs: 50));

  // a session: limits are fixed when it is created
  final repl = MontyRepl(limits: MontyLimits(timeoutMs: 50));
  ```

  An omitted `limits:` is still fully unbounded, so no existing caller changes
  behaviour. Malformed limits JSON is now an error rather than a silent fallback
  to unbounded — the same defect one layer up.

- **On the web, `MontyRepl(limits:)` — and therefore `Monty.run(limits:)` —
  throws `UnsupportedError` instead of being ignored (#140).** Loud at the
  boundary rather than quiet at runtime: a cap that is silently absent is worse
  than one that refuses to be set.

  **What is missing on web is session scoping, not limits.** Verified in Chrome
  against the shipped WASM asset: all three limits are enforced on the one-shot
  path, which the exported `MontyPlatform` reaches.

  | limit | web behaviour, measured |
  |---|---|
  | `timeout_ms: 50` | `TimeoutError: time limit exceeded: 50.005ms > 50ms`, at 51 ms (266 ms unlimited) |
  | `memory_bytes: 1 MiB` | `MemoryError: memory limit exceeded: 800000032 bytes > 1048576 bytes` |
  | `stack_depth: 32` | `RecursionError: maximum recursion depth exceeded` |

  So on web today:

  ```dart
  // throws UnsupportedError
  await Monty(code).run(limits: MontyLimits(timeoutMs: 50));

  // works — one-shot, limits enforced
  final platform = createMontyPlatform();
  await platform.run(code, limits: MontyLimits(timeoutMs: 50));
  ```

  The gap is narrow: the JS bridge already threads limits through `run` and
  `start`, and `monty_repl_create_with_limits` is already present in the shipped
  `.wasm`. Only `replCreate` does not take the parameter. #140 is JS plumbing,
  not new engine work.

- **A malformed typed envelope is now a decode error, not a panic and not a
  silently-substituted zero.** Two defects sat on the same lines of
  `native/src/convert.rs`: `map["key"]` is Rust's panicking index, and
  `.unwrap_or(0)` swallowed a wrong-typed field.

  Measured in Chrome against the shipped wasm, driving the JS bridge directly:

  | envelope | was | now |
  |---|---|---|
  | `{"__type":"date","year":2020}` | `error: "unreachable"` — a wasm trap | `date envelope is missing required field "month"` |
  | `{"__type":"datetime",…,"hour":"XX",…}` | `ok:true`, `datetime(2020,1,1,0,0)` — hour silently `0` | `datetime envelope field "hour" must be an integer, got "XX"` |

  The same treatment covers `timedelta`, `timezone`, `path`, `bytes`,
  `namedtuple` and `dataclass`, which had the identical shape. An *absent*
  optional field is still absent; a *present but wrong-typed* one is now an
  error, because a caller who supplied the key meant something by it.

  Reachable only through the JS bridge, which is not gated by the internal
  `WireJson` type — the Dart API never could produce these, and since #139
  neither can sandboxed Python, whose maps arrive as dicts.

  **Not fixed, and worth knowing:** a rejected resume still leaves that REPL
  session unusable (`handle not in Idle or Complete state`). The trap is gone
  and the error now says what was wrong, but recovery still means disposing the
  session.

- **`memoryMountedOsHandler`'s errors now read like CPython's.** They were
  ad-hoc:

  ```
  was:  No such file: /mnt/x.txt
  now:  [Errno 2] No such file or directory: '/mnt/x.txt'
  ```

  Also `[Errno 17] File exists`, `[Errno 20] Not a directory` and
  `[Errno 39] Directory not empty`. Sandboxed Python that matched on the old
  text will stop matching — but that code was matching on a string CPython
  never produces. Found because monty's own `mount_fs__errors.py` asserts the
  CPython wording verbatim, so the fixtures were right and we were not.

- **An `inputs` key must now be a valid Python identifier, and it is enforced
  (#137).** The doc always said so; nothing checked, and each key was
  interpolated into Python source raw — so a key was a working code-injection
  primitive:

  ```dart
  // executed as Python, before this release:
  Monty(code).run(inputs: {'ignored = 0\nanswer = "INJECTED"\nz': 1});
  ```

  Now `ArgumentError`. Rejecting rather than sanitising is deliberate: a key
  that is not an identifier cannot express what you meant, so rewriting it
  would substitute our guess for your intent. Non-ASCII identifiers still
  work — Python accepts `café`, so an ASCII-only rule would have been a
  regression dressed up as a fix.

  **This is a guard, not a boundary.** Inputs are still rendered as Python
  source, so an escaping bug here would be a code-execution bug. And a bound
  name shadows what it collides with — `{'print': 1}` makes `print("x")` raise
  `TypeError`. That second one is not a bug we can encode away: shadowing is
  what binding a name means, and `print = 1` is legal Python.

- **An infinite `inputs` value produced invalid Python on the web.** Fixed.

  ```dart
  Monty(code).run(inputs: {'f': double.infinity});
  // was, on dart2js:  f = Infinity   → NameError in Python
  // now, everywhere:  f = float('inf')
  ```

  Cause: on dart2js `double.infinity is int` is **true** — the runtime check is
  effectively `Math.floor(x) === x`, which holds for the infinities — so the
  `int` branch claimed the value before the non-finite branch could. The VM was
  never affected.

  **A related case is deliberately NOT fixed.** On dart2js `4.0 is int` is also
  true, so `inputs: {'x': 4.0}` binds a Python `int` there, where the VM and
  dart2wasm bind a `float`. It is not recoverable inside the library — the
  parameter is `Object?` and dart2js destroys the distinction before the call
  is entered — and **upstream monty does not preserve it on JS either**. Since
  this package mirrors upstream, that settles it: parity, not a gap awaiting a
  fix. Documented rather than chased. The test row is live on the VM and
  dart2wasm and skipped on dart2js against **#137**, so the decision stays
  visible instead of silently passing.

- **`MontyValue.fromJson` now throws `FormatException` on an untagged object or
  an unknown `__type`.** Both used to decode as a dict, and that guess is what
  turned a forged type into a real one. `fromJson` is a deserializer; it now has
  the same contract as `json.decode`.

- **Non-string-key dicts are `MontyPairsDict`, not `MontyList`.** They used to
  travel as a bare JSON array, so a dict silently became a sequence with keys
  indistinguishable from values. `MontyPairsDict` exposes
  `List<(MontyValue, MontyValue)> pairs` in Python insertion order.

  **This adds a variant to the sealed `MontyValue` hierarchy**, so exhaustive
  switches stop compiling until they gain an arm — loud, and the analyzer points
  at each one.

- **A hand-built `{'__type': ...}` Dart `Map` is no longer honoured as that
  type — it is a dict.** THIS ONE FAILS QUIETLY. If an OS-call handler or
  external function returns a map spelling an envelope by hand, the interpreter
  now receives a dict and your code stops working with no error at the boundary.

  ```dart
  // was: interpreted as a dataclass
  (args, _) async => {'__type': 'dataclass', 'name': 'User', 'attrs': {…}}

  // now: say it with the type
  (args, _) async => MontyDataclass(
        name: 'User', typeId: 1, fieldNames: ['name'], attrs: {…},
      )
  ```

  This is the same defect as #136 pointing from the host into the sandbox: any
  `Map` whose keys happened to spell an envelope became that type. Three test
  fixtures in this repo relied on it, which is how it was found.

  Six call sites also built wire JSON with a raw `json.encode(value)`, bypassing
  the encoder entirely — `resume`, `resumeNameLookup`, `MontyRepl.resume`, and
  all three `resolveFutures` implementations. They now route through
  `MontyValue.encodeForWire`, so host values and interpreter values are encoded
  by the same code.

- **Python's `Ellipsis` (`...`) is now `MontyEllipsis`, not `MontyString('...')`.**
  It travels as `{"__type": "ellipsis"}` rather than the bare string `"..."`, so
  `...` and the actual string `"..."` are finally distinguishable — previously
  both arrived as `MontyString` and nothing could tell them apart.

  ```dart
  final r = await Monty('...').run();
  // was: MontyString('...')
  // now: MontyEllipsis()
  ```

  **This adds a variant to the sealed `MontyValue` hierarchy.** If you have an
  exhaustive `switch` over `MontyValue`, it will no longer compile until you add
  a `MontyEllipsis` arm — the analyzer will point at each one. That is the only
  loud part; code that treated `...` as a string just stops matching it.

  A test in `convert.rs` asserted the old collapse as correct behaviour, which
  is precisely why the defect survived to 0.19. It has been inverted. Fixes #129.

- **Dict key order now follows Python insertion order; it used to be sorted
  alphabetically.** ⚠️ **Silent** — nothing errors, values simply arrive in a
  different order. `{"b": 1, "a": 2, "c": 3}` previously came back as
  `{"a": 2, "b": 1, "c": 3}`. Affects **both backends, FFI included**.

  ```python
  d = {"b": 1, "a": 2, "c": 3}
  list(d)     # was ['a', 'b', 'c']  ->  now ['b', 'a', 'c']
  ```

  This restores correct Python semantics: dicts have been insertion-ordered
  since CPython 3.7, and monty computes the order correctly in Rust — `repr(d)`
  always returned `{'b': 1, 'a': 2, 'c': 3}`. Our JSON encoder was discarding it,
  because `serde_json::Map` is a sorted `BTreeMap` unless the `preserve_order`
  feature is enabled. It now is.

  If you sort our output before comparing, nothing changes for you. If you
  relied on receiving alphabetical order, you were relying on a bug — sort
  explicitly. Fixes #129.

- **The `open()` OS-call op is now `'open'`, was `'Open'`.** ⚠️ **This is the one
  change that fails silently.** If you have a custom `OsCallHandler` that matches
  on the op name, a `case 'Open':` (or `if (op == 'Open')`) stops matching and
  every `open()` falls through to your not-handled path. Rename it:

  ```dart
  // before
  if (op == 'Open') { ... }
  // after
  if (op == 'open') { ... }
  ```

  Upstream renamed exactly one of the 23 ops in v0.0.19 (the other 22 are
  unchanged);
  `'Open'` was the only capitalised, undotted name, so `'open'` is now consistent
  with `Path.*`, `os.*`, `date.*` and `datetime.*`.

- **Print output is capped at 10 MB and raises `MemoryError` past it.** Print
  collection previously sat outside all resource accounting, so sandboxed code
  could exhaust the *host* process with a `while True: print(x)` loop. Exceeding
  the cap now raises a normal, catchable Python `MemoryError` — the write is
  rejected, nothing is truncated and no output is silently lost:

  ```python
  try:
      for _ in range(1_000_000):
          print("x" * 100_000)
  except MemoryError:
      ...          # reachable; chunk the output or stream it via printCallback
  ```

- **Session snapshots are not portable across this upgrade.** The canonical dump
  for `"2 + 2"` changed from 60 to 59 bytes, because serialized sessions now carry
  `CompileOptions`. Snapshots taken with 0.18.x cannot be restored on 0.19.0 and
  must be regenerated. (This has been true of every monty bump: 98 → 74 → 60 → 59.)

- **`monty`'s argument-error wording now matches CPython** for Python-style
  argument callsites. For example `json.dumps(1, 2)` raised
  `TypeError('dumps expected at most 1 argument, got 2')` and now raises
  `TypeError('dumps() takes 1 positional argument but 2 were given')`. If you
  assert on these strings, update them.

- **`native/Cargo.lock` is now committed.** The build hook compiles the Rust crate
  as a top-level package on every consumer's `pub get`, so the lockfile is honoured
  and pinning it is what makes your build reproducible. It is also load-bearing:
  free resolution selected a `get-size2` whose `GetSize` impl targeted a different
  `compact_str` major than `ruff_python_ast` used, and the build failed inside a
  dependency neither we nor you control. If you vendor or patch transitive Rust
  dependencies, you now inherit our pins.

- **`TimeoutError` is now part of the `OSError` hierarchy, and
  `UnicodeEncodeError` exists (#522 et al.).** Upstream moved it, so sandboxed
  Python that does `except OSError:` now also catches `TimeoutError`, where
  before it did not. **Silent** — the handler simply starts firing for a case it
  never saw.

- **`open()` modes with no action are now rejected (#612).** A mode string that
  requests neither reading nor writing (e.g. `'b'`) used to be accepted and do
  something unhelpful; it now raises. If you passed a mode through from user
  input without validating it, that call site changes from quietly wrong to
  loud.

- **`encode` / `decode` codec coverage changed, and with it which encodings
  raise `LookupError` (#523).** Some names that used to fail now work, and the
  error type for an unknown codec is now consistent. Code that branched on the
  failure of a specific encoding needs rechecking.

- **`ReplPlatform` now rejects per-call `limits` and `scriptName`.** Both are
  part of the `MontyPlatform` signature and both were accepted and **silently
  dropped**, because on a REPL each is session-scoped: the resource tracker is
  chosen when the Rust handle is created and cannot be swapped, and the script
  name is baked in at `monty_repl_create`. That is the FB-1 / core#124 defect
  shape — a caller who asked for a memory cap got an unbounded session and no
  signal. `run(code, limits: …)` and `start(code, scriptName: …)` now throw
  `ArgumentError` naming the constructor that does honour the argument:

  ```dart
  // was: silently unbounded
  ReplPlatform(repl: MontyRepl()).run(code, limits: MontyLimits(stackDepth: 10));
  // now:
  ReplPlatform(repl: MontyRepl(limits: MontyLimits(stackDepth: 10))).run(code);
  ```

  Note what this does **not** fix: a bare `MontyRepl()` is still UNBOUNDED,
  while every one-shot run is bounded at 256 MB / depth 1000
  (`native/src/handle.rs`'s `default_limits()`). Measured on this release:
  `recurse(2000)` returns `2000` on a bare REPL session and raises
  `RecursionError` on a one-shot run. Pass `MontyRepl(limits: …)` explicitly.

  `ReplPlatform.resumeNameLookup` / `resumeNameLookupUndefined` now throw
  `UnimplementedError` where they threw `UnsupportedError`. Harnesses that drive
  a `MontyPlatform` catch `UnimplementedError` to record a capability gap as a
  skip; an `UnsupportedError` went through that catch and aborted the run.

### Added — capabilities 0.19 brings that this package now passes through

These were previously unsupported by the engine. They are **handled, not
surfaced**: no new Dart API, and values still marshal through the existing
`MontyValue` contract. Documented here because our own docs asserted they did
not work.

- **User-defined classes and class decorators (#515, #582).** Sandboxed Python
  can now define and use classes. Note the marshalling limit: an instance
  crosses to Dart through `repr_or_error`, so it arrives as
  `MontyOpaque(repr, …)` rather than a structured value. A richer surface is
  blocked upstream.

- **`unicodedata` (#522).** The module is available to sandboxed code.

### Deliberately unchanged

- **`assert` keeps CPython semantics.** monty v0.0.19 enables pytest-style
  introspected assert messages by default, so `assert 2 == 5` would raise
  `AssertionError('assert 2 == 5')` where CPython raises an empty
  `AssertionError()`. This release pins them **off**, preserving 0.18 behaviour;
  adopting a new upstream default silently is not an upgrade. An opt-in is
  planned.

### Security

- Removed four stale `unic-*` advisory exemptions from `native/deny.toml`.
  v0.0.19 dropped that dependency chain entirely, so the crate no longer carries
  those unmaintained transitive dependencies.

### Internal

- Depends on the new `monty-types` crate; `monty_type_checking` is now
  `monty-type-checking` upstream (the Rust path is unchanged). `monty-fs` is
  **not** required — this package never used `monty::fs`.
- The conformance corpus moved to v0.0.19's 531 fixtures (was 482 from v0.0.18),
  and `tool/check_fixture_corpus.sh` now fails the build if the corpus and the
  pinned monty version disagree.


## 0.18.1

Requires `monty` v0.0.18 (Rust 1.95+ to build from source). Upgrades the
embedded interpreter and surfaces Python `open()` / file I/O with typed OS
exceptions.

### Breaking

- **Snapshot bytecode format changed.** `monty` v0.0.18 re-encoded
  instructions: the `monty_snapshot` byte stream for `"2 + 2"` shrank from 74
  to 60 bytes. Snapshots are NOT portable across the 0.17 → 0.18 upgrade —
  consumers persisting snapshots must regenerate them. Pinned by
  `snapshot_format_pinning` in `native/tests/integration.rs`.
- **Building from source now requires Rust 1.95+** (upstream `monty` raised its
  MSRV). Run `rustup update stable`.

### Added

- **`open()` / file I/O.** `memoryMountedOsHandler` services the `Open` OS-call
  (existence-check for `r`/`rb`, truncate-create for `w`/`wb`, create-preserving
  for `a`/`ab`) and the `append_text`/`append_bytes` calls the interpreter
  emits. Python can `open()` files, read/write/append, and use
  `with open(...) as f:` against an in-memory mount. A new **`MontyFileHandle`**
  `MontyValue` represents the returned file object.
- **`resolveOpenCall(...)`** — the store-agnostic `open()` primitive that owns
  the mode→effect mapping (existence-check / truncate / create → file handle,
  with typed errors). `memoryMountedOsHandler` delegates to it, and any
  `OsCallHandler` (e.g. a `package:file`-backed one) can support `open()` by
  supplying its `exists`/`truncate`/`createIfMissing` primitives.
- **Typed OS exceptions.** OS-handler errors are delivered to Python as their
  real class — `except FileNotFoundError:` / `except PermissionError:` now work
  (previously every `OsCallException` surfaced as `RuntimeError`). New FFI +
  WASM resume entry points: `monty_repl_resume_with_exception` and
  `DartMontyBridge.replResumeWithException`.

### Changed

- **Upgraded the embedded interpreter to `monty` v0.0.18** — an `open()` builtin
  with buffered file I/O and `with` / context-manager support, plus upstream
  garbage-collector, exception-safety, and performance fixes.
- **`resolveFutures` per-call errors are now catchable in Python.** An `errors`
  entry on `resolveFutures` is raised as a `RuntimeError` at the `await` point,
  so a wrapping `try/except RuntimeError` catches it normally. Previously this
  short-circuited past Python's exception handling and terminated the script
  with `MontyScriptError`. Scripts that relied on the old script-terminating
  behavior (without a `try/except`) still surface a terminal error.

### Fixed

- **`memoryMountedOsHandler`'s `Path.read_bytes` returns a typed bytes value**
  instead of a bare list, so binary `open(..., 'rb').read()` buffers correctly.

### Known limitations

- `with__cm_*` use `monty`'s synthetic `_test_cm()`, which exists only under the
  testing-only `test-hooks` cargo feature (never shipped). They have dedicated
  conformance on both backends via opt-in test-hooks builds that never touch the
  shipped binaries: `bash tool/test_cm.sh` (FFI) and `bash tool/test_cm_wasm.sh`
  (WASM). The default suites skip them; real `with open(...)` is covered by
  `with__all`.
- `range__ops` (`2**63` range membership) and `edge__int_float_mod`
  (`int % float`) diverge on the shared `monty` wasm32 engine — an upstream
  concern, not a host-binding gap. Skipped on the WASM runners only; both pass
  on native FFI.

## 0.17.1

### Breaking

- **`MontyCallback` is now `(List<Object?> args, Map<String, Object?>? kwargs)`.**
  Positional args by index (`args[0]`…); keyword args in `kwargs`. Old single-map
  form (`args['_0']`) no longer compiles.
- **`.arguments` renamed to `.args`** on `MontyPending`, `MontyOsCall`,
  `CoreProgressResult`, and `WasmProgressResult`.
- **`useFutures` removed** from `feedRun`/`feedStart`/`Monty.run`. Use
  `externalAsyncFunctions` instead.

### Added

- **`inputs:`** on `Monty.run`/`feedRun`/`feedStart` — inject Dart values as
  Python variables for one execution.
- **`externalAsyncFunctions`** — callbacks dispatched via `resumeAsFuture`;
  Python can `await` them and `asyncio.gather` runs them concurrently.
- **`MontyInternalError`** — new `MontyError` subtype for interpreter-internal
  failures.
- **`MontyNone` literal** — `feedRun('None')` now returns `MontyNone`.

## 0.17.0

Re-cut release: align versioning with `dart_monty`. Supersedes the
retracted `0.0.17` (which omitted `native/src/bin/oracle.rs` from
the published archive, breaking the build hook for consumers).

## 0.0.17

Initial release.
