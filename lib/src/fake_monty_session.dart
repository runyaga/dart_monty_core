/// A scriptable session for testing host code without a worker (C4 API3).
///
/// Internal until the cutover, when `dart_monty_core_testing.dart` exports
/// [FakeMontySession] as its only name; until then it takes host functions
/// in the session's internal map (C4 pre-cutover.md).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/src/fake_answers.dart';
import 'package:dart_monty_core/src/fake_script.dart';
import 'package:dart_monty_core/src/fake_worker.dart';
import 'package:dart_monty_core/src/mount/mount_dir.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart'
    show exceptionTypeNames;
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_session.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';

/// The scripting half of [FakeMontySession]: the `will*` events and the
/// record of what the session ran and answered.
abstract class _FakeScripting {
  const _FakeScripting._(FakeScript script, FakeWorker worker)
    : _script = script,
      _worker = worker;

  final FakeScript _script;
  final FakeWorker _worker;

  /// Scripts a call to the host function [name] with [args] and [kwargs]
  /// (Python calling a name the sandbox does not define). [eager] when
  /// Python awaits the call at once with nothing else to run. Returns the
  /// call's id, for [willAwait].
  ///
  /// Throws [ArgumentError] for a value a worker could not send.
  int willCall(
    String name, {
    List<MontyValue> args = const [],
    Map<String, MontyValue> kwargs = const {},
    bool eager = false,
  }) {
    final id = _script.nextCallId;
    final writer = ArenaWriter();
    final call = pb.FunctionCall(
      functionName: name,
      args: [for (final a in args) scriptedValue(writer, a)],
      kwargs: [
        for (final MapEntry(:key, :value) in kwargs.entries)
          pb.NodePair(
            key: writer.add(MontyString(key)),
            value: scriptedValue(writer, value),
          ),
      ],
      callId: id,
      allowEagerAwait: eager,
    )..values = writer.arena;
    _script.add(
      FakeCall(name, id, pb.ChildEvent(functionCall: call), eager: eager),
    );

    return id;
  }

  /// Scripts the OS call [name] (`Path.read_text`, `os.getenv`, ...), with
  /// [args] and [kwargs] as the session receives them (`os.getenv('A')` is
  /// `('A', None)`). Returns the call's id.
  ///
  /// Throws [ArgumentError] for a name or arguments a worker could not
  /// send.
  int willCallOs(
    String name, {
    List<MontyValue> args = const [],
    Map<String, MontyValue> kwargs = const {},
    bool eager = false,
  }) {
    final id = _script.nextCallId;
    final call = _osCall(name, args, kwargs)
      ..callId = id
      ..allowEagerAwait = eager;
    _script.add(FakeCall(name, id, pb.ChildEvent(osCall: call), eager: eager));

    return id;
  }

  /// Scripts a bare reference to [name], undefined in the sandbox.
  void willLookUp(String name) => _script.add(FakeLookup(name));

  /// Scripts Python awaiting the host futures [callIds], ids this feed's
  /// calls returned; [gathered] for an `asyncio.gather`. Futures already
  /// settled are awaited in place; the session waits for the rest.
  ///
  /// Throws [ArgumentError] for an id the segment has not scripted.
  void willAwait(List<int> callIds, {bool gathered = false}) {
    if (callIds.isEmpty) {
      throw ArgumentError.value(callIds, 'callIds', 'awaits nothing');
    }
    final known = _script.openCallIds;
    for (final id in callIds) {
      if (!known.contains(id)) {
        throw ArgumentError.value(id, 'callIds', 'no such call in this feed');
      }
    }
    _script.add(FakeAwait(List.unmodifiable(callIds), gathered: gathered));
  }

  /// Scripts [text] printed to [stream], `stdout` or `stderr`.
  void willPrint(String text, {String stream = 'stdout'}) {
    if (stream != 'stdout' && stream != 'stderr') {
      throw ArgumentError.value(stream, 'stream', 'not stdout or stderr');
    }
    _script.add(FakePrint(text, stream));
  }

  /// Scripts the feed's end with [value].
  ///
  /// Throws [ArgumentError] for a value a worker could not send.
  void willReturn(MontyValue value) {
    ArenaWriter().add(value);
    _script.add(FakeReturn(value));
  }

  /// Scripts the feed's end with an uncaught [excType], with [message] and
  /// [attributes]. With [line], the error has one traceback frame at
  /// [line] and [column] (1 by default), named as the worker names the
  /// feed's source.
  ///
  /// Throws [ArgumentError] for a type that is not upstream's, or for an
  /// attribute value a worker could not send.
  void willRaise(
    String excType, {
    String? message,
    Map<String, MontyValue> attributes = const {},
    int? line,
    int? column,
  }) {
    if (!exceptionTypeNames.contains(excType)) throw unknownExcType(excType);
    attributes.values.forEach(ArenaWriter().add);
    _script.add(
      FakeRaise(
        _sandboxException(excType, message, attributes),
        line: line,
        column: column,
      ),
    );
  }

  /// Scripts Python catching the exception the answer to the event before
  /// raised; the script then runs on.
  ///
  /// Throws [StateError] unless the event before is a call, a lookup or an
  /// await.
  void willCatch() {
    if (_script.lastOpen is! FakeCall &&
        _script.lastOpen is! FakeLookup &&
        _script.lastOpen is! FakeAwait) {
      throw StateError('willCatch() must follow a call, a lookup or an await');
    }
    _script.add(const FakeCatch());
  }

  /// Scripts a protocol turn kept in flight until [gate] completes: `close`
  /// meanwhile kills the turn, and other calls queue.
  void willHold(Future<void> gate) => _script.add(FakeHold(gate));

  /// Scripts the worker dying: the feed throws `MontyCrashedError` and the
  /// session is finished.
  void willCrash({bool timedOut = false}) =>
      _script.add(FakeCrash(timedOut: timedOut));

  /// The code of each feed the session ran, in order.
  List<String> get feeds => List.unmodifiable(_worker.feeds);

  /// The host's answers, one per suspension, in order: each with its call
  /// id (none for a name lookup), the number of the futures batch it went
  /// out in (only for a settled future) and the answer, null where the
  /// host answered `not_found`, `not_handled` or an undefined name.
  List<FakeAnswer> get answers => List.unmodifiable(_worker.log.answers);
}

/// The session's lifecycle over the scripted worker: opened on the first
/// call, closed once.
class _ScriptedLink {
  _ScriptedLink(this._worker);

  /// Whether [close] has run.
  bool isClosed = false;

  final FakeWorker _worker;
  Future<MontySession>? _opening;
  MontySession? _session;
  Monty? _pool;
  Future<void>? _closing;

  Future<void> close() => _closing ??= _close();

  /// Runs [body] on the session over the scripted worker: at once when it
  /// is open, so calls keep their order and timing.
  Future<T> call<T>(Future<T> Function(MontySession session) body) {
    // Refused at once, as a closed session refuses, while the close is
    // still on its way to the session underneath.
    if (isClosed) return Future.error(StateError('the session is finished'));
    final session = _session;
    if (session != null) return body(session);

    return _opened(body);
  }

  Future<void> _close() async {
    isClosed = true;
    final opening = _opening;
    try {
      // The session's close takes its usual path: Reset when idle, a kill
      // with a turn in flight.
      final session = _session;
      if (session != null) {
        await session.close();
      } else if (opening != null) {
        await (await opening).close();
      }
    } finally {
      await _pool?.close();
      await _worker.close();
    }
  }

  Future<T> _opened<T>(Future<T> Function(MontySession session) body) async =>
      body(await (_opening ??= _open()));

  Future<MontySession> _open() async {
    final pool = _pool = await startMonty(
      const PoolOptions(minProcesses: 0, maxProcesses: 1),
      open: () => PendingSpawn((_) async => _worker),
    );

    return _session = await pool.checkout();
  }
}

/// A session that plays a script where a worker would run Python.
///
/// A test queues, in order, what each feed's Python does: the host calls,
/// OS calls, name lookups and awaits it suspends on, its prints, and how it
/// ends. The session answers each suspension exactly as a worker-backed
/// session does, through the same driver: a call through `externalLookup`,
/// an OS call through `os`, a lookup from `externalLookup`, an await from
/// the host futures it started. Under `feedStart` each suspension is
/// returned as a snapshot to resume by hand.
///
/// An answer that raises in the sandbox (a host function's exception, a
/// name not in `externalLookup`, a declined OS call, a refused value, a failed
/// future Python awaits) ends the feed with that error, as uncaught Python
/// would, unless the next scripted event is [willCatch]. The rest of that
/// feed's events are dropped.
///
/// Each feed plays its own segment of the queue: the events up to and
/// including the next [willReturn], [willRaise] or [willCrash]. A feed
/// that finds no complete segment throws [StateError]. Call ids count from
/// 0 within a segment, as a worker numbers them within a feed.
///
/// What it does not do: run Python, type-check, enforce limits, or keep a
/// working directory (`cwd` is checked as a session checks it, and no
/// Python reads it). [installDependencies] answers as the pure-Monty worker
/// does: an empty list succeeds, any other is refused. [dump],
/// [loadSession], [loadSnapshot] and a snapshot's `dump` throw
/// [UnsupportedError]. [workerPid] is null.
final class FakeMontySession extends _FakeScripting implements MontySession {
  /// A session with nothing scripted.
  FakeMontySession() : this._(FakeScript());

  FakeMontySession._(FakeScript script)
    : this._over(script, FakeWorker(script));

  FakeMontySession._over(super.script, super.worker)
    : _link = _ScriptedLink(worker),
      super._();

  final _ScriptedLink _link;

  /// Whether [close] has run.
  bool get isClosed => _link.isClosed;

  @override
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    List<MountDir>? mount,
    String? cwd,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) => _link.call(
    (s) => s.feedRun(
      code,
      inputs: inputs,
      externalLookup: externalLookup,
      printCallback: printCallback,
      mount: mount,
      cwd: cwd,
      os: os,
      skipTypeCheck: skipTypeCheck,
    ),
  );

  @override
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    List<MountDir>? mount,
    String? cwd,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) => _link.call(
    (s) => s.feedStart(
      code,
      inputs: inputs,
      externalLookup: externalLookup,
      printCallback: printCallback,
      mount: mount,
      cwd: cwd,
      os: os,
      skipTypeCheck: skipTypeCheck,
    ),
  );

  @override
  Future<void> installDependencies(List<String> requirements) =>
      Future.sync(() {
        // Read and checked when called, as the session does, not when the
        // fake's session opens.
        final taken = [...requirements];
        checkRequirementsText(taken);

        return _link.call((s) => s.installDependencies(taken));
      });

  @override
  Future<void> loadSession(Uint8List state) async => throw _noDump;

  @override
  Future<MontySnapshot> loadSnapshot(
    Uint8List state, {
    List<MountDir>? mount,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    OsHandler? os,
  }) async => throw _noDump;

  @override
  Future<Uint8List> dump() async => throw _noDump;

  @override
  int? get workerPid => null;

  @override
  Future<void> close() => _link.close();
}

/// The exception the worker sends for a sandbox-raised [excType]: the
/// host-answer form, plus a Unicode error's payload from [attributes]
/// (`encoding`, `object`, `start`, `end`, `reason`), which only the worker
/// sends.
pb.RaisedException _sandboxException(
  String excType,
  String? message,
  Map<String, MontyValue> attributes,
) {
  final raised = raisedException(excType, message, attributes);
  if (_unicodeData(attributes) case final data?
      when excType.startsWith(
        'Unicode',
      )) {
    raised.data = pb.ExcData(unicode: data);
  }

  return raised;
}

pb.UnicodeErrorData? _unicodeData(Map<String, MontyValue> attributes) {
  if (attributes case {
    'encoding': MontyString(value: final encoding),
    'start': MontyInt(value: final start),
    'end': MontyInt(value: final end),
    'reason': MontyString(value: final reason),
  } when start >= 0 && end >= 0) {
    final data = pb.UnicodeErrorData(
      encoding: encoding,
      start: Int64(start),
      end: Int64(end),
      reason: reason,
    );
    switch (attributes['object']) {
      case MontyBytes(:final value):
        data.objectBytes = value;
      case MontyString(:final value):
        data.objectStr = value;
      default:
        return null;
    }

    return data;
  }

  return null;
}

final UnsupportedError _noDump = UnsupportedError(
  'FakeMontySession has no dump or load; test them against a real session',
);

/// The worker's `OsCall` for [name] with [args] and [kwargs], as the
/// session decodes it (`osCallParts`).
pb.OsCall _osCall(
  String name,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) {
  final build = _osCalls[name];
  if (build == null) throw _OsArgs(name, args, kwargs).bad();

  return build(_OsArgs(name, args, kwargs));
}

/// A scripted OS call's arguments, read as the worker's fields.
final class _OsArgs {
  const _OsArgs(this.name, this.args, this.kwargs);

  final String name;
  final List<MontyValue> args;
  final Map<String, MontyValue> kwargs;

  ArgumentError bad() => ArgumentError.value(
    '$name$args$kwargs',
    'name',
    'not an OS call a worker sends',
  );

  String path([int i = 0]) => switch (args.elementAtOrNull(i)) {
    MontyPath(:final value) || MontyString(:final value) => value,
    _ => throw bad(),
  };

  String str(int i) => switch (args.elementAtOrNull(i)) {
    MontyString(:final value) => value,
    _ => throw bad(),
  };

  double float() => switch (args.firstOrNull) {
    MontyFloat(:final value) => value,
    MontyInt(:final value) => value.toDouble(),
    _ => throw bad(),
  };

  Int64 size() => switch (args.firstOrNull) {
    MontyInt(:final value) when value >= 0 => Int64(value),
    _ => throw bad(),
  };

  bool flag(String key) => switch (kwargs[key]) {
    MontyBool(:final value) => value,
    null => false,
    _ => throw bad(),
  };

  List<int> bytes() => switch (args.elementAtOrNull(1)) {
    MontyBytes(:final value) => value,
    _ => throw bad(),
  };

  pb.OsCall_TextWrite text() => pb.OsCall_TextWrite(path: path(), data: str(1));

  pb.OsCall_BytesWrite data() =>
      pb.OsCall_BytesWrite(path: path(), data: bytes());

  pb.OsCall getenv() {
    final writer = ArenaWriter();
    final fallback = args.elementAtOrNull(1) ?? const MontyNone();

    return pb.OsCall(
      getenv: pb.OsCall_Getenv(
        key: str(0),
        default_2: scriptedValue(writer, fallback),
      ),
      values: writer.arena,
    );
  }

  pb.OsCall_DateTimeNow now() => switch (args.firstOrNull) {
    MontyTimeZone(:final offsetSeconds, name: final zone) =>
      pb.OsCall_DateTimeNow(
        tz: pb.TimeZone(offsetSeconds: offsetSeconds, name: zone),
      ),
    MontyNone() || null => pb.OsCall_DateTimeNow(),
    _ => throw bad(),
  };
}

/// The worker's fields for each OS function name (`osCallParts` read
/// backwards).
final Map<String, pb.OsCall Function(_OsArgs a)> _osCalls = {
  'Path.exists': (a) => pb.OsCall(exists: a.path()),
  'Path.is_file': (a) => pb.OsCall(isFile: a.path()),
  'Path.is_dir': (a) => pb.OsCall(isDir: a.path()),
  'Path.is_symlink': (a) => pb.OsCall(isSymlink: a.path()),
  'Path.read_text': (a) => pb.OsCall(readText: a.path()),
  'Path.read_bytes': (a) => pb.OsCall(readBytes: a.path()),
  'Path.stat': (a) => pb.OsCall(stat: a.path()),
  'Path.iterdir': (a) => pb.OsCall(iterdir: a.path()),
  'Path.resolve': (a) => pb.OsCall(resolve: a.path()),
  'Path.absolute': (a) => pb.OsCall(absolute: a.path()),
  'Path.unlink': (a) => pb.OsCall(unlink: a.path()),
  'Path.rmdir': (a) => pb.OsCall(rmdir: a.path()),
  'Path.write_text': (a) => pb.OsCall(writeText: a.text()),
  'Path.append_text': (a) => pb.OsCall(appendText: a.text()),
  'Path.write_bytes': (a) => pb.OsCall(writeBytes: a.data()),
  'Path.append_bytes': (a) => pb.OsCall(appendBytes: a.data()),
  'open': (a) => pb.OsCall(
    open: pb.OsCall_Open(path: a.path(), mode: a.str(1)),
  ),
  'Path.mkdir': (a) => pb.OsCall(
    mkdir: pb.OsCall_Mkdir(
      path: a.path(),
      parents: a.flag('parents'),
      existOk: a.flag('exist_ok'),
    ),
  ),
  'Path.rename': (a) => pb.OsCall(
    rename: pb.OsCall_Rename(src: a.path(), dst: a.path(1)),
  ),
  'os.getenv': (a) => a.getenv(),
  'os.environ': (_) => pb.OsCall(getEnviron: pb.Unit()),
  'date.today': (_) => pb.OsCall(dateToday: pb.Unit()),
  'datetime.now': (a) => pb.OsCall(dateTimeNow: a.now()),
  'os.urandom': (a) => pb.OsCall(
    urandom: pb.OsCall_Urandom(size: a.size()),
  ),
  'time.time': (a) => pb.OsCall(time: pb.OsCall_TimeCall(caller: a.str(0))),
  'time.sleep': (a) => pb.OsCall(sleep: pb.OsCall_Sleep(seconds: a.float())),
  'system.sleep': (a) => pb.OsCall(
    systemSleep: pb.OsCall_Sleep(seconds: a.float()),
  ),
  'asyncio.sleep': (a) => pb.OsCall(
    asyncSleep: pb.OsCall_AsyncSleep(delay: a.float()),
  ),
  'system.async_sleep': (a) => pb.OsCall(
    asyncSystemSleep: pb.OsCall_AsyncSleep(delay: a.float()),
  ),
};
