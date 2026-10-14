/// The scripted worker under `FakeMontySession`: a [MontyChannel] that
/// plays a [FakeScript] where a worker would run Python, and answers the
/// session's requests by the worker's rules (C4 worker-rules.md). The
/// session's own driver, writer, reader and error factory run unchanged
/// over it.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';

import 'package:dart_monty_core/src/fake_answers.dart';
import 'package:dart_monty_core/src/fake_script.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/encoded_length.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart'
    show acceptsFuture, osCallParts;
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_rules.dart' show pythonRepr;

/// How far a call the feed made has got.
sealed class _CallState {
  const _CallState();
}

/// Answered with a plain value, not a future.
final class _Plain extends _CallState {
  const _Plain(this.value, {required this.wrapped});

  /// Whether the worker wrapped the value in a settled future, as it wraps
  /// an `asyncio.sleep`'s (os-awaits.md), so Python may await it.
  final bool wrapped;

  final MontyValue value;
}

/// A host future not yet settled.
final class _Pending extends _CallState {
  const _Pending();
}

/// A host future settled with a value.
final class _Settled extends _CallState {
  const _Settled();
}

/// A call or host future that failed with [exception].
final class _Failed extends _CallState {
  const _Failed(this.exception);

  final pb.RaisedException exception;
}

/// A [MontyChannel] whose worker plays [FakeScript].
final class FakeWorker implements MontyChannel {
  /// A worker playing [_script].
  FakeWorker(this._script);

  /// The answers the session sent.
  final FakeAnswers log = FakeAnswers();

  /// The code of each feed the session sent.
  final List<String> feeds = [];

  final FakeScript _script;
  final Completer<void> _killed = Completer();
  bool _isAlive = true;

  /// How many feeds the worker has run since its last reset.
  int _feedCount = 0;

  /// The feed in play, or null between feeds.
  _Feed? _feed;

  @override
  bool get isAlive => _isAlive;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) async {
    if (!_isAlive) {
      throw crashedError(CrashCause.killed, detail: 'channel is dead');
    }
    // What the real channels refuse before sending a byte, refused here too.
    final length = EncodedLength.of(request);
    if (length > Frame.maxLength) {
      throw FrameTooLargeException(length, Frame.maxLength);
    }
    // Through the wire encoding, as a worker receives it.
    final sent = pb.ParentRequest.fromBuffer(request.writeToBuffer());
    // A real turn is asynchronous; so is this one.
    await Future<void>.delayed(Duration.zero);
    final event = await _reply(sent, onPrint);

    return pb.ChildEvent.fromBuffer(event.writeToBuffer());
  }

  @override
  Future<void> close() async {
    _isAlive = false;
  }

  @override
  void kill() {
    _isAlive = false;
    if (!_killed.isCompleted) _killed.complete();
  }

  Future<pb.ChildEvent> _reply(
    pb.ParentRequest request,
    PrintHandler? onPrint,
  ) async {
    final kind = request.whichKind();
    if (kind == pb.ParentRequest_Kind.configure) return _ok;
    if (kind == pb.ParentRequest_Kind.feed) return _start(request, onPrint);
    if (_answers.contains(kind)) {
      log.add(request);
      final feed = _feed;
      if (feed == null) throw _unexpected(kind);

      return _run(feed, feed.answer(request), onPrint);
    }

    return switch (kind) {
      pb.ParentRequest_Kind.reset => _reset(),
      pb.ParentRequest_Kind.abortFeed => _abort(request.abortFeed),
      _ => throw _refused(kind),
    };
  }

  /// A new session, as upstream's next checkout of the worker is.
  pb.ChildEvent _reset() {
    _feed = null;
    _feedCount = 0;

    return _ok;
  }

  /// The session's budget ends the feed with [abort]'s exception.
  pb.ChildEvent _abort(pb.AbortFeed abort) {
    _feed = null;

    return pb.ChildEvent(error: pb.Error(exception: abort.exception));
  }

  /// Starts the feed [request] on the next segment.
  Future<pb.ChildEvent> _start(
    pb.ParentRequest request,
    PrintHandler? onPrint,
  ) {
    final segment = _script.takeSegment();
    if (segment == null) {
      throw StateError(
        'FakeMontySession: no script for this feed; queue its events, '
        'ending with willReturn, willRaise or willCrash',
      );
    }
    log.add(request);
    // The worker names the N-th feed's source `<python-input-N>`.
    final feed = _feed = _Feed(segment, _feedCount++, _killed);
    feeds.add(request.feed.code);

    return _run(feed, null, onPrint);
  }

  /// [next], or what [feed] plays to when the answer let it run on.
  Future<pb.ChildEvent> _run(
    _Feed feed,
    pb.ChildEvent? next,
    PrintHandler? onPrint,
  ) async {
    try {
      final event = next ?? await feed.play(onPrint);
      if (feed.isOver) _feed = null;

      return event;
    } on MontyCrashedError {
      _feed = null;
      _isAlive = false;
      rethrow;
    } on Object {
      _feed = null;
      rethrow;
    }
  }
}

/// One feed in play: its remaining events, what it is suspended on, and its
/// calls.
final class _Feed {
  _Feed(List<FakeEvent> segment, this._index, this._killed)
    : _events = Queue.of(segment);

  /// Whether the feed has ended.
  bool isOver = false;

  final Queue<FakeEvent> _events;
  final int _index;
  final Completer<void> _killed;

  /// The feed's calls, by id.
  final Map<int, _CallState> _calls = {};

  /// What the feed is suspended on: a call, a lookup or an await.
  FakeEvent? _at;

  /// The ids an await is still waiting on.
  Set<int> _awaited = {};

  /// The ids the last wait listed.
  List<int> _advertised = const [];

  /// Ids a gather still waits on after a partial settlement let the script
  /// run on.
  final Set<int> _outstanding = {};

  /// Plays the events up to the next suspension or the end.
  Future<pb.ChildEvent> play(PrintHandler? onPrint) async {
    for (;;) {
      final event = _events.removeFirst();
      switch (event) {
        case FakePrint():
          await onPrint?.call(_printOf(event));
        case FakeHold(:final gate):
          await _hold(gate);
        case _:
          if (_suspend(event) case final next?) return next;
      }
    }
  }

  /// Takes the host's answer [request] to the current suspension: the
  /// event it leads to, or null when the feed runs on.
  pb.ChildEvent? answer(pb.ParentRequest request) {
    final at = _at;
    _at = null;
    final kind = request.whichKind();

    return switch ((kind, at)) {
      (pb.ParentRequest_Kind.resumeCall, final FakeCall call) => _answerCall(
        call,
        request.resumeCall,
      ),
      (pb.ParentRequest_Kind.resumeNameLookup, FakeLookup(:final name)) =>
        switch (request.resumeNameLookup.whichKind()) {
          pb.ResumeNameLookup_Kind.value => null,
          pb.ResumeNameLookup_Kind.error => _raise(
            request.resumeNameLookup.error,
          ),
          _ => _raise(_nameError(name)),
        },
      // An eager call answered by a coroutine: its result, at once.
      (pb.ParentRequest_Kind.resumeFutures, FakeCall(:final callId)) =>
        _raiseFirstFailure(
          _settleBatch(request.resumeFutures).where((id) => id == callId),
        ),
      (pb.ParentRequest_Kind.resumeFutures, final FakeAwait wait) =>
        _settleWait(wait, request.resumeFutures),
      _ => throw _unexpected(kind),
    };
  }

  /// Plays [event], one that suspends or ends the feed: the event the
  /// worker sends, or null when the script runs on.
  pb.ChildEvent? _suspend(FakeEvent event) {
    switch (event) {
      case FakeCall(:final callId):
        _calls[callId] = const _Pending();
        _at = event;

        return event.event;
      case FakeLookup(:final name):
        _at = event;

        return pb.ChildEvent(nameLookup: pb.NameLookup(name: name));
      case FakeAwait():
        return _await(event);
      case FakeEnd():
        return _end(event);
      case FakeCatch() || FakePrint() || FakeHold():
        throw StateError(
          'FakeMontySession: willCatch() follows no answer that raised',
        );
    }
  }

  /// Ends the feed with [end], or first waits for what a gather still
  /// owes: the worker cannot end the feed while it is blocked on them.
  /// Null when the owed ids settled already and the script runs on.
  pb.ChildEvent? _end(FakeEnd end) {
    // Only a return needs the gather done: a raise or a dead worker ends
    // the feed whatever it still waits on.
    if (_outstanding.isEmpty || end is! FakeReturn) {
      isOver = true;

      return _ending(end, _index);
    }
    _events.addFirst(end);
    final owed = FakeAwait(_outstanding.toList()..sort(), gathered: true);
    _outstanding.clear();

    return _await(owed);
  }

  /// Keeps the protocol turn in flight until [gate] opens; a kill
  /// meanwhile ends it as a dead worker's.
  Future<void> _hold(Future<void> gate) async {
    await Future.any([gate, _killed.future]);
    if (_killed.isCompleted) {
      throw crashedError(CrashCause.killed, detail: 'killed mid-turn');
    }
  }

  /// Plays [wait]: futures already settled are observed in place (observe.md),
  /// a plain value raises `TypeError` (awaitable.md), and the rest are
  /// waited on. Null when the script runs on.
  pb.ChildEvent? _await(FakeAwait wait) {
    // A gather checks every argument is awaitable before it awaits any.
    if (wait.gathered) {
      if (_firstPlain(_calls, wait.callIds) case final value?) {
        return _raise(_notAwaitable(value, gathered: true));
      }
    }
    final pending = <int>{};
    for (final id in wait.callIds) {
      switch (_calls[id]) {
        // Settled, or an OS call's value, which upstream wraps itself.
        case _Settled() || _Plain(wrapped: true):
          break;
        case _Plain(:final value):
          return _raise(_notAwaitable(value, gathered: wait.gathered));
        case _Failed(:final exception):
          return _raise(exception);
        case _Pending():
          pending.add(id);
        case null:
          throw StateError(
            'FakeMontySession: willAwait names call $id, which the feed '
            'has not made',
          );
      }
    }
    if (pending.isEmpty) return null;
    _at = wait;
    _awaited = pending;

    return _resolveFutures();
  }

  /// The worker's wait: every host future still pending, whatever Python
  /// awaits (upstream's scheduler lists all of them, in hash order; the
  /// fake lists them ascending).
  pb.ChildEvent _resolveFutures() {
    final pending = _advertised = [
      for (final MapEntry(:key, :value) in _calls.entries)
        if (value is _Pending) key,
    ]..sort();

    return pb.ChildEvent(
      resolveFutures: pb.ResolveFutures(pendingCallIds: pending),
    );
  }

  /// Settles the batch [futures] while Python awaits [wait].
  ///
  /// A batch naming an id the wait did not list ends the feed, as the
  /// worker refuses it. One that settles nothing Python awaits repeats the
  /// wait (rewait.md). A partial one runs the script on when its next event
  /// past any prints is one an unblocked branch can make (a call, a lookup,
  /// a hold); before an await or the end the worker is still blocked on
  /// the rest, and waits again for them (waits.md). Ids it ran on without
  /// stay owed, and are waited for before the feed ends.
  pb.ChildEvent? _settleWait(
    FakeAwait wait,
    pb.ResumeFutures futures,
  ) {
    if (_unknownId(_advertised, futures) case final refused?) {
      isOver = true;

      return _uncatchable(refused);
    }
    final settled = _settleBatch(futures);
    final awaited = _awaited;
    final remaining = awaited.difference(settled);
    // The batch's first failure Python awaits or a gather owes raises now.
    final owed = {..._outstanding};
    final watched = {...awaited, ...owed};
    _outstanding.removeAll(settled);
    final failed = futures.results
        .map((r) => r.callId)
        .where(watched.contains)
        .firstWhereOrNull((id) => _calls[id] is _Failed);
    if (failed != null) {
      // A failed gather member cancels what the gather owes; a branch's not.
      if (wait.gathered || owed.contains(failed)) _outstanding.clear();

      return _raiseFirstFailure([failed]);
    }
    final runsOn =
        remaining.length < awaited.length &&
        (remaining.isEmpty ||
            _isBranchEvent(_events.firstWhereOrNull((e) => e is! FakePrint)));
    if (runsOn) {
      // The rest stay owed: the feed cannot end before they settle.
      _outstanding.addAll(remaining);

      return null;
    }
    _at = wait;
    _awaited = remaining;

    return _resolveFutures();
  }

  pb.ChildEvent? _answerCall(FakeCall call, pb.ResumeCall resume) {
    final id = call.callId;
    final result = resume.result;
    switch (result.whichKind()) {
      case pb.ExtFunctionResult_Kind.returnValue:
        return _answerValue(
          call,
          ArenaReader(resume.values)[result.returnValue],
        );
      case pb.ExtFunctionResult_Kind.future:
        _calls[id] = const _Pending();
        if (!call.eager) return null;
        // Awaited at once: the worker waits on it now.
        _at = FakeAwait([id], gathered: false);
        _awaited = {id};

        return _resolveFutures();
      case pb.ExtFunctionResult_Kind.error:
      case pb.ExtFunctionResult_Kind.notFound:
      case pb.ExtFunctionResult_Kind.notHandled:
      case pb.ExtFunctionResult_Kind.notSet:
        final error = _callError(call, result);
        _calls[id] = _Failed(error);

        return _raise(error);
    }
  }

  pb.ChildEvent? _answerValue(FakeCall call, MontyValue value) {
    final id = call.callId;
    final wrapped = call.os && acceptsFuture(call.name);
    _calls[id] = _Plain(value, wrapped: wrapped);
    if (wrapped) _shiftAfter(id);
    // Python awaits an eager call at once; an OS call takes a plain value
    // (os-awaits.md).
    if (call.eager && !call.os) {
      return _raise(_notAwaitable(value, gathered: false));
    }

    return null;
  }

  /// The worker gives an `asyncio.sleep` answered with a plain value a
  /// second call id, for the settled future it wraps the value in
  /// (upstream `settled_awaitable`): the calls after [id] each take the
  /// next id, and the awaits naming them follow.
  void _shiftAfter(int id) {
    final rest = [
      for (final e in _events)
        switch (e) {
          FakeCall(:final callId) when callId > id => e.shifted(),
          FakeAwait() => e.shiftedAfter(id),
          _ => e,
        },
    ];
    _events
      ..clear()
      ..addAll(rest);
  }

  /// Records each result of [futures] against its call; the ids settled.
  Set<int> _settleBatch(pb.ResumeFutures futures) {
    final settled = <int>{};
    for (final result in futures.results) {
      final id = result.callId;
      final answer = result.result;
      _calls[id] = answer.whichKind() == pb.ExtFunctionResult_Kind.error
          ? _Failed(answer.error)
          : const _Settled();
      settled.add(id);
    }

    return settled;
  }

  pb.ChildEvent? _raiseFirstFailure(Iterable<int> ids) {
    for (final id in ids) {
      if (_calls[id] case _Failed(:final exception)) return _raise(exception);
    }

    return null;
  }

  /// Raises [exception] in the sandbox: the feed ends with it, unless the
  /// next event is `willCatch()` (failures.md). Null when caught.
  pb.ChildEvent? _raise(pb.RaisedException exception) {
    if (_events.firstOrNull is FakeCatch) {
      _events.removeFirst();

      return null;
    }
    isOver = true;

    return _uncatchable(exception);
  }
}

/// The worker's refusal of a batch [futures] naming an id its wait did not
/// list as [advertised]; null when every id was listed.
pb.RaisedException? _unknownId(
  List<int> advertised,
  pb.ResumeFutures futures,
) {
  final unknown = futures.results.firstWhereOrNull(
    (r) => !advertised.contains(r.callId),
  );
  if (unknown == null) return null;

  return pb.RaisedException(
    excType: 'RuntimeError',
    message: 'unknown call_id ${unknown.callId}, expected one of: $advertised',
  );
}

/// The first of [ids] answered with a plain value Python cannot await.
MontyValue? _firstPlain(Map<int, _CallState> calls, List<int> ids) {
  for (final id in ids) {
    if (calls[id] case _Plain(wrapped: false, :final value)) return value;
  }

  return null;
}

/// The `Error` event ending a feed with [exception], without its traceback.
pb.ChildEvent _uncatchable(pb.RaisedException exception) => pb.ChildEvent(
  error: pb.Error(
    exception: pb.RaisedException(
      excType: exception.excType,
      message: exception.hasMessage() ? exception.message : null,
      data: exception.hasData() ? exception.data : null,
    ),
  ),
);

/// Whether [event], the next one past any prints, is one a branch a
/// settlement unblocked can make: a call, a lookup or a hold. An await or
/// the end means the gather has not returned yet.
bool _isBranchEvent(FakeEvent? event) =>
    event is FakeCall || event is FakeLookup || event is FakeHold;

/// The requests that answer a suspension.
const Set<pb.ParentRequest_Kind> _answers = {
  pb.ParentRequest_Kind.resumeCall,
  pb.ParentRequest_Kind.resumeNameLookup,
  pb.ParentRequest_Kind.resumeFutures,
};

/// The error for a request the fake does not take.
Error _refused(pb.ParentRequest_Kind kind) => switch (kind) {
  pb.ParentRequest_Kind.dump || pb.ParentRequest_Kind.load => UnsupportedError(
    'FakeMontySession has no dump or load; test them against a real session',
  ),
  _ => _unexpected(kind),
};

StateError _unexpected(pb.ParentRequest_Kind kind) => StateError(
  'FakeMontySession: ${kind.name} answers no scripted suspension',
);

/// The worker's `Print` for [print].
pb.Print _printOf(FakePrint print) => pb.Print(
  segments: [
    pb.PrintSegment(
      stream: print.stream == 'stderr'
          ? pb.PrintStream.PRINT_STREAM_STDERR
          : pb.PrintStream.PRINT_STREAM_STDOUT,
      text: print.text,
    ),
  ],
);

/// The event [end] sends, in the [index]-th feed; a crash throws.
pb.ChildEvent _ending(FakeEnd end, int index) {
  switch (end) {
    case FakeReturn(:final value):
      final writer = ArenaWriter();
      final root = writer.add(value);

      return pb.ChildEvent(
        complete: pb.Complete(value: root, values: writer.arena),
      );
    case FakeRaise(:final exception, :final line, :final column):
      final raised = exception.deepCopy();
      if (line != null) {
        final at = pb.CodeLoc(line: line, column: column ?? 1);
        raised.traceback.add(
          pb.StackFrame(
            filename: '<python-input-$index>',
            start: at,
            end: at,
            frameName: '<module>',
          ),
        );
      }

      return pb.ChildEvent(error: pb.Error(exception: raised));
    case FakeCrash(:final timedOut):
      throw crashedError(
        timedOut ? CrashCause.killed : CrashCause.vanished,
        detail: 'the scripted worker died',
        timedOut: timedOut,
      );
  }
}

/// The exception a call answered with [result] raises in the sandbox.
pb.RaisedException _callError(FakeCall call, pb.ExtFunctionResult result) =>
    switch (result.whichKind()) {
      pb.ExtFunctionResult_Kind.error => result.error,
      pb.ExtFunctionResult_Kind.notFound => _nameError(result.notFound),
      _ => _notHandled(call),
    };

final pb.ChildEvent _ok = pb.ChildEvent(ok: pb.Ok());

/// Upstream's `NameError` for the undefined [name].
pb.RaisedException _nameError(String name) => pb.RaisedException(
  excType: 'NameError',
  message: "name '$name' is not defined",
);

/// Upstream's default for an OS call no handler took: `PermissionError`
/// naming the path for a filesystem call, `RuntimeError` for the rest.
pb.RaisedException _notHandled(FakeCall call) {
  // Only an OS call can be declined: the session refuses the rest.
  final (name, args, _) = osCallParts(call.event.osCall);
  if (args.firstOrNull case MontyPath(:final value) when _isFilesystem(name)) {
    return pb.RaisedException(
      excType: 'PermissionError',
      message: 'Permission denied: ${pythonRepr(value)}',
    );
  }

  return pb.RaisedException(
    excType: 'RuntimeError',
    message: "'$name' is not supported in this environment",
  );
}

bool _isFilesystem(String name) => name.startsWith('Path.') || name == 'open';

/// The `TypeError` Python raises awaiting the plain [value]
/// (await-messages.md).
pb.RaisedException _notAwaitable(
  MontyValue value, {
  required bool gathered,
}) => pb.RaisedException(
  excType: 'TypeError',
  message: gathered
      ? 'An asyncio.Future, a coroutine or an awaitable is required'
      : "'${pythonTypeName(value)}' object can't be awaited",
);

/// The Python type name of [value], as a `TypeError` names it.
String pythonTypeName(MontyValue value) =>
    _typeNames[value.runtimeType] ?? 'object';

const Map<Type, String> _typeNames = {
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
  MontyPath: 'PosixPath',
  MontyDate: 'date',
  MontyDateTime: 'datetime',
  MontyTime: 'time',
  MontyTimeDelta: 'timedelta',
  MontyTimeZone: 'timezone',
  MontyEllipsis: 'ellipsis',
};
