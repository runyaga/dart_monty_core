/// How a session answers the worker's calls on the host's behalf: host
/// functions, OS calls, name lookups and pending futures, as upstream's
/// async binding answers them.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart'
    show exceptionTypeNames, uuidString;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException, unknownExcType;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

/// A host function Python can call by name.
///
/// Throw [ExternalException] to raise a chosen Python exception; any other
/// throw raises `Exception` with its text ([raisedFrom]).
typedef ProtoExternalFunction =
    FutureOr<MontyValue> Function(
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// Upstream's `OsHandler`: answers the OS calls such as `Path.read_text`
/// that no mount covers.
///
/// [name] is upstream's OS function name, never validated, and [args] and
/// [kwargs] its arguments, as upstream's `OsFunctionCall::to_args` gives
/// them: a path is a [MontyPath], lexically normalized. The returned value
/// is the answer; [MontyNone] is `None`. Throw [OsCallNotHandledException]
/// to decline (upstream's `NOT_HANDLED`): the worker then raises the call's
/// own default, `PermissionError` naming the path for a filesystem call and
/// `RuntimeError` for the rest. Only a synchronous throw declines, as only a
/// synchronously returned `NOT_HANDLED` does upstream; a returned [Future]
/// that fails with it raises `TypeError` ([AsyncDecline]), so an `async`
/// handler cannot decline. Throw [ExternalException] to raise a chosen
/// exception; any other throw raises `Exception` with its text
/// ([raisedFrom]). For `asyncio.sleep` a returned [Future] is the call's
/// coroutine, which the sandbox awaits. For every other call it is awaited
/// and its value is the answer.
typedef OsHandler =
    FutureOr<MontyValue> Function(
      String name,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// Marks [function] as a coroutine, as an `async def` host function is
/// upstream: the sandbox gets an awaitable for each call, settled through
/// the futures protocol when [function]'s future completes. Unmarked, a host
/// function's returned future is awaited and its value is the call's answer.
ProtoExternalFunction coroutine(ProtoExternalFunction function) {
  FutureOr<MontyValue> marked(
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

/// Whether an OS call named [name] may be answered with a future: only
/// `asyncio.sleep`, in either sleep mode (upstream
/// `OsFunctionCall::accepts_future`).
bool acceptsFuture(String name) =>
    name == 'asyncio.sleep' || name == 'system.async_sleep';

/// An OS call's function name, positional and keyword arguments.
typedef OsCallParts = (String, List<MontyValue>, Map<String, MontyValue>);

/// [call]'s OS function name, positional and keyword arguments, as upstream
/// presents an OS call to a host (`OsFunctionCall::to_args`), host objects
/// resolved through [hosts]. Throws [FormatException] for a call with no
/// arm set.
OsCallParts osCallParts(pb.OsCall call, {HostObjectLookup? hosts}) {
  if (call.whichCall() == pb.OsCall_Call.getenv) {
    // The default is any value, a host object's included.
    return (
      'os.getenv',
      [
        MontyString(call.getenv.key),
        ArenaReader(call.values, hosts: hosts)[call.getenv.default_2],
      ],
      _noKwargs,
    );
  }
  final parts = _osCalls[call.whichCall()];
  if (parts == null) {
    throw const FormatException('invalid OS call payload: no call');
  }

  return parts(call);
}

const Map<String, MontyValue> _noKwargs = {};

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

/// The host's side of one feed: its host functions, OS handler and the
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
    this.externals = const {},
    this.os,
    this.systemSleepMax,
    HostObjects? objects,
  }) : objects = objects ?? HostObjects();

  /// The session's host objects.
  final HostObjects objects;

  /// The host functions, by the name the sandbox calls.
  final Map<String, ProtoExternalFunction> externals;

  /// The OS handler; without one every OS call is declined.
  final OsHandler? os;

  /// The longest system sleep the parent waits; null declines system sleeps.
  final Duration? systemSleepMax;

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
  Future<pb.ParentRequest> call(pb.FunctionCall call) async {
    if (call.hasObjectId()) return _methodCall(this, call);
    final name = call.functionName;
    final function = externals[name];
    if (function == null) {
      return _resume(call.callId, pb.ExtFunctionResult(notFound: name));
    }
    // Decoding the arguments is inside the guarded body too: an argument
    // this driver cannot carry fails the call in Python, and the worker,
    // suspended on it, still gets its answer.
    FutureOr<MontyValue> invoke() {
      final reader = ArenaReader(call.values, hosts: objects.lookup);
      final args = [for (final a in call.args) reader[a]];

      return function(args, _kwargs(reader, call.kwargs));
    }

    if (!isCoroutine(function)) {
      return _resumeWith(call.callId, invoke, objects);
    }

    return _coroutine(call.callId, call.allowEagerAwait, _started(invoke));
  }

  /// Answers a lookup of [name]: with [objectId], a lazy attribute of that
  /// host object; otherwise a host function by that name resolves to
  /// itself, which the worker calls back, and anything else is undefined.
  pb.ParentRequest lookup(String name, {String? objectId}) {
    if (objectId != null) return _attribute(objects, objectId, name);
    if (!externals.containsKey(name)) {
      return pb.ParentRequest(
        resumeNameLookup: pb.ResumeNameLookup(undefined: pb.Unit()),
      );
    }
    final arena = pb.Arena(nodeCount: 1, nodes: [functionNode(name)]);

    return pb.ParentRequest(
      resumeNameLookup: pb.ResumeNameLookup(values: arena, value: 0),
    );
  }

  /// Answers the OS call [call]. With [parentSleeps] a system sleep is
  /// waited here, as `feedRun` waits it; without, it goes to the handler
  /// like any other call, as a resumed snapshot's does upstream.
  Future<pb.ParentRequest> osCall(
    pb.OsCall call, {
    required bool parentSleeps,
  }) async {
    final max = systemSleepMax;
    final slept = parentSleeps && max != null ? _systemSleep(call, max) : null;
    if (slept != null) return slept;
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

  /// Ends this feed's host side: every system sleep still waiting ends now,
  /// so no timer outlives the feed (upstream drops its pending tasks with
  /// the drive). A sleep the drive still awaits returns at once; one behind
  /// a pending future settles, unread.
  void dispose() {
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
      final answer = handler(name, args, kwargs);
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
    Future<Object> work,
  ) async {
    final outcome = _Outcome.of(work);
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

/// Answers a method call on the host object [call] names: refused for an
/// underscore name other than `__call__` before anything else, as
/// upstream refuses one; then dispatched to the registered wrapper. A
/// future result is a coroutine's.
Future<pb.ParentRequest> _methodCall(
  HostAnswers host,
  pb.FunctionCall call,
) async {
  final objects = host.objects;
  final FutureOr<Object> result;
  try {
    checkHostMethodName(call.functionName);
    final reader = ArenaReader(call.values, hosts: objects.lookup);
    result = objects.callMethod(
      uuidString(call.objectId.data),
      call.functionName,
      [for (final a in call.args) reader[a]],
      _kwargs(reader, call.kwargs),
    );
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
  const _Outcome.value(Object this.value) : error = null;

  const _Outcome.error(Object this.error) : value = null;

  final Object? value;
  final Object? error;

  ExternalAnswer get result {
    final v = value;

    return v == null
        ? ExternalAnswer.error(raisedFrom(error ?? const MontyNone()))
        : ExternalAnswer.value(v);
  }

  static Future<_Outcome> of(Future<Object> work) async {
    try {
      return _Outcome.value(await work);
    } on Object catch (error) {
      return _Outcome.error(error);
    }
  }
}

/// A settled answer as the wire carries it: a value or a raised exception.
final class ExternalAnswer {
  /// The call returned [value].
  const ExternalAnswer.value(Object this.value) : error = null;

  /// The call raised [error].
  const ExternalAnswer.error(pb.RaisedException this.error) : value = null;

  /// The value, when the call returned one: a [MontyValue] or a host
  /// object's wrapper.
  final Object? value;

  /// The exception, when the call raised one.
  final pb.RaisedException? error;
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
  final value = answer.value;
  if (value == null) {
    return pb.ExtFunctionResult(
      error: answer.error ?? pb.RaisedException(excType: 'RuntimeError'),
    );
  }
  if (strict) return pb.ExtFunctionResult(returnValue: writer.add(value));
  try {
    // A refused value leaves no nodes behind in the shared arena.
    return pb.ExtFunctionResult(returnValue: writer.tryAdd(value));
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
  FutureOr<Object> Function() body,
  HostObjects objects,
) async {
  try {
    return resumeValue(callId, await body(), objects: objects);
  } on Object catch (error) {
    return _resume(callId, pb.ExtFunctionResult(error: raisedFrom(error)));
  }
}

/// [invoke]'s result as a started future; a synchronous throw is its error.
Future<MontyValue> _started(FutureOr<MontyValue> Function() invoke) =>
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
/// `TypeError` ("Cannot convert pydantic_monty._NotHandledSentinel to Monty
/// value"), for `asyncio.sleep` too; [raisedFrom] raises this as that
/// `TypeError`.
final class AsyncDecline implements Exception {
  /// A decline from a future.
  const AsyncDecline();

  /// The `TypeError`'s message: upstream's, naming the Dart class.
  static const String message =
      'Cannot convert OsCallNotHandledException to Monty value: an OS '
      'handler declines only by throwing it synchronously';

  @override
  String toString() => 'AsyncDecline: $message';
}

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
  Object value, {
  HostObjects? objects,
}) {
  final writer = ArenaWriter(objects: objects);
  final index = writer.add(value);

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

/// The Python exception a throw from host code (a host function, an OS
/// handler or a coroutine) becomes.
///
/// - A value the writer refused as Python does ([PythonRefusal]) raises
///   Python's error, as upstream answers a conversion failure in an
///   automatic answer.
/// - An [ExternalException] raises its type, with its attributes sent as
///   upstream sends a live exception's. Its message is always sent, `''`
///   when it has none: upstream reads a raised exception's argument as
///   `str(exc)` when it has no single `str` one (`exception_arg`), so
///   `ValueError()` arrives as `ValueError('')`.
/// - An [ExternalException] whose type upstream does not know is the
///   [ArgumentError] a manual resume throws for it ([unknownExcType]), and
///   is raised as any other throw is.
/// - Any other throw raises `Exception` with its `toString()`: upstream
///   raises a host exception as its nearest built-in class, and a Dart
///   object has no Python class, so it takes the fallback a class of the
///   host's own takes.
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
