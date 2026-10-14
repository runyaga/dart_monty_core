/// What a `FakeMontySession` test queues: the events one feed's Python
/// produces, grouped into one segment per feed.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:collection';

import 'package:collection/collection.dart';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

/// The queued events, as segments: one per feed, each ending with a
/// [FakeEnd] (call-ids.md).
final class FakeScript {
  final Queue<List<FakeEvent>> _segments = Queue();
  List<FakeEvent> _open = [];
  int _nextCallId = 0;

  /// Queues [event].
  void add(FakeEvent event) {
    _open.add(event);
    if (event is FakeCall) _nextCallId++;
    if (event is FakeEnd) {
      _segments.add(_open);
      _open = [];
      _nextCallId = 0;
    }
  }

  /// The id the next call queued in the open segment takes.
  int get nextCallId => _nextCallId;

  /// The ids of the open segment's calls so far.
  Set<int> get openCallIds => {
    for (final e in _open)
      if (e is FakeCall) e.callId,
  };

  /// The open segment's last event, or null.
  FakeEvent? get lastOpen => _open.lastOrNull;

  /// The next complete segment, removed; null when none is queued.
  List<FakeEvent>? takeSegment() =>
      _segments.isEmpty ? null : _segments.removeFirst();
}

/// One scripted event: what the worker does next.
sealed class FakeEvent {
  const FakeEvent();
}

/// A call to a host function, or an OS call when [os] is set: the worker's
/// `FunctionCall` or `OsCall`.
final class FakeCall extends FakeEvent {
  /// The call [callId] to [name].
  const FakeCall(this.name, this.callId, this.event, {required this.eager});

  /// The function or OS function name.
  final String name;

  /// The call's id, counted from 0 within the feed.
  final int callId;

  /// Whether Python awaits the call at once (`allow_eager_await`).
  final bool eager;

  /// The event the worker sends for it.
  final pb.ChildEvent event;

  /// Whether this is an OS call.
  bool get os => event.whichKind() == pb.ChildEvent_Kind.osCall;

  /// This call with the next id: a call after one the worker gave a second
  /// id.
  FakeCall shifted() {
    final next = event.deepCopy();
    if (os) {
      next.osCall.callId = callId + 1;
    } else {
      next.functionCall.callId = callId + 1;
    }

    return FakeCall(name, callId + 1, next, eager: eager);
  }
}

/// A bare reference to the undefined name [name]: the worker's
/// `NameLookup`.
final class FakeLookup extends FakeEvent {
  /// A lookup of [name].
  const FakeLookup(this.name);

  /// The name looked up.
  final String name;
}

/// Python awaiting the host futures [callIds]; [gathered] when it awaits
/// them through `asyncio.gather`.
final class FakeAwait extends FakeEvent {
  /// An await on [callIds].
  const FakeAwait(this.callIds, {required this.gathered});

  /// The call ids awaited.
  final List<int> callIds;

  /// Whether the await is a gather.
  final bool gathered;

  /// This await with each id above [id] one higher.
  FakeAwait shiftedAfter(int id) => FakeAwait([
    for (final c in callIds)
      if (c > id) c + 1 else c,
  ], gathered: gathered);
}

/// A print: the worker's `Print`.
final class FakePrint extends FakeEvent {
  /// [text] printed to [stream].
  const FakePrint(this.text, this.stream);

  /// The text.
  final String text;

  /// `stdout` or `stderr`.
  final String stream;
}

/// Python catching the exception the answer before it raised.
final class FakeCatch extends FakeEvent {
  /// Python catches it.
  const FakeCatch();
}

/// A protocol turn kept in flight until [gate] completes.
final class FakeHold extends FakeEvent {
  /// A hold until [gate].
  const FakeHold(this.gate);

  /// What ends the hold.
  final Future<void> gate;
}

/// A feed-ending event.
sealed class FakeEnd extends FakeEvent {
  const FakeEnd();
}

/// The feed's value: the worker's `Complete`.
final class FakeReturn extends FakeEnd {
  /// The feed returns [value].
  const FakeReturn(this.value);

  /// The value.
  final MontyValue value;
}

/// An uncaught exception: the worker's `Error`.
final class FakeRaise extends FakeEnd {
  /// The feed raises [exception], placed at [line] and [column] when given.
  const FakeRaise(this.exception, {this.line, this.column});

  /// The exception as the worker sends it, with no traceback.
  final pb.RaisedException exception;

  /// The line of the frame the fake builds, or none for no frame.
  final int? line;

  /// The frame's column.
  final int? column;
}

/// A dead worker.
final class FakeCrash extends FakeEnd {
  /// The worker dies; [timedOut] as a killed deadline reports it.
  const FakeCrash({required this.timedOut});

  /// Whether the death is reported as a timeout.
  final bool timedOut;
}

/// [value] checked as the writer checks a value and placed in [writer]:
/// scripted values must be ones a worker could send (inbound.md).
int scriptedValue(ArenaWriter writer, MontyValue value) {
  ArenaWriter().add(value);

  return writer.add(value);
}
