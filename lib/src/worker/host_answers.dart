/// How a session answers the worker's calls on the host's behalf: host
/// functions, OS calls, name lookups and pending futures, as upstream's
/// async binding answers them.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dart_monty_core/src/mount/mount_dir.dart';
import 'package:dart_monty_core/src/mount/native_mount_service.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_not_handled_exception.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart'
    show exceptionTypeNames, rustDebug, uuidString;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedError, MontyRuntimeError, encodingInput, protocolError;
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException, unknownExcType;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry_recorder.dart';

/// A host function Python can call by name.
///
/// Throw [ExternalException] to raise a chosen Python exception; any other
/// throw raises `Exception` with its text ([raisedFrom]).
typedef ProtoExternalFunction =
    FutureOr<MontyValue> Function(
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// Answers an OS call after no mount handles it.
///
/// A synchronous [OsCallNotHandledException] declines the call. The sandbox
/// then raises `PermissionError` for filesystem calls and `RuntimeError` for
/// other calls. A future failure with that exception raises `TypeError`, so a
/// handler that can decline must be synchronous and may return futures for
/// calls it accepts. [ExternalException] selects a Python exception. Any other
/// throw becomes `Exception` with its text.
///
/// [name] passes through without validation. Path arguments are lexically
/// normalized [MontyPath] values. Write and append calls return the character
/// or byte count written.
///
/// A future returned for `asyncio.sleep` or `system.async_sleep` becomes the
/// sandbox coroutine and its value is ignored. Other future results are
/// awaited as answers. For `os.getenv`, the handler must return the second
/// positional argument when the key is absent because the worker does not
/// apply that default.
typedef OsHandler =
    FutureOr<MontyValue> Function(
      String name,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// Where an OS call goes before the OS handler: the mount table's own call,
/// or a route the host injected.
///
/// The route answers with the encoded reply, or null when it declines the
/// call, as the mount table's own call does.
typedef MountRoute = List<int>? Function(List<int>);

/// Marks a host function as a Python coroutine.
///
/// An eagerly awaited call waits in place. Other calls produce pending
/// futures, so `asyncio.gather` can run several concurrently. An unmarked host
/// function waits for its returned future before answering the call.
ProtoExternalFunction coroutine(ProtoExternalFunction function) {
  FutureOr<MontyValue> marked(
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => function(args, kwargs);
  _coroutines[marked] = true;

  return marked;
}

/// Marks a parity host function as a Python coroutine.
FutureOr<Object?> Function(
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
)
parityCoroutine(
  FutureOr<Object?> Function(
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  )
  function,
) {
  FutureOr<Object?> marked(
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => function(args, kwargs);
  _coroutines[marked] = true;

  return marked;
}

/// Whether [function] was marked by [coroutine].
bool isCoroutine(ProtoExternalFunction function) =>
    _coroutines[function] ?? false;

final Expando<bool> _coroutines = Expando('coroutine');

/// Whether the named OS call accepts a future answer.
bool acceptsFuture(String name) =>
    name == 'asyncio.sleep' || name == 'system.async_sleep';

/// An OS call's function name, positional and keyword arguments.
typedef OsCallParts = (String, List<MontyValue>, Map<String, MontyValue>);

/// [call]'s OS function name, positional and keyword arguments, as upstream
/// presents an OS call to a host (`OsFunctionCall::to_args`), host objects
/// resolved through [hosts].
///
/// Throws [FormatException] for a payload [checkOsCall] rejects, and for a
/// `getenv` default that cannot be built.
OsCallParts osCallParts(pb.OsCall call, {HostObjectLookup? hosts}) {
  final reader = checkOsCall(call, hosts: hosts);
  if (reader != null) {
    // The default is any value, a host object's included.
    return (
      'os.getenv',
      [MontyString(call.getenv.key), reader[call.getenv.default_2]],
      _noKwargs,
    );
  }

  return _osCalls[call.whichCall()]!(call);
}

/// Checks [call] as upstream's `os_call_from_proto` does before any host
/// code sees it: an arm is set, an `import_stubs`'s modules are each asked
/// about once, and a `getenv`'s arena is present, passes the reader's first
/// two stages and holds its default's root. Returns the `getenv` default's
/// reader, or null for any other arm.
///
/// Throws [FormatException] with upstream's message (monty-proto 1.2.0
/// `convert/os_call.rs:43-52` and `convert/os_call.rs:194-204`) for the
/// first failure.
ArenaReader? checkOsCall(pb.OsCall call, {HostObjectLookup? hosts}) {
  final kind = call.whichCall();
  if (kind == pb.OsCall_Call.notSet) {
    throw const FormatException('missing required field OsCall.call');
  }
  if (kind == pb.OsCall_Call.importStubs) {
    _checkStubModules(call.importStubs.modules);

    return null;
  }
  if (kind != pb.OsCall_Call.getenv) return null;
  if (!call.hasValues()) {
    throw const FormatException('missing required field OsCall.values');
  }

  return ArenaReader(call.values, hosts: hosts)
    ..checkRoots([call.getenv.default_2]);
}

/// Checks [call]'s arena and every argument root in it, as upstream's
/// `into_call_args` does when the frame arrives; returns the reader.
///
/// Throws [MontyCrashedError] ([protocolError], upstream's `invalid payload
/// from worker`) for an arena or root it rejects: the caller discards the
/// worker. A failure building the Python values is not checked here; it
/// fails the call in Python, as upstream's `wire_call_arguments` does.
ArenaReader checkCallArgs(pb.FunctionCall call, HostObjectLookup? hosts) {
  final reader = ArenaReader(call.values, hosts: hosts);
  try {
    reader.checkRoots([
      ...call.args,
      for (final pair in call.kwargs) ...[pair.key, pair.value],
    ]);
  } on FormatException catch (e) {
    throw protocolError('invalid payload from worker: ${e.message}');
  }

  return reader;
}

const Map<String, MontyValue> _noKwargs = {};

/// The modules an `import_stubs` arm asks about, each of them once.
///
/// Upstream refuses a module named twice (monty-proto 1.2.0
/// `convert/os_call.rs:194-204`): a host runs one factory per name, and a
/// compromised child must not multiply that work.
void _checkStubModules(List<String> modules) {
  final seen = <String>{};
  for (final module in modules) {
    if (!seen.add(module)) {
      throw FormatException(
        'invalid value for ImportStubs.modules: module ${rustDebug(module)} '
        'is asked about twice',
      );
    }
  }
}

OsCallParts _onPath(String name, String path) => (
  name,
  [_path(path)],
  _noKwargs,
);

OsCallParts _sleep(String name, double seconds) => (
  name,
  [MontyFloat(seconds)],
  _noKwargs,
);

MontyValue _path(String path) => MontyPath(normalizeVirtualPath(path));

MontyValue _zoneOrNone(pb.OsCall_DateTimeNow now) => now.hasTz()
    ? MontyTimeZone(
        offsetSeconds: now.tz.offsetSeconds,
        name: now.tz.hasName() ? now.tz.name : null,
      )
    : const MontyNone();

/// Each OS call arm's name and arguments.
final Map<pb.OsCall_Call, OsCallParts Function(pb.OsCall)> _osCalls = {
  pb.OsCall_Call.exists: (c) => _onPath('Path.exists', c.exists),
  pb.OsCall_Call.isFile: (c) => _onPath('Path.is_file', c.isFile),
  pb.OsCall_Call.isDir: (c) => _onPath('Path.is_dir', c.isDir),
  pb.OsCall_Call.isSymlink: (c) => _onPath('Path.is_symlink', c.isSymlink),
  pb.OsCall_Call.readText: (c) => _onPath('Path.read_text', c.readText),
  pb.OsCall_Call.readBytes: (c) => _onPath('Path.read_bytes', c.readBytes),
  pb.OsCall_Call.stat: (c) => _onPath('Path.stat', c.stat),
  pb.OsCall_Call.iterdir: (c) => _onPath('Path.iterdir', c.iterdir),
  pb.OsCall_Call.resolve: (c) => _onPath('Path.resolve', c.resolve),
  pb.OsCall_Call.absolute: (c) => _onPath('Path.absolute', c.absolute),
  pb.OsCall_Call.unlink: (c) => _onPath('Path.unlink', c.unlink),
  pb.OsCall_Call.rmdir: (c) => _onPath('Path.rmdir', c.rmdir),
  pb.OsCall_Call.writeText: (c) => (
    'Path.write_text',
    [_path(c.writeText.path), MontyString(c.writeText.data)],
    _noKwargs,
  ),
  pb.OsCall_Call.appendText: (c) => (
    'Path.append_text',
    [_path(c.appendText.path), MontyString(c.appendText.data)],
    _noKwargs,
  ),
  pb.OsCall_Call.writeBytes: (c) => (
    'Path.write_bytes',
    [_path(c.writeBytes.path), _bytes(c.writeBytes.data)],
    _noKwargs,
  ),
  pb.OsCall_Call.appendBytes: (c) => (
    'Path.append_bytes',
    [_path(c.appendBytes.path), _bytes(c.appendBytes.data)],
    _noKwargs,
  ),
  pb.OsCall_Call.open: (c) => (
    'open',
    [_path(c.open.path), MontyString(c.open.mode)],
    _noKwargs,
  ),
  pb.OsCall_Call.mkdir: (c) => (
    'Path.mkdir',
    [_path(c.mkdir.path)],
    {
      'parents': MontyBool(c.mkdir.parents),
      'exist_ok': MontyBool(c.mkdir.existOk),
    },
  ),
  pb.OsCall_Call.rename: (c) => (
    'Path.rename',
    [_path(c.rename.src), _path(c.rename.dst)],
    _noKwargs,
  ),
  pb.OsCall_Call.getEnviron: (_) => ('os.environ', const [], _noKwargs),
  pb.OsCall_Call.dateToday: (_) => ('date.today', const [], _noKwargs),
  pb.OsCall_Call.dateTimeNow: (c) => (
    'datetime.now',
    [_zoneOrNone(c.dateTimeNow)],
    _noKwargs,
  ),
  pb.OsCall_Call.urandom: (c) => (
    'os.urandom',
    [MontyInt(c.urandom.size.toInt())],
    _noKwargs,
  ),
  pb.OsCall_Call.time: (c) => (
    'time.time',
    [MontyString(c.time.caller)],
    _noKwargs,
  ),
  pb.OsCall_Call.sleep: (c) => _sleep('time.sleep', c.sleep.seconds),
  pb.OsCall_Call.systemSleep: (c) =>
      _sleep('system.sleep', c.systemSleep.seconds),
  pb.OsCall_Call.asyncSleep: (c) => _sleep('asyncio.sleep', c.asyncSleep.delay),
  pb.OsCall_Call.asyncSystemSleep: (c) =>
      _sleep('system.async_sleep', c.asyncSystemSleep.delay),
  pb.OsCall_Call.import: (c) => (
    'import',
    [MontyString(c.import.module)],
    _noKwargs,
  ),
  pb.OsCall_Call.importStubs: (c) => (
    'import_stubs',
    [
      MontyList([
        for (final module in c.importStubs.modules) MontyString(module),
      ]),
    ],
    _noKwargs,
  ),
  pb.OsCall_Call.scan: (c) => (
    'Path.scan',
    [_path(c.scan.path)],
    {
      'max_depth': c.scan.hasMaxDepth()
          ? MontyInt(c.scan.maxDepth)
          : const MontyNone(),
      'follow_symlinks': MontyBool(c.scan.followSymlinks),
      'pattern': c.scan.pattern.isEmpty
          ? const MontyNone()
          : MontyList([
              for (final part in c.scan.pattern) MontyString(part),
            ]),
      'case_sensitive': c.scan.hasCaseSensitive()
          ? MontyBool(c.scan.caseSensitive)
          : const MontyNone(),
      'recurse_symlinks': MontyBool(c.scan.recurseSymlinks),
    },
  ),
};

MontyBytes _bytes(List<int> data) =>
    MontyBytes(Uint8List.fromList(data).asUnmodifiableView());

/// [path] lexically normalized as upstream's `normalize_virtual_path` does:
/// absolute, `.` dropped, `..` resolved and stopped at `/`, a relative path
/// rooted at `/`. An empty path stays empty, as `to_args` leaves it.
String normalizeVirtualPath(String path) {
  if (path.isEmpty || _isNormalized(path)) return path;
  final out = StringBuffer();
  final parts = <String>[];
  for (final segment in path.split('/')) {
    switch (segment) {
      case '' || '.':
        break;
      case '..':
        if (parts.isNotEmpty) parts.removeLast();
      default:
        parts.add(segment);
    }
  }
  for (final part in parts) {
    out
      ..write('/')
      ..write(part);
  }

  return parts.isEmpty ? '/' : out.toString();
}

bool _isNormalized(String path) =>
    path == '/' ||
    (path.startsWith('/') &&
        !path.endsWith('/') &&
        path
            .split('/')
            .skip(1)
            .every((s) => s.isNotEmpty && s != '.' && s != '..'));

/// A `time.sleep` or `asyncio.sleep` delay as the parent waits it: cut to
/// [max]. A delay that is not a finite, non-negative number waits [max],
/// as upstream counts an invalid worker delay.
Duration cappedSleep(double seconds, Duration max) {
  final micros = seconds.isFinite && seconds >= 0
      ? seconds * Duration.microsecondsPerSecond
      : double.infinity;

  return micros >= max.inMicroseconds
      ? max
      : Duration(microseconds: micros.round());
}

/// A feed's mount table and the route its OS calls take.
///
/// The route is the table's own call, or the one the host injected: a
/// supplied route replaces the table's call, it does not follow it.
final class _Mounts {
  const _Mounts(this.table, this.route);

  /// The feed's overlay and budgets, absent without mounts.
  final NativeMountTable? table;

  /// Where an OS call goes before the OS handler.
  final MountRoute? route;
}

/// The mount table for [mount], and the route its calls take: the injected
/// [route] when there is one, else the table's own call.
_Mounts _mountsFor(List<MountDir>? mount, MountRoute? route) {
  final table = beginMountFeed(mount);

  return _Mounts(table, route ?? table?.call);
}

/// The host's side of one feed: its external lookup, OS handler and the
/// coroutines it has started, answering the worker's suspensions as
/// upstream's async binding does.
///
/// A host function answers with its value (a returned future is awaited
/// first). One marked with [coroutine] is awaited in place when the sandbox
/// awaits the call with nothing else to run (`allow_eager_await`), and
/// otherwise started and answered with a pending future, settled when the
/// sandbox blocks on it.
///
/// A method call or lazy attribute read on a host object goes to the
/// wrapper [objects] registered under its id. A method's future is a
/// coroutine's, as an `async def` method's coroutine is upstream.
final class HostAnswers {
  /// The answers for one feed, its host objects in [objects] (a fresh
  /// registry without one).
  HostAnswers({
    this.externalLookup = const {},
    this.os,
    this.systemSleepMax,
    this.recorder,
    this.externalModules = const {},
    HostObjects? objects,
    List<MountDir>? mount,
    MountRoute? mountRoute,
  }) : objects = objects ?? HostObjects(),
       _mounts = _mountsFor(mount, mountRoute);

  /// Callback context for this checkout, absent without instrumentation.
  final TelemetryRecorder? recorder;

  /// The session's host objects.
  final HostObjects objects;

  /// What names the sandbox leaves undefined resolve to: a host function
  /// ([MontyHostFunction]), or any other value, converted when the name is
  /// read.
  final Map<String, MontyValue> externalLookup;

  /// The OS handler; without one every OS call is declined.
  final OsHandler? os;

  /// The session's host modules, by name: the modules an `import` asks for.
  ///
  /// The map is read live, as upstream reads `external_modules`: an entry
  /// added, replaced or removed after the session opened is seen by the
  /// next import.
  final Map<String, ExternalModule> externalModules;

  /// The longest system sleep the parent waits; null declines system sleeps.
  final Duration? systemSleepMax;

  /// This feed's overlay and budgets, and where its OS calls go.
  final _Mounts _mounts;

  /// Coroutines started and not yet delivered, by call id.
  final Set<int> _running = {};

  /// System sleeps still waiting: each one's timer and completion.
  final Set<(Timer, Completer<void>)> _sleeps = {};

  /// Settled coroutines, oldest first, not yet delivered.
  final Queue<(int, _Outcome)> _settled = Queue();

  Completer<void>? _wake;

  /// Whether a started coroutine has not been delivered yet.
  bool get hasPending => _running.isNotEmpty || _settled.isNotEmpty;

  /// The answer to the suspension [event], as a feed gives it: a system
  /// sleep is waited by the parent. Null for an event that is no suspension
  /// this side can answer, a `ResolveFutures` with no coroutine started
  /// included.
  Future<pb.ParentRequest?> answer(pb.ChildEvent event) async =>
      switch (event.whichKind()) {
        pb.ChildEvent_Kind.nameLookup => lookup(
          event.nameLookup.name,
          objectId: event.nameLookup.hasObjectId()
              ? uuidString(event.nameLookup.objectId.data)
              : null,
        ),
        pb.ChildEvent_Kind.functionCall => await call(event.functionCall),
        pb.ChildEvent_Kind.osCall => await osCall(
          event.osCall,
          parentSleeps: true,
        ),
        pb.ChildEvent_Kind.resolveFutures when hasPending => await settle(),
        _ => null,
      };

  /// Answers the host function call [call]; one with an object id is a
  /// method call on that host object.
  ///
  /// Throws [MontyCrashedError] ([protocolError]) for an arguments arena
  /// upstream rejects when the frame arrives, before anything else: the
  /// caller discards the worker.
  Future<pb.ParentRequest> call(pb.FunctionCall call) async {
    final reader = checkCallArgs(call, objects.lookup);
    if (call.hasObjectId()) return _methodCall(this, call, reader);
    final name = call.functionName;
    final MontyValue? entry;
    try {
      entry = externalLookup[name];
    } on Object catch (error) {
      return _resume(
        call.callId,
        pb.ExtFunctionResult(error: raisedFrom(error)),
      );
    }
    if (entry == null) {
      return _resume(call.callId, pb.ExtFunctionResult(notFound: name));
    }
    if (entry is! MontyHostFunction) {
      // Upstream calls the entry, whatever it is.
      return _resume(
        call.callId,
        pb.ExtFunctionResult(error: _notCallable(entry)),
      );
    }

    return _functionCall(this, call, reader, entry);
  }

  /// Answers a lookup of [name]: with [objectId], a lazy attribute of that
  /// host object; otherwise [externalLookup]'s entry. A host function
  /// resolves to a function named [name], its lookup key, which the worker
  /// calls back; a value is converted now; an absent name is undefined.
  ///
  /// A value the writer refuses throws, as [MontyRuntimeError] for one
  /// Python refuses ([encodingInput]): upstream does not answer it, and
  /// discards the checkout. The caller ends the session.
  pb.ParentRequest lookup(String name, {String? objectId}) {
    if (objectId != null) {
      final recording = recorder;

      return recording == null
          ? _attribute(objects, objectId, name)
          : _invoke3(recording, _attribute, objects, objectId, name);
    }
    final entry = externalLookup[name];
    if (entry == null) {
      return pb.ParentRequest(
        resumeNameLookup: pb.ResumeNameLookup(undefined: pb.Unit()),
      );
    }
    if (entry is MontyHostFunction) {
      // Renamed to its key, as upstream renames the function it converts,
      // so the call comes back to this entry.
      final arena = pb.Arena(
        nodeCount: 1,
        nodes: [functionNode(name, docstring: entry.docstring)],
      );

      return pb.ParentRequest(
        resumeNameLookup: pb.ResumeNameLookup(values: arena, value: 0),
      );
    }
    final writer = ArenaWriter(objects: objects);
    final index = encodingInput(() => writer.add(entry));

    return pb.ParentRequest(
      resumeNameLookup: pb.ResumeNameLookup(
        values: writer.arena,
        value: index,
      ),
    );
  }

  /// Answers the OS call [call]. With [parentSleeps] a system sleep is
  /// waited here, as `feedRun` waits it; without, it goes to the handler
  /// like any other call, as a resumed snapshot's does upstream.
  ///
  /// Throws [MontyCrashedError] ([protocolError], upstream's `invalid OS
  /// call payload`) for a payload [checkOsCall] rejects, before anything
  /// else: the caller discards the worker.
  Future<pb.ParentRequest> osCall(
    pb.OsCall call, {
    required bool parentSleeps,
  }) async {
    try {
      checkOsCall(call);
    } on FormatException catch (e) {
      throw protocolError('invalid OS call payload: ${e.message}');
    }
    final max = systemSleepMax;
    final slept = parentSleeps && max != null ? _systemSleep(call, max) : null;
    if (slept != null) return slept;
    final mounted = _mounts.route?.call(call.writeToBuffer());
    if (mounted != null) {
      return pb.ParentRequest(resumeCall: pb.ResumeCall.fromBuffer(mounted));
    }
    final handler = os;
    if (handler == null) return _notHandled(call.callId);
    final OsCallParts parts;
    try {
      parts = osCallParts(call, hosts: objects.lookup);
    } on Object catch (error) {
      return _failed(call.callId, error);
    }

    return _handle(call, parts, handler);
  }

  /// Waits for at least one started coroutine to settle, then answers the
  /// worker's `ResolveFutures` with every one settled by then (upstream's
  /// `wait_for_futures`). Throws [StateError] when none was started.
  Future<pb.ParentRequest> settle() async {
    if (_settled.isEmpty) {
      if (_running.isEmpty) {
        throw StateError('No pending async tasks but ResolveFutures requested');
      }
      await (_wake = Completer<void>()).future;
    }
    final results = <(int, _Outcome)>[];
    while (_settled.isNotEmpty) {
      results.add(_settled.removeFirst());
    }

    return futuresRequest(
      results.map((r) => (r.$1, r.$2.result)),
      objects: objects,
    );
  }

  /// Drops the feed's mount table and ends every system sleep still waiting,
  /// so no table or timer outlives the feed (upstream drops pending tasks with
  /// the drive). A sleep the drive still awaits returns at once; one behind
  /// a pending future settles, unread.
  void dispose() {
    _mounts.table?.close();
    for (final (timer, done) in [..._sleeps]) {
      timer.cancel();
      if (!done.isCompleted) done.complete();
    }
    _sleeps.clear();
  }

  /// The parent's wait for a system sleep [call], capped at [max]; null when
  /// [call] is no system sleep.
  Future<pb.ParentRequest>? _systemSleep(pb.OsCall call, Duration max) {
    switch (call.whichCall()) {
      case pb.OsCall_Call.systemSleep:
        return _slept(call.callId, cappedSleep(call.systemSleep.seconds, max));
      case pb.OsCall_Call.asyncSystemSleep:
        final wait = cappedSleep(call.asyncSystemSleep.delay, max);

        return _coroutine(call.callId, call.allowEagerAwait, _sleepNone(wait));
      // ignore: no_default_cases, every other call goes to the handler.
      default:
        return null;
    }
  }

  /// [handler]'s answer to [call], named and argued as [parts].
  Future<pb.ParentRequest> _handle(
    pb.OsCall call,
    OsCallParts parts,
    OsHandler handler,
  ) async {
    final (name, args, kwargs) = parts;
    final callId = call.callId;
    try {
      final recording = recorder;
      final answer = recording == null
          ? handler(name, args, kwargs)
          : _invoke3(recording, handler, name, args, kwargs);
      if (answer is MontyValue) {
        return resumeValue(callId, answer, objects: objects);
      }
      // For `asyncio.sleep` a future is the call's coroutine. Its value is
      // ignored: the sandbox keeps the sleep's own result.
      if (acceptsFuture(name)) {
        return await _coroutine(
          callId,
          call.allowEagerAwait,
          _undeclined(answer),
        );
      }

      return resumeValue(
        callId,
        await _undeclined(answer),
        objects: objects,
      );
    } on OsCallNotHandledException {
      // Only a synchronous throw lands here; a decline from a future is an
      // AsyncDecline.
      return _notHandled(callId);
    } on Object catch (error) {
      return _failed(callId, error);
    }
  }

  /// The coroutine [work], already started, answering [callId]: awaited
  /// now and delivered through `ResumeFutures` when the sandbox awaits it
  /// eagerly, else answered with a future and delivered once it settles.
  Future<pb.ParentRequest> _coroutine(
    int callId,
    bool eager,
    Future<Object?> work, {
    bool parity = false,
  }) async {
    final outcome = _Outcome.of(work, parity: parity);
    if (eager) {
      return futuresRequest([
        (callId, (await outcome).result),
      ], objects: objects);
    }
    _running.add(callId);
    unawaited(_settleWhenDone(callId, outcome));

    return _resume(callId, pb.ExtFunctionResult(future: callId));
  }

  /// Waits [duration] on a timer [dispose] can end early.
  Future<void> _wait(Duration duration) {
    final done = Completer<void>();
    final entry = (Timer(duration, done.complete), done);
    _sleeps.add(entry);

    return done.future.whenComplete(() => _sleeps.remove(entry));
  }

  /// `None` once [wait] has passed.
  Future<MontyValue> _sleepNone(Duration wait) async {
    await _wait(wait);

    return const MontyNone();
  }

  /// `ResumeCall` answering [callId] with `None` once [wait] has passed.
  Future<pb.ParentRequest> _slept(int callId, Duration wait) async {
    await _wait(wait);

    return resumeValue(callId, const MontyNone(), objects: objects);
  }

  /// Queues [callId]'s [outcome] once it is known, and wakes a [settle]
  /// waiting for one.
  Future<void> _settleWhenDone(int callId, Future<_Outcome> outcome) async {
    final settled = await outcome;
    _running.remove(callId);
    _settled.add((callId, settled));
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }
}

/// Answers [call] with the resolved host function [entry]: run in place when
/// synchronous, or as a coroutine when marked by [coroutine] or
/// [parityCoroutine].
Future<pb.ParentRequest> _functionCall(
  HostAnswers host,
  pb.FunctionCall call,
  ArenaReader reader,
  MontyHostFunction entry,
) {
  final rawFn = entry.parityFn ?? entry.fn;
  // Building the argument values is inside the guarded body too: a value
  // this driver cannot carry fails the call in Python, and the worker,
  // suspended on it, still gets its answer.
  FutureOr<Object?> invoke() {
    final args = [for (final a in call.args) reader[a]];

    return rawFn(args, _kwargs(reader, call.kwargs));
  }

  final recording = host.recorder;
  final callback = recording == null
      ? invoke
      : () => _invoke(recording, invoke);
  final parity = entry.isParity;
  if (!(_coroutines[rawFn] ?? false)) {
    return _resumeWith(call.callId, callback, host.objects, parity: parity);
  }

  return host._coroutine(
    call.callId,
    call.allowEagerAwait,
    _started(callback),
    parity: parity,
  );
}

/// Answers a method call on the host object [call] names: refused for an
/// underscore name other than `__call__` before anything else, as
/// upstream refuses one; then dispatched to the registered wrapper. A
/// future result is a coroutine's.
Future<pb.ParentRequest> _methodCall(
  HostAnswers host,
  pb.FunctionCall call,
  ArenaReader reader,
) async {
  final objects = host.objects;
  final FutureOr<Object> result;
  try {
    checkHostMethodName(call.functionName);
    final id = uuidString(call.objectId.data);
    final name = call.functionName;
    final args = [for (final a in call.args) reader[a]];
    final kwargs = _kwargs(reader, call.kwargs);
    final recording = host.recorder;
    result = recording == null
        ? objects.callMethod(id, name, args, kwargs)
        : _invoke4(recording, objects.callMethod, id, name, args, kwargs);
  } on Object catch (error) {
    return _failed(call.callId, error);
  }
  if (result is Future<Object>) {
    return host._coroutine(call.callId, call.allowEagerAwait, result);
  }

  return _resumeWith(call.callId, () => result, objects);
}

/// A lazy attribute [name] of the host object [id]: its value, undefined
/// when it is not exposed, or the exception reading it raised.
pb.ParentRequest _attribute(HostObjects objects, String id, String name) {
  pb.ResumeNameLookup answer;
  try {
    final value = objects.lookupLazyAttr(id, name);
    answer = pb.ResumeNameLookup(undefined: pb.Unit());
    if (value != null) {
      final writer = ArenaWriter(objects: objects);
      final index = writer.add(value);
      answer = pb.ResumeNameLookup(values: writer.arena, value: index);
    }
  } on Object catch (error) {
    answer = pb.ResumeNameLookup(error: raisedFrom(error));
  }

  return pb.ParentRequest(resumeNameLookup: answer);
}

/// A coroutine's outcome: a value or a throw.
final class _Outcome {
  const _Outcome.value(this.value, {this.parity = false}) : error = null;

  const _Outcome.error(Object this.error, {this.parity = false}) : value = null;

  final Object? value;
  final Object? error;
  final bool parity;

  ExternalAnswer get result {
    if (error case final err?) {
      return ExternalAnswer.error(raisedFrom(err), parity: parity);
    }

    return ExternalAnswer.value(
      parity && value == null ? const MontyNone() : value,
      parity: parity,
    );
  }

  static Future<_Outcome> of(
    Future<Object?> work, {
    bool parity = false,
  }) async {
    try {
      return _Outcome.value(await work, parity: parity);
    } on Object catch (error) {
      return _Outcome.error(error, parity: parity);
    }
  }
}

/// A settled answer as the wire carries it: a value or a raised exception.
final class ExternalAnswer {
  /// The call returned [value].
  const ExternalAnswer.value(
    this.value, {
    this.parity = false,
  }) : error = null;

  /// The call raised [error].
  const ExternalAnswer.error(
    pb.RaisedException this.error, {
    this.parity = false,
  }) : value = null;

  /// The value, when the call returned one: a [MontyValue], a host
  /// object's wrapper included.
  final Object? value;

  /// The exception, when the call raised one.
  final pb.RaisedException? error;

  /// Whether [value] is serialized under Monty 1.1.0 parity rules.
  final bool parity;
}

/// `ResumeFutures` settling each (call id, answer) of [results], their
/// values in one arena, host objects registered in [objects]. A value the
/// writer refuses settles its future with the exception the refusal raises
/// instead ([raisedFrom]); with [strict] the refusal is thrown.
pb.ParentRequest futuresRequest(
  Iterable<(int, ExternalAnswer)> results, {
  HostObjects? objects,
  bool strict = false,
}) {
  final writer = ArenaWriter(objects: objects);
  final out = <pb.FutureResult>[];
  for (final (callId, answer) in results) {
    writer.separate();
    out.add(
      pb.FutureResult(
        callId: callId == 0 ? null : callId,
        result: _wire(answer, writer, strict: strict),
      ),
    );
  }

  return pb.ParentRequest(
    resumeFutures: pb.ResumeFutures(results: out, values: writer.arena),
  );
}

pb.ExtFunctionResult _wire(
  ExternalAnswer answer,
  ArenaWriter writer, {
  required bool strict,
}) {
  if (answer.error case final error?) {
    return pb.ExtFunctionResult(error: error);
  }
  final value = answer.parity && answer.value == null
      ? const MontyNone()
      : answer.value;
  if (value == null) {
    return pb.ExtFunctionResult(
      error: pb.RaisedException(excType: 'RuntimeError'),
    );
  }
  if (strict) {
    return pb.ExtFunctionResult(
      returnValue: writer.add(value, parity: answer.parity),
    );
  }
  try {
    // A refused value leaves no nodes behind in the shared arena.
    return pb.ExtFunctionResult(
      returnValue: writer.tryAdd(value, parity: answer.parity),
    );
  } on Object catch (error) {
    return pb.ExtFunctionResult(error: raisedFrom(error));
  }
}

Map<String, MontyValue> _kwargs(ArenaReader reader, List<pb.NodePair> pairs) {
  final kwargs = <String, MontyValue>{};
  for (final pair in pairs) {
    final key = reader[pair.key];
    if (key is! MontyString) {
      throw FormatException(
        'a keyword argument name must be a str; the worker sent a '
        '${key.runtimeType}',
      );
    }
    kwargs[key.value] = reader[pair.value];
  }

  return kwargs;
}

/// [call]'s keyword arguments, in order, host objects resolved through
/// [hosts].
Map<String, MontyValue> callKwargs(
  pb.FunctionCall call, {
  HostObjectLookup? hosts,
}) => _kwargs(ArenaReader(call.values, hosts: hosts), call.kwargs);

/// [call]'s positional arguments, host objects resolved through [hosts].
List<MontyValue> callArgs(pb.FunctionCall call, {HostObjectLookup? hosts}) {
  final reader = ArenaReader(call.values, hosts: hosts);

  return [for (final a in call.args) reader[a]];
}

Future<pb.ParentRequest> _resumeWith(
  int callId,
  FutureOr<Object?> Function() body,
  HostObjects objects, {
  bool parity = false,
}) async {
  final Object? value;
  try {
    value = await body();
  } on Object catch (error) {
    return _resume(callId, pb.ExtFunctionResult(error: raisedFrom(error)));
  }
  try {
    return resumeValue(
      callId,
      parity && value == null ? const MontyNone() : value,
      objects: objects,
      parity: parity,
    );
  } on Object catch (error) {
    return _resume(callId, pb.ExtFunctionResult(error: raisedFrom(error)));
  }
}

/// [invoke]'s result as a started future; a synchronous throw is its error.
Future<Object?> _started(FutureOr<Object?> Function() invoke) =>
    Future.sync(invoke);

/// [answer]'s value; an [OsCallNotHandledException] it fails with is an
/// [AsyncDecline].
Future<MontyValue> _undeclined(Future<MontyValue> answer) async {
  try {
    return await answer;
  } on OsCallNotHandledException {
    throw const AsyncDecline();
  }
}

/// An [OsCallNotHandledException] an OS handler's future failed with.
///
/// Upstream declines only a synchronous `NOT_HANDLED`. One a coroutine
/// returns is a value it cannot convert, raised in the sandbox as
/// `TypeError`, for every call, `asyncio.sleep` and `time.sleep` included
/// (monty-python 1.1.0 `pool.rs:2103-2108`: only the synchronous result is
/// compared with `NOT_HANDLED`); [raisedFrom] raises this as that
/// `TypeError`.
final class AsyncDecline implements Exception {
  /// A decline from a future.
  const AsyncDecline();

  /// The `TypeError`'s message: upstream's conversion refusal ("Cannot
  /// convert pydantic_monty._NotHandledSentinel to Monty value — wrap class
  /// instances in pydantic_monty.ClassInstance(...)"), naming the Dart
  /// classes as the writer's refusal does.
  static const String message =
      'Cannot convert OsCallNotHandledException to Monty value — wrap class '
      'instances in ClassInstance(...)';

  @override
  String toString() => 'AsyncDecline: $message';
}

/// The name CPython's `'<type>' object is not callable` gives the host
/// object an [HostAnswers.externalLookup] entry stands for: the binding
/// calls the entry itself, so the name is the host type's, as upstream's
/// Python host object would have it (a `datetime.date`, a
/// `PurePosixPath`, the wrapper classes), not the sandbox's.
String _typeName(MontyValue entry) => switch (entry) {
  ClassInstance() => 'ClassInstance',
  ClassType() => 'ClassType',
  // CPython names an exception class without its module; re.PatternError
  // is an alias of the class named `error`.
  MontyExceptionValue(excType: 're.PatternError') => 'error',
  MontyExceptionValue(:final excType) => excType.substring(
    excType.lastIndexOf('.') + 1,
  ),
  MontyNamedTuple(:final typeName) => typeName,
  _ => _hostTypeNames[entry.runtimeType] ?? 'object',
};

/// The exception a call to the [HostAnswers.externalLookup] value [entry]
/// raises: CPython's `TypeError` for a host object that is not callable.
///
/// A builtin type ([MontyStdTypeProxy] of kind `type`) is the one value
/// upstream can call, since it decodes to the Python type itself: `int("42")`
/// runs on the host. Dart has no Python builtins to run, so that call raises
/// `TypeError` instead (the recorded divergence
/// `builtin-type-call-by-name`); a read of the name, such as
/// `t = p`, gives the sandbox the type, which it calls as upstream does.
pb.RaisedException _notCallable(MontyValue entry) => raisedException(
  'TypeError',
  switch (entry) {
    MontyStdTypeProxy(kind: 'type', :final name) =>
      "builtin type '$name' cannot be called from externalLookup by name; "
          'read the name first',
    _ => "'${_typeName(entry)}' object is not callable",
  },
  const {},
);

/// The host type each plain [MontyValue] stands for, by CPython name.
const Map<Type, String> _hostTypeNames = {
  MontyNone: 'NoneType',
  MontyBool: 'bool',
  MontyInt: 'int',
  MontyBigInt: 'int',
  MontyFloat: 'float',
  MontyString: 'str',
  MontyBytes: 'bytes',
  MontyList: 'list',
  MontyTuple: 'tuple',
  MontyDict: 'dict',
  MontySet: 'set',
  MontyFrozenSet: 'frozenset',
  MontyPath: 'PurePosixPath',
  MontyDate: 'datetime.date',
  MontyDateTime: 'datetime.datetime',
  MontyTime: 'datetime.time',
  MontyTimeDelta: 'datetime.timedelta',
  MontyTimeZone: 'datetime.timezone',
  MontyEllipsis: 'ellipsis',
  MontyNotImplemented: 'NotImplementedType',
  // Values that decode upstream to the binding's own proxy classes.
  MontyFileHandle: 'pydantic_monty.MontyFileHandle',
  MontyClassProxy: 'pydantic_monty.MontyClassProxy',
  MontyStdTypeProxy: 'pydantic_monty.MontyStdTypeProxy',
};

/// `ResumeCall` declining [callId]'s OS call.
pb.ParentRequest _notHandled(int callId) =>
    _resume(callId, pb.ExtFunctionResult(notHandled: pb.Unit()));

/// `ResumeCall` raising [error] at [callId]'s call.
pb.ParentRequest _failed(int callId, Object error) =>
    _resume(callId, pb.ExtFunctionResult(error: raisedFrom(error)));

/// `ResumeCall` answering [callId] with [value], a [MontyValue] or a host
/// object's wrapper, registered in [objects].
pb.ParentRequest resumeValue(
  int callId,
  Object? value, {
  HostObjects? objects,
  bool parity = false,
}) {
  final writer = ArenaWriter(objects: objects);
  final index = writer.add(value, parity: parity);

  return _resume(
    callId,
    pb.ExtFunctionResult(returnValue: index),
    writer.arena,
  );
}

/// `ResumeCall` answering [callId] with [result].
pb.ParentRequest resumeWith(int callId, pb.ExtFunctionResult result) =>
    _resume(callId, result);

pb.ParentRequest _resume(
  int callId,
  pb.ExtFunctionResult result, [
  pb.Arena? values,
]) => pb.ParentRequest(
  // A zero id is left unset, as upstream's encoder leaves a proto3 default:
  // the frame's size, which an oversized answer's error reports, then
  // matches upstream's to the byte.
  resumeCall: pb.ResumeCall(
    callId: callId == 0 ? null : callId,
    result: result,
    values: values,
  ),
);

/// Converts a host throw into the Python exception sent to the worker.
///
/// [PythonRefusal] retains its Python error. A recognized [ExternalException]
/// retains its requested type. An unknown requested type from live host code
/// becomes plain `Exception` with the validation error text. Any other throw
/// becomes `Exception` with its own text.
pb.RaisedException raisedFrom(Object error) => switch (error) {
  PythonRefusal(:final excType, :final text) => pb.RaisedException(
    excType: excType,
    message: text,
  ),
  ExternalException(:final excType, :final message, :final attributes)
      when exceptionTypeNames.contains(excType) =>
    raisedException(excType, message ?? _noArgText(excType), attributes),
  ExternalException(:final excType) => _fallback(unknownExcType(excType)),
  AsyncDecline() => pb.RaisedException(
    excType: 'TypeError',
    message: AsyncDecline.message,
  ),
  _ => _fallback(error),
};

/// `Exception` carrying [error]'s text, read as [raisedException] reads a
/// message; with no message when the text cannot be had, as upstream's
/// `exception_arg` gives none when `str()` fails.
pb.RaisedException _fallback(Object error) {
  String? text;
  try {
    text = '$error';
  } on Object {
    text = null;
  }

  return raisedException('Exception', text, const {});
}

/// The message upstream's `exception_arg` reads off an exception raised
/// with no argument: its `str()`, which is `'None'` for a `SyntaxError`
/// (whose `msg` is None) and `''` for every other type.
String _noArgText(String excType) => excType == 'SyntaxError' ? 'None' : '';

/// All host callback entry points share the same exactly-once invoker.
R _invoke<R>(TelemetryRecorder recorder, R Function() body) =>
    recorder.invoke(body);

// Called only with instrumentation: the uninstalled path allocates no
// context wrapper closures or method tear-offs.
R _invoke3<R, A, B, C>(
  TelemetryRecorder recorder,
  R Function(A, B, C) body,
  A a,
  B b,
  C c,
) => _invoke(recorder, () => body(a, b, c));

R _invoke4<R, A, B, C, D>(
  TelemetryRecorder recorder,
  R Function(A, B, C, D) body,
  A a,
  B b,
  C c,
  D d,
) => _invoke(recorder, () => body(a, b, c, d));
