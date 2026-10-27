/// How a session answers the worker's calls on the host's behalf: host
/// functions, OS calls, name lookups and pending futures, as upstream's
/// async binding answers them.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:collection/collection.dart';
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
import 'package:dart_monty_core/src/worker/python_rules.dart'
    show moduleNameError;
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
  ///
  /// The session's host [modules] are the ones the feeds of a session
  /// share, so a factory's result is cached across them. The mapping
  /// [externalModules] is read only when no [modules] are given: the two
  /// name one thing, and the mapping the modules hold is the one that is
  /// read.
  HostAnswers({
    this.externalLookup = const {},
    this.os,
    this.systemSleepMax,
    this.recorder,
    Map<String, Object?>? externalModules,
    HostModules? modules,
    HostObjects? objects,
    List<MountDir>? mount,
    MountRoute? mountRoute,
  }) : modules =
           modules ??
           HostModules(
             externalModules: externalModules ?? HostModules._noModules,
           ),
       externalModules =
           modules?.externalModules ??
           externalModules ??
           HostModules._noModules,
       objects = objects ?? HostObjects(),
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

  /// The session's host modules: the mapping the host gave and the factory
  /// results cached for it.
  ///
  /// One per session, so a factory's result is cached across the session's
  /// feeds, its resets and its resumes.
  final HostModules modules;

  /// The session's host modules, by name: the modules an `import` asks for.
  ///
  /// The very map the session holds, not a copy of it: an entry added,
  /// replaced or removed through it is seen by the next import, as
  /// upstream reads `external_modules`.
  final Map<String, Object?> externalModules;

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
  /// A name carrying a dot is a module call: it is resolved through the
  /// session's host modules, never through the lookup.
  ///
  /// Throws [MontyCrashedError] ([protocolError]) for an arguments arena
  /// upstream rejects when the frame arrives, before anything else: the
  /// caller discards the worker.
  Future<pb.ParentRequest> call(pb.FunctionCall call) async {
    final reader = checkCallArgs(call, objects.lookup);
    if (call.hasObjectId()) return _methodCall(this, call, reader);
    final name = call.functionName;
    if (name.contains('.')) return _moduleCall(this, call, reader, name);
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
  /// An `import` is answered from the session's host modules, before the
  /// mounts and the OS handler see it (upstream's `module_call`).
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
    final kind = call.whichCall();
    final module = _moduleAnswer(this, call, kind);
    if (module != null) return module;
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

/// The session's host modules: the mapping the host gave and the factory
/// results cached for it.
///
/// The mapping is the host's own and is read live, as upstream reads
/// `external_modules`: an entry added, replaced or removed after the
/// session opened is seen by the next import or call. An entry is a module
/// itself, or a factory: a zero-argument function returning one, either
/// synchronously or through a future.
///
/// A factory runs once per session: its result is cached and serves every
/// later import, call and resume. A factory that fails is not cached, so
/// the next use runs it again. A direct entry is never cached: the mapping
/// is read live, and a replaced entry is seen by the next request.
final class HostModules {
  /// Creates the modules of [externalModules]: the very map, not a copy.
  HostModules({this.externalModules = _noModules});

  /// The mapping, as the host gave it.
  final Map<String, Object?> externalModules;

  /// The mapping a set of modules without one of its own holds: empty, and
  /// the same one everywhere, so a feed's own mapping is that one too.
  static const Map<String, Object?> _noModules = {};

  /// What each factory returned, by module name: only a validated result
  /// is cached, never a direct entry, a failure, an invalid result or a
  /// pending future.
  final Map<String, ExternalModule> _factoryResults = {};

  /// Forgets every factory result: the mapping stays as it is, and the
  /// factories run again when they are next needed.
  void clearFactoryResults() => _factoryResults.clear();

  /// The module [name] names, staged: the module itself, the factory's
  /// pending future, the name's absence, or the error that stopped it.
  ///
  /// The cache comes first: a factory's validated result serves every
  /// later request, whatever the mapping holds by then. A direct entry is
  /// returned as it is and never cached, so a replaced entry is seen by the
  /// next request.
  ///
  /// The name is checked when it is reached, as upstream's `check_entry`
  /// checks it: a name that is not an identifier, or one the sandbox
  /// provides itself, cannot name a host module. An entry that is neither
  /// a module nor a factory is refused when it is reached, too.
  ModuleResolution resolve(String name) {
    final cached = _factoryResults[name];
    if (cached != null) return ResolvedModule(cached);
    final Object? entry;
    try {
      entry = externalModules[name];
      // A name the mapping does not hold is absent; a name it holds with no
      // value is an entry the host must fix, not a missing module.
      if (entry == null && !externalModules.containsKey(name)) {
        return const MissingModule();
      }
    } on Object catch (error) {
      return RefusedModule(raisedFrom(error));
    }
    final nameError = moduleNameError(name);
    if (nameError != null) {
      return RefusedModule(
        raisedException('ValueError', nameError, const {}),
      );
    }
    if (entry == null) return RefusedModule(_invalidEntry(name, entry));
    if (entry is ExternalModule) return ResolvedModule(entry);
    if (entry is! Object? Function()) {
      return RefusedModule(_invalidEntry(name, entry));
    }

    return _stage(name, entry);
  }

  /// The module [name] names, awaiting a factory's future: the module
  /// itself, the name's absence, or the error that stopped it.
  ///
  /// A factory's future is awaited here and its result installed, so the
  /// next request finds it in the cache. A failure is not cached: the next
  /// request runs the factory again.
  Future<SettledModule> resolveAsync(String name) async {
    final resolution = resolve(name);

    return switch (resolution) {
      PendingModule(:final future) => await _awaited(name, future),
      ResolvedModule(:final module) => ResolvedModule(module),
      MissingModule() => const MissingModule(),
      RefusedModule(:final error) => RefusedModule(error),
    };
  }

  /// The module [name] holds once [result] is installed: the result
  /// itself, cached for the rest of the session.
  ///
  /// A result that is not an [ExternalModule] is refused, with a
  /// `TypeError` naming the factory and the type it returned, as upstream's
  /// `install_module` raises. Nothing is cached then, and the next request
  /// runs the factory again. The module's attributes are not read here: a
  /// module the sandbox cannot hold is installed all the same.
  ExternalModule install(String name, Object? result) {
    if (result is! ExternalModule) {
      throw ExternalException(
        'TypeError',
        "external_modules['$name']() returned ${_resultTypeName(result)}, "
            'not an ExternalModule',
      );
    }
    _factoryResults[name] = result;

    return result;
  }

  /// The module [name] holds once the factory's [future] is awaited, or
  /// the error that stopped it.
  Future<SettledModule> _awaited(String name, Future<Object?> future) async {
    final Object? result;
    try {
      result = await future;
    } on Object catch (error) {
      return RefusedModule(_factoryError(error));
    }

    return _install(name, result);
  }

  /// The factory [factory]'s result for [name]: the module it built, or
  /// the error that stopped it.
  ///
  /// A factory that returns a future stages it: the future is awaited by
  /// [resolveAsync], which installs its result. A factory that fails
  /// leaves nothing behind, so the next request runs the factory again.
  ModuleResolution _stage(String name, Object? Function() factory) {
    final Object? result;
    try {
      result = factory();
    } on Object catch (error) {
      return RefusedModule(_factoryError(error));
    }
    if (result is Future<Object?>) return PendingModule(result);

    return _install(name, result);
  }

  /// The module [name] holds once [result] is installed, or the error the
  /// refusal answers with.
  SettledModule _install(String name, Object? result) {
    try {
      return ResolvedModule(install(name, result));
    } on Object catch (error) {
      return RefusedModule(_factoryError(error));
    }
  }
}

/// How a module name resolved: the module it holds, the factory's pending
/// future, the name's absence, or the error that stopped it.
sealed class ModuleResolution {
  const ModuleResolution();
}

/// A resolution that is settled: the module, the name's absence, or the
/// error that stopped it.
sealed class SettledModule extends ModuleResolution {
  const SettledModule();
}

/// The module [module] the name holds.
final class ResolvedModule extends SettledModule {
  /// Creates the resolution of the module [module].
  const ResolvedModule(this.module);

  /// The module the name holds.
  final ExternalModule module;
}

/// The factory's [future]: the module it will bring is not known yet.
final class PendingModule extends ModuleResolution {
  /// Creates the resolution of the factory's pending [future].
  const PendingModule(this.future);

  /// The future the factory returned.
  final Future<Object?> future;
}

/// The name holds no entry: the request that needs it is not found.
final class MissingModule extends SettledModule {
  /// Creates the resolution of a name the mapping does not hold.
  const MissingModule();
}

/// The name cannot be resolved: [error] is the exception the request
/// answers with.
final class RefusedModule extends SettledModule {
  /// Creates the resolution refused with [error].
  const RefusedModule(this.error);

  /// The exception the request answers with.
  final pb.RaisedException error;
}

/// The error an entry that is neither a module nor a factory answers with:
/// a `TypeError`, as upstream's `check_entry` raises.
pb.RaisedException _invalidEntry(String name, Object? entry) => raisedException(
  'TypeError',
  "external_modules['$name'] must be an ExternalModule or a callable "
      'returning one, not ${_entryTypeName(entry)}',
  const {},
);

/// How the entry [entry] is named in the refusal upstream's `check_entry`
/// makes: a class is named as one, a function that takes arguments as
/// one, and any other value by its Dart type.
String _entryTypeName(Object? entry) => switch (entry) {
  null => 'Null',
  final Type type => 'the class $type',
  final Function _ => 'a function taking arguments',
  _ => '${entry.runtimeType}',
};

/// The Dart type of the result [result] a factory returned, as the refusal
/// upstream's `install_module` makes names it.
String _resultTypeName(Object? result) =>
    result == null ? 'Null' : '${result.runtimeType}';

/// The Python exception a module factory's failure answers with.
///
/// A factory that builds a module upstream refuses fails with the error
/// upstream's constructor raises: a `ValueError` for an attribute key it
/// refuses, a `TypeError` for a key that is not a string. Any other
/// failure keeps its own type, as [raisedFrom] converts it.
pb.RaisedException _factoryError(Object error) {
  try {
    if (error is ArgumentError) {
      final message = _argumentMessage(error);
      if (message != null && message.startsWith('ExternalModule attrs')) {
        final strKeys = message.startsWith(
          'ExternalModule attrs must have str keys',
        );

        return raisedException(
          strKeys ? 'TypeError' : 'ValueError',
          message,
          const {},
        );
      }
    }
  } on Object {
    // An arbitrary ArgumentError may throw while exposing its message.
    // Preserve the original error's normal protocol conversion.
    return raisedFrom(error);
  }

  return raisedFrom(error);
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

/// Answers the `import` OS call [call] from the session's host modules, as
/// upstream's `import_module` does (monty-python 1.2.0 `src/external.rs`).
///
/// The name the call carries is looked up in the session's map, read live,
/// and only a direct entry is resolved: a nested module is part of the
/// module value the import binds, as upstream's `resolve_module` resolves
/// the top-level name alone. An entry that is a factory is run, and its
/// result is cached for the rest of the session.
///
/// A name the map does not hold is not found, which raises
/// `ModuleNotFoundError` in the sandbox. A name that cannot name a host
/// module raises `ValueError`, and an attribute the sandbox cannot hold
/// raises `TypeError`; both are answered as errors, and no failure of the
/// mapping escapes the answer.
Future<pb.ParentRequest> _import(HostAnswers host, pb.OsCall call) async {
  final callId = call.callId;
  final name = call.import.module;
  final resolution = await host.modules.resolveAsync(name);

  return switch (resolution) {
    ResolvedModule(:final module) => _importValue(host, callId, name, module),
    MissingModule() => _resume(
      callId,
      pb.ExtFunctionResult(notFound: 'import'),
    ),
    RefusedModule(:final error) => _resume(
      callId,
      pb.ExtFunctionResult(error: error),
    ),
  };
}

/// Answers the `import_stubs` OS call [call] from the session's host
/// modules, as upstream's `import_stubs` does (monty-python 1.2.0
/// `src/external.rs`).
///
/// The names the call carries are resolved in the order they were asked
/// for, and a factory that returns a future is staged: every factory of
/// the ask runs before any of them is awaited.
///
/// A failure ends the ask: the factories after it do not run, and the
/// results of the futures staged before it are never installed.
///
/// No failure escapes the ask as a thrown exception: a failure of the
/// resolver itself is answered with the structured error of the failure,
/// under the call's own id.
///
/// The answer is the stubs of every asked module the mapping has, its
/// public submodules included.
Future<pb.ParentRequest> _importStubs(HostAnswers host, pb.OsCall call) async {
  final callId = call.callId;
  final modules = host.modules;
  final names = call.importStubs.modules;
  final List<(String, Future<Object?>)> staged;
  final pb.RaisedException? refusal;
  try {
    (staged, refusal) = _stagedFutures(modules, names);
  } on Object catch (error) {
    // The resolver failed while it staged the ask: the ask ends with the
    // structured error of the failure. The futures staged before it are
    // observed, so their failure is not an unhandled error, and their
    // results are never installed.
    return _failed(callId, error);
  }
  if (refusal != null) return _raises(callId, refusal);
  final List<(String, Object?)> results;
  try {
    results = await _awaitedBatch(staged);
  } on Object catch (error) {
    return _raises(callId, _factoryError(error));
  }
  final failure = _installResults(modules, results);
  if (failure != null) return _raises(callId, failure);

  return _stubsAnswer(host, callId, names);
}

/// The futures of the factories that returned one, by the name they were
/// asked for, in the order they were asked for; the error a factory that
/// fails at once answers with, and null when every factory was staged.
///
/// A factory that fails at once ends the ask: the factories after it do
/// not run, and the futures staged before it are abandoned.
///
/// The resolver may itself fail while it refuses an entry: the failure is
/// thrown, and the caller answers the ask with it.
(List<(String, Future<Object?>)> staged, pb.RaisedException? refusal)
_stagedFutures(HostModules modules, List<String> names) {
  final staged = <(String, Future<Object?>)>[];
  for (final name in names) {
    switch (modules.resolve(name)) {
      case ResolvedModule():
      case MissingModule():
        break;
      case PendingModule(:final future):
        // The future is observed, so the failure of one that is abandoned
        // is not an unhandled error; the future itself is kept, for the
        // batch to await.
        future.ignore();
        staged.add((name, future));
      case RefusedModule(:final error):
        return (staged, error);
    }
  }

  return (staged, null);
}

/// Installs the results of the staged futures, in the order the names were
/// asked for; the error the first result that is not a module answers with,
/// and null when every result was installed.
///
/// The results before an invalid one stay installed; the ones after it are
/// not installed at all.
pb.RaisedException? _installResults(
  HostModules modules,
  List<(String, Object?)> results,
) {
  for (final (name, result) in results) {
    try {
      modules.install(name, result);
    } on Object catch (error) {
      return _factoryError(error);
    }
  }

  return null;
}

/// The results of the staged futures, awaited together: the first failure
/// ends the wait, without waiting for the futures that are still pending.
///
/// Every result is paired with the name it was asked for, so the results
/// are installed in the order the names were asked for.
Future<List<(String, Object?)>> _awaitedBatch(
  List<(String, Future<Object?>)> staged,
) async {
  if (staged.isEmpty) return const [];
  final values = await Future.wait<Object?>(
    [for (final (_, future) in staged) future],
    eagerError: true,
  );
  final results = values.iterator;
  final pairs = <(String, Object?)>[];
  for (final (name, _) in staged) {
    results.moveNext();
    pairs.add((name, results.current));
  }

  return pairs;
}

/// The answer to a stubs ask: the stubs of the modules the names [names]
/// resolve to, in the order they were asked for.
///
/// The names are resolved through the session's host modules once more, so
/// a module a factory built for this ask is the one the answer carries.
///
/// A failure while the answer is built or encoded — a source the wire
/// cannot hold, an attribute that cannot be read — answers the call with
/// the structured error of the failure: no failure escapes the OS call as
/// a thrown exception.
pb.ParentRequest _stubsAnswer(
  HostAnswers host,
  int callId,
  List<String> names,
) {
  final modules = host.modules;
  final pairs = <(MontyValue, MontyValue)>[];
  try {
    for (final name in names) {
      switch (modules.resolve(name)) {
        case ResolvedModule(:final module):
          _collectModuleStubs(name, module, pairs);
        case MissingModule():
          break;
        case RefusedModule(:final error):
          return _raises(callId, error);
        case PendingModule(:final future):
          // The mapping changed under the ask: the name names a factory
          // that is pending again, and was never installed. The future is
          // observed, so the failure of one that is abandoned is not an
          // unhandled error; its result is never installed.
          future.ignore();

          return _raises(callId, _pendingFactory(name));
      }
    }

    return resumeValue(callId, MontyDict(pairs), objects: host.objects);
  } on Object catch (error) {
    return _failed(callId, error);
  }
}

/// The error a factory that is pending again answers with.
pb.RaisedException _pendingFactory(String name) => raisedException(
  'RuntimeError',
  'module factory for $name is still pending after the ask that staged it',
  const {},
);

/// The stubs of the module [module] and of its public submodules, in the
/// order they are reached: the module itself, then its public attributes,
/// in insertion order, each a submodule of its own.
///
/// The path of a module is its own path and the name of the attribute it
/// is held under, joined with a dot, as upstream's `collect_stubs` builds
/// it.
///
/// An ordinary attribute is left alone: it is not converted, and it is not
/// called. Only a submodule is walked into.
void _collectModuleStubs(
  String path,
  ExternalModule module,
  List<(MontyValue, MontyValue)> pairs,
) {
  final source = module.stubs;
  pairs.add((
    MontyString(path),
    source == null ? const MontyNone() : MontyString(source),
  ));
  for (final entry in module.publicAttrs.entries) {
    final value = entry.value;
    if (value is ExternalModule) {
      _collectModuleStubs('$path.${entry.key}', value, pairs);
    }
  }
}

/// The answer to the module OS call [call], when [kind] names one; null
/// when the call is not a module call.
///
/// An `import` and an `import_stubs` are answered from the session's host
/// modules, before the mounts and the OS handler see them.
Future<pb.ParentRequest>? _moduleAnswer(
  HostAnswers host,
  pb.OsCall call,
  pb.OsCall_Call kind,
) => switch (kind) {
  pb.OsCall_Call.import => _import(host, call),
  pb.OsCall_Call.importStubs => _importStubs(host, call),
  _ => null,
};

/// The module value the import binds: the module [module], imported as
/// [name], written into an arena of its own.
pb.ParentRequest _importValue(
  HostAnswers host,
  int callId,
  String name,
  ExternalModule module,
) {
  try {
    final writer = ArenaWriter(objects: host.objects);
    final index = addImport(writer, name, module);

    return _resume(
      callId,
      pb.ExtFunctionResult(returnValue: index),
      writer.arena,
    );
  } on Object catch (error) {
    return _importFailure(callId, error);
  }
}

/// The answer to an import that failed: the error it raised, as the Python
/// exception the worker raises in the sandbox.
///
/// This is the conversion of the module's attributes: a failure of the
/// resolution itself is answered by the resolution, as a dotted call
/// answers it.
///
/// No failure escapes: the error is converted defensively, so an error
/// whose own text cannot be read is answered without a message, as
/// upstream's `exception_arg` gives none when `str()` fails.
pb.ParentRequest _importFailure(int callId, Object error) => _resume(
  callId,
  pb.ExtFunctionResult(error: _importError(error)),
);

/// The Python exception the conversion of a module's attributes answers
/// with.
///
/// A value the sandbox cannot hold is a `TypeError`, as upstream's
/// `value_conversion_err` makes it; any other failure is `Exception` with
/// its own text ([raisedFrom]).
///
/// The conversion cannot fail: an error whose own text cannot be read is
/// answered without one, and an error the conversion cannot handle at all
/// is answered as a plain `Exception`, so the worker is never left waiting
/// for an answer that does not come.
pb.RaisedException _importError(Object error) {
  try {
    if (error is PythonRefusal) return raisedFrom(error);
    if (error is ArgumentError) {
      final message = _argumentMessage(error);
      if (message != null && message.startsWith('Cannot convert')) {
        return raisedException('TypeError', message, const {});
      }
    }

    return raisedFrom(error);
  } on Object {
    return raisedException('Exception', null, const {});
  }
}

/// [error]'s own message, or null when it has none or its text cannot be
/// read: a message that is not a string is read through its own
/// `toString()`, which may throw.
String? _argumentMessage(ArgumentError error) {
  final message = error.message;
  if (message == null) return null;
  if (message is String) return message;
  try {
    return '$message';
  } on Object {
    return null;
  }
}

/// Answers the dotted call [name] through the session's host modules, as
/// upstream's `callable` does (monty-python 1.2.0 `src/external.rs`: the
/// name is split at its last dot, the path before it is walked through the
/// host's modules, one public component at a time, and the leaf is the
/// attribute the module that path names holds).
///
/// The lookup is never consulted for a dotted name: a module attribute is
/// the only thing such a name can name. The first component of the path
/// names the host module, and it is resolved as an import resolves it: a
/// factory is run, and its result is cached for the rest of the session.
/// A name the modules do not hold is not found: the walk stops at the
/// first component that is missing, protected, or not a module. A leaf the
/// module holds but cannot call raises CPython's
/// `'<type>' object is not callable`.
Future<pb.ParentRequest> _moduleCall(
  HostAnswers host,
  pb.FunctionCall call,
  ArenaReader reader,
  String name,
) async {
  final dot = name.lastIndexOf('.');
  final parts = name.substring(0, dot).split('.');
  final resolution = await host.modules.resolveAsync(
    parts.firstOrNull ?? '',
  );

  return switch (resolution) {
    ResolvedModule(:final module) => _moduleLeaf(
      host,
      call,
      reader,
      name,
      module,
      parts,
    ),
    MissingModule() => _resume(
      call.callId,
      pb.ExtFunctionResult(notFound: name),
    ),
    RefusedModule(:final error) => _resume(
      call.callId,
      pb.ExtFunctionResult(error: error),
    ),
  };
}

/// The answer to the dotted call [name]: the attribute the module the path
/// names holds, called as any other host function.
///
/// The module [module] is the one the first component of the path [parts]
/// named; the components below it are walked through it, one public
/// attribute at a time.
Future<pb.ParentRequest> _moduleLeaf(
  HostAnswers host,
  pb.FunctionCall call,
  ArenaReader reader,
  String name,
  ExternalModule module,
  List<String> parts,
) async {
  final dot = name.lastIndexOf('.');
  final target = _moduleBelow(module, parts.skip(1));
  if (target == null) {
    return _resume(call.callId, pb.ExtFunctionResult(notFound: name));
  }
  final attrs = target.publicAttrs;
  final leaf = name.substring(dot + 1);
  if (!attrs.containsKey(leaf)) {
    return _resume(call.callId, pb.ExtFunctionResult(notFound: name));
  }
  final entry = attrs[leaf];
  if (entry is! MontyHostFunction) {
    // Upstream calls the attribute, whatever it is.
    return _resume(
      call.callId,
      pb.ExtFunctionResult(error: _notCallableValue(entry)),
    );
  }

  return _functionCall(host, call, reader, entry);
}

/// The module the components [rest] name below [module], or null when the
/// walk stops: a component that is missing, protected, or not a module ends
/// the walk, as upstream's `module_of` stops at the first missing
/// component.
ExternalModule? _moduleBelow(ExternalModule module, Iterable<String> rest) {
  var current = module;
  for (final part in rest) {
    final attrs = current.publicAttrs;
    if (!attrs.containsKey(part)) return null;
    final child = attrs[part];
    if (child is! ExternalModule) return null;
    current = child;
  }

  return current;
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

/// The exception a call to the raw host value [entry] raises: CPython's
/// `TypeError` for a value that is not callable.
///
/// The name is the type of the value's Python counterpart, read from the
/// value's own type and not from a conversion of it, so a value the
/// conversion refuses still names its type.
pb.RaisedException _notCallableValue(Object? entry) => raisedException(
  'TypeError',
  "'${_rawTypeName(entry)}' object is not callable",
  const {},
);

/// The CPython type name of the raw host value [value], as the binding
/// names it in `'<type>' object is not callable`: the type of the value's
/// Python counterpart, read from the value's own type, without converting
/// the value.
///
/// A value of the value family names its own type ([_typeName]); an
/// ordinary Dart value names the type it converts to; a value with no
/// Python counterpart names its Dart type, as the conversion refusal
/// does.
String _rawTypeName(Object? value) => switch (value) {
  null => 'NoneType',
  // A byte list is a list, so it is named before the list arm.
  final Uint8List _ => 'bytes',
  final BigInt _ => 'int',
  final List<Object?> _ => 'list',
  final Map<Object?, Object?> _ => 'dict',
  final Set<Object?> _ => 'set',
  final MontyValue monty => _typeName(monty),
  _ => _dartTypeNames[value.runtimeType] ?? '${value.runtimeType}',
};

/// The CPython type each plain Dart value stands for, by CPython name.
const Map<Type, String> _dartTypeNames = {
  bool: 'bool',
  int: 'int',
  double: 'float',
  String: 'str',
  DateTime: 'datetime.datetime',
};

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
  MontyComplex: 'complex',
  // Values that decode upstream to the binding's own proxy classes.
  MontyFileHandle: 'pydantic_monty.MontyFileHandle',
  MontyClassProxy: 'pydantic_monty.MontyClassProxy',
  MontyClassTypeProxy: 'pydantic_monty.MontyClassTypeProxy',
  MontyStdTypeProxy: 'pydantic_monty.MontyStdTypeProxy',
  ExternalModule: 'pydantic_monty.ExternalModule',
};

/// `ResumeCall` declining [callId]'s OS call.
pb.ParentRequest _notHandled(int callId) =>
    _resume(callId, pb.ExtFunctionResult(notHandled: pb.Unit()));

/// `ResumeCall` raising [error] at [callId]'s call.
pb.ParentRequest _failed(int callId, Object error) =>
    _resume(callId, pb.ExtFunctionResult(error: raisedFrom(error)));

/// `ResumeCall` raising the Python exception [error] at [callId]'s call.
pb.ParentRequest _raises(int callId, pb.RaisedException error) =>
    _resume(callId, pb.ExtFunctionResult(error: error));

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
