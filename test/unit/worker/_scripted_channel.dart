// A MontyChannel that answers from a script instead of a worker.
//
// Each turn takes the next scripted reply: the events a worker would send
// (zero or more Print, then the turn end) or a crash. Requests and events go
// through the protobuf wire encoding both ways, so a message the real channel
// could not send fails here too. Pure Dart: runs on vm, dart2js and dart2wasm.
import 'dart:async';
import 'dart:collection';

import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

import '../../_accessors.dart';

/// The worker's reply to one request.
typedef Reply = List<pb.ChildEvent> Function(pb.ParentRequest request);

/// A scripted worker.
final class ScriptedChannel implements MontyChannel {
  /// Answers each turn with the next of [script].
  ScriptedChannel(Iterable<Reply> script) : _remaining = Queue.of(script);

  /// Every request received, decoded from its wire bytes.
  final List<pb.ParentRequest> requests = [];

  /// How many times [close] was called.
  int closes = 0;

  /// How many times [kill] was called.
  int kills = 0;

  final Queue<Reply> _remaining;
  final Completer<void> _killed = Completer();
  bool _isAlive = true;

  /// Replies not yet used.
  int get remaining => _remaining.length;

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
    final sent = pb.ParentRequest.fromBuffer(request.writeToBuffer());
    requests.add(sent);
    if (_remaining.isEmpty) {
      throw StateError('script exhausted at a ${sent.whichKind().name}');
    }
    final reply = _remaining.removeFirst();
    // A real turn is asynchronous; so is this one.
    await Future<void>.delayed(Duration.zero);
    final List<pb.ChildEvent> events;
    try {
      events = [
        for (final e in reply(sent))
          pb.ChildEvent.fromBuffer(e.writeToBuffer()),
      ];
    } on _Crash catch (c) {
      _isAlive = false;
      throw crashedError(c.cause, detail: c.message, exitCode: c.exitCode);
    } on _Hang catch (h) {
      return _hang(h.prints, onPrint);
    }
    for (final e in events.take(events.length - 1)) {
      if (e.whichKind() != pb.ChildEvent_Kind.print) {
        throw StateError('only Print may precede the turn end');
      }
      await onPrint?.call(e.print);
    }
    final end = itemAt(events, events.length - 1);
    if (end.whichKind() == pb.ChildEvent_Kind.fatalError) {
      _isAlive = false;
      throw crashedError(
        CrashCause.fatal,
        detail: end.fatalError.message,
      );
    }

    return end;
  }

  @override
  Future<void> close() async {
    closes++;
    _isAlive = false;
  }

  @override
  void kill() {
    kills++;
    if (!_killed.isCompleted) _killed.complete();
    _isAlive = false;
  }

  /// Streams [prints] one by one, as a native worker would, and never ends
  /// the turn: only [kill] does.
  Future<pb.ChildEvent> _hang(
    List<pb.ChildEvent> prints,
    PrintHandler? onPrint,
  ) async {
    for (final p in prints) {
      if (_killed.isCompleted) break;
      await onPrint?.call(p.print);
      await Future<void>.delayed(Duration.zero);
    }
    await _killed.future;
    throw crashedError(CrashCause.killed, detail: 'killed mid-turn');
  }
}

/// A reply of [events], whatever was asked.
Reply answer(List<pb.ChildEvent> events) =>
    (_) => events;

/// A reply that checks the request is a [kind] before answering [events].
Reply expecting(
  pb.ParentRequest_Kind kind,
  List<pb.ChildEvent> events,
) => (request) {
  if (request.whichKind() != kind) {
    throw StateError('expected ${kind.name}, got ${request.whichKind().name}');
  }

  return events;
};

/// A worker that dies with [cause] instead of answering, with [exitCode]
/// when the OS reported one.
Reply crash(CrashCause cause, [String? message, int? exitCode]) =>
    (_) => throw _Crash(cause, message, exitCode);

/// A worker that streams [prints] and then runs until killed.
Reply hangAfter(List<pb.ChildEvent> prints) =>
    (_) => throw _Hang(prints);

/// How a [Reply] tells the channel to hang.
final class _Hang implements Exception {
  const _Hang(this.prints);

  final List<pb.ChildEvent> prints;

  @override
  String toString() => '_Hang(${prints.length} prints)';
}

/// How a [Reply] tells the channel the worker died.
final class _Crash implements Exception {
  const _Crash(this.cause, this.message, this.exitCode);

  final CrashCause cause;
  final String? message;
  final int? exitCode;

  @override
  String toString() => '_Crash(${cause.name}, $message)';
}

/// `Ok`.
pb.ChildEvent ok() => pb.ChildEvent(ok: pb.Ok());

/// `Complete` of the value at [root] in [nodes].
pb.ChildEvent complete(List<pb.MontyNode> nodes, [int? root]) => pb.ChildEvent(
  complete: pb.Complete(
    value: root ?? nodes.length - 1,
    values: pb.Arena(nodeCount: nodes.length, nodes: nodes),
  ),
);

/// `Complete` of `None`.
pb.ChildEvent completeNone() => complete([pb.MontyNode(none: pb.Unit())]);

/// One `Print` of [segments], each (stream, text).
pb.ChildEvent printed(List<(pb.PrintStream, String)> segments) => pb.ChildEvent(
  print: pb.Print(
    segments: [
      for (final (stream, text) in segments)
        pb.PrintSegment(stream: stream, text: text),
    ],
  ),
);

/// An `Error` raising [excType].
pb.ChildEvent raised(
  String excType, [
  String? message,
  List<pb.StackFrame> traceback = const [],
]) => pb.ChildEvent(
  error: pb.Error(
    exception: pb.RaisedException(
      excType: excType,
      message: message,
      traceback: traceback,
    ),
  ),
);

/// `FatalError`.
pb.ChildEvent fatal(String message) =>
    pb.ChildEvent(fatalError: pb.FatalError(message: message));
