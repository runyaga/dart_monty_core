// The contract suite's harness: one scenario, run as Python on a real
// session and as a script on FakeMontySession, gives a host-visible trace
// (host calls, prints, snapshots, the end) and the host's answers. Both
// sides are compared with the same expected lists.
//
// WHERE THE FAKE DOES NOT MATCH THE WORKER: the listed exceptions. Each is
// left out of the comparison here, by name, never skipped silently.
//  1. Positions. A snapshot's `position` is the worker's source range; the
//     fake has none (`SourceRange.unknown`). showSnapshot leaves it out.
//  2. Frames. A worker error carries its traceback with source lines and
//     end positions; the fake's has none, or with `willRaise(line:)` one
//     frame with no source line. Only filename, line, column and function
//     name are compared ('frames are named per feed'); `display()` is not.
//  3. Pending-id order. A `FutureSnapshot`'s `pendingCallIds` lists every
//     pending host future in the worker's hash-map order (upstream
//     `scheduler.rs` `pending_call_ids`); the fake lists them ascending.
//     showSnapshot sorts them.
//  4. Before the cutover there is no `MontyHostFunction`: the scenarios
//     that pass a function as a value (in inputs, as an alias, a replaced
//     entry, a function nested in an argument) and an invalid lookup value
//     run on the cutover candidate (C4 pre-cutover.md, refusals.md).
//  5. Type names. The plain-value `TypeError` names the value's Python
//     type; the suite checks `int` only (pythonTypeName in the fake).
//  6. What the fake does not do: run Python, type-check, enforce limits
//     (the session's own budgets still apply). No scenario depends on them.
//  7. Ids with no host call. Upstream gives an awaitable `asyncio.sleep`
//     answered with a plain value a second call id (`settled_awaitable`);
//     the fake does the same. A zero-delay `asyncio.sleep` under the
//     system sleep policy makes no host call yet takes an id too; a script
//     cannot show it, so later calls number one lower on the fake. Not in
//     the suite.
//  8. Partial gathers. After a batch settles part of a gather, a script
//     cannot say whether its next events come from a branch the batch
//     unblocked or from after the gather. The fake runs on when the next
//     event past any prints is a call, a lookup or a hold, and otherwise
//     waits for the rest first; ids it ran on without are waited for
//     before the feed returns; a failure among them raises when it
//     settles, and once caught the gather owes nothing more. Two orders
//     the script cannot express are fixed: a batch's failure raises before
//     a branch unblocked by the same batch runs, and an exception caught
//     after a branch's call raised is taken as caught inside the branch.
//  9. OS answers. The worker checks an OS call's answer against the
//     operation (a file handle for `open`, no future for an operation that
//     takes none); the fake takes any value the writer takes. A handler
//     test that relies on those checks runs against a real session.
import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:dart_monty_core/src/fake_answers.dart';
import 'package:dart_monty_core/src/fake_monty_session.dart';
import 'package:dart_monty_core/src/platform/exception_attributes.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

/// A host function body.
typedef Body =
    FutureOr<MontyValue> Function(
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// One contract scenario.
final class Scenario {
  /// A scenario named [name]: [feeds] for the real session, [script] for the
  /// fake, [run] the host code both sides run, and what both must show.
  const Scenario(
    this.name, {
    required this.feeds,
    required this.script,
    required this.run,
    required this.trace,
    required this.answers,
    this.config = const SessionConfig(),
  });

  /// The scenario's name.
  final String name;

  /// The Python of each feed, in order.
  final List<String> feeds;

  /// The fake's script: what the feeds' Python does.
  final void Function(FakeMontySession fake) script;

  /// The host code, the same on both sides.
  final Future<void> Function(Side side) run;

  /// The expected trace.
  final List<String> trace;

  /// The expected answers, as [showAnswer] writes them.
  final List<String> answers;

  /// The real session's settings.
  final SessionConfig config;
}

/// One side's run: the session, the feeds' code and what the host saw.
final class Side {
  /// A side over [session].
  Side(this.session, this.feeds, {required this.isFake});

  /// The session under test.
  final PoolSession session;

  /// The scenario's feeds.
  final List<String> feeds;

  /// Whether [session] is the fake.
  final bool isFake;

  /// What the host saw, in order.
  final List<String> trace = [];

  /// The errors the feeds and resumes ended with, in order.
  final List<Object> errors = [];

  /// The code of feed [i].
  String code(int i) =>
      feeds.elementAtOrNull(i) ?? (throw RangeError.index(i, feeds, 'i'));

  /// The host function [name], recording each call before running [body]
  /// (a call returning `None` when no body is given).
  ProtoExternalFunction fn(String name, [Body? body]) => (args, kwargs) {
    trace.add('call $name${showArgs(args, kwargs)}');

    return body == null ? const MontyNone() : body(args, kwargs);
  };

  /// The host coroutine [name], as [fn].
  ProtoExternalFunction async(String name, [Body? body]) =>
      coroutine(fn(name, body));

  /// An OS handler recording each call before running [body].
  OsHandler os(
    FutureOr<MontyValue> Function(
      String name,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    )
    body,
  ) => (name, args, kwargs) {
    trace.add('os $name${showArgs(args, kwargs)}');

    return body(name, args, kwargs);
  };

  /// The print callback: each fragment joins the one before it when both
  /// are prints to the same stream (trace.md).
  void printer(String stream, String text) {
    final head = 'print[$stream] ';
    if (trace.isNotEmpty && trace.last.startsWith(head)) {
      trace.last = '${trace.last}$text';
    } else {
      trace.add('$head$text');
    }
  }

  /// Runs feed [i] to its end and records the end.
  Future<void> run(
    int i, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    OsHandler? os,
  }) => end(
    () => session.feedRun(
      code(i),
      inputs: inputs,
      externals: externals,
      os: os,
      printCallback: printer,
    ),
  );

  /// Records how [body] ended: its value or its error.
  Future<void> end(Future<MontyValue> Function() body) async =>
      trace.add(await outcome(body));

  /// How [body] ended, as the trace writes it.
  Future<String> outcome(Future<MontyValue> Function() body) async {
    try {
      return 'value ${showValue(await body())}';
    } on Object catch (error) {
      errors.add(error);

      return showError(error);
    }
  }

  /// Starts feed [i] and records where it stopped.
  Future<MontySnapshot?> start(
    int i, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    OsHandler? os,
  }) => step(
    () => session.feedStart(
      code(i),
      inputs: inputs,
      externals: externals,
      os: os,
      printCallback: printer,
    ),
  );

  /// Resumes [at] with [resume] when it is a [T], recording where that
  /// stopped; otherwise records what [at] was instead, and returns null.
  Future<MontySnapshot?> next<T extends MontySnapshot>(
    MontySnapshot? at,
    Future<MontySnapshot> Function(T snapshot) resume,
  ) async {
    if (at is T) return step(() => resume(at));
    trace.add('expected a $T, not $at');

    return null;
  }

  /// Records where [body], a start or a resume, stopped; null when it threw.
  Future<MontySnapshot?> step(Future<MontySnapshot> Function() body) async {
    try {
      final snapshot = await body();
      trace.add(showSnapshot(snapshot));

      return snapshot;
    } on Object catch (error) {
      trace.add(showError(error));
      errors.add(error);

      return null;
    }
  }
}

/// [args] and [kwargs] as the trace writes them.
String showArgs(List<MontyValue> args, Map<String, MontyValue> kwargs) {
  final shown = [
    for (final a in args) showValue(a),
    for (final MapEntry(:key, :value) in kwargs.entries)
      '$key=${showValue(value)}',
  ];

  return '(${shown.join(', ')})';
}

/// [value] as the trace writes it, unambiguously: strings and paths
/// quoted, containers, bytes and named tuples with their contents, and a
/// float the same on every platform (dart2js writes an integral double
/// without its `.0`). Other kinds are written as their JSON form.
String showValue(MontyValue value) => switch (value) {
  MontyString(value: final text) => 'MontyString(${jsonEncode(text)})',
  MontyPath(value: final path) => 'MontyPath(${jsonEncode(path)})',
  MontyBytes(value: final bytes) => 'MontyBytes$bytes',
  MontyFloat(value: final v) => 'MontyFloat(${_showFloat(v)})',
  MontyList(:final items) => 'MontyList[${_showAll(items)}]',
  MontyTuple(:final items) => 'MontyTuple(${_showAll(items)})',
  MontySet(:final items) => 'MontySet{${_showAll(items)}}',
  MontyFrozenSet(:final items) => 'MontyFrozenSet{${_showAll(items)}}',
  MontyDict(:final pairs) => 'MontyDict{${pairs.map(_showPair).join(', ')}}',
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    'MontyNamedTuple($typeName, $fieldNames, ${_showAll(values)})',
  MontyNone() || MontyBool() || MontyInt() || MontyBigInt() => '$value',
  // Every other kind whole, as its JSON form.
  _ => jsonEncode(value.toJson()),
};

/// [v] exactly and the same on every platform: an integral double below
/// 2^53 with its `.0` and sign, a larger one in exponent form.
String _showFloat(double v) {
  if (!v.isFinite || v != v.truncateToDouble()) return '$v';
  final magnitude = v.abs();
  if (magnitude >= 9007199254740992) return v.toStringAsExponential();
  final sign = v.isNegative ? '-' : '';

  return '$sign${magnitude.toInt()}.0';
}

String _showAll(List<MontyValue> items) => items.map(showValue).join(', ');

String _showPair((MontyValue, MontyValue) pair) =>
    '${showValue(pair.$1)}: ${showValue(pair.$2)}';

/// [snapshot] as the trace writes it. Positions are left out: the fake has
/// none (a listed exception).
String showSnapshot(MontySnapshot snapshot) => switch (snapshot) {
  SessionComplete(:final output) => 'complete ${showValue(output)}',
  FunctionSnapshot(
    :final functionName,
    :final callId,
    :final isOsFunction,
    :final allowEagerAwait,
    :final args,
    :final kwargs,
  ) =>
    'snap ${isOsFunction ? 'os' : 'call'} $functionName#$callId'
        '${allowEagerAwait ? ' eager' : ''}${showArgs(args, kwargs)}',
  NameLookupSnapshot(:final variableName) => 'snap lookup $variableName',
  // Upstream lists the pending ids in hash order; the fake ascending.
  FutureSnapshot(:final pendingCallIds) =>
    'snap futures ${[...pendingCallIds]..sort()}',
};

/// [error] as the trace writes it: its class, `exception` and
/// `toString()`.
String showError(Object error) => switch (error) {
  MontyCrashedError(:final cause, :final timedOut) =>
    'crashed ${cause.name}${timedOut ? ' timedOut' : ''}',
  MontyError(:final exception) =>
    '${error.runtimeType} ${exception.excType}: ${exception.message}'
        '${_attributes(exception)}'
        ' | $error',
  _ => '${error.runtimeType}: $error',
};

String _attributes(MontyExceptionValue exception) {
  final attributes = exceptionAttributes(exception);

  if (attributes.isEmpty) return '';
  final shown = [
    for (final MapEntry(:key, :value) in attributes.entries)
      '$key: ${showValue(value)}',
  ];

  return ' {${shown.join(', ')}}';
}

/// [entry] as the expected answers write it.
String showAnswer(FakeAnswer entry) {
  final id = entry.callId == null ? '-' : '${entry.callId}';
  final batch = entry.batch == null ? '' : '/b${entry.batch}';
  final answer = switch (entry.answer) {
    null => 'none',
    ExternalReturnValue(:final value) => 'value ${showValue(value)}',
    ExternalException(:final excType, :final message, :final attributes) =>
      'raise $excType: $message${attributes.isEmpty ? '' : ' $attributes'}',
    ExternalFuture() => 'future',
  };

  return '$id$batch $answer';
}

/// A channel that records the answers in every request it forwards.
final class RecordingChannel implements MontyChannel {
  /// Forwards to [_inner], recording into [log].
  const RecordingChannel(this._inner, this.log);

  /// What the session answered.
  final FakeAnswers log;

  final MontyChannel _inner;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) {
    log.add(request);

    return _inner.turn(request, onPrint: onPrint);
  }

  @override
  Future<void> close() => _inner.close();

  @override
  void kill() => _inner.kill();

  @override
  bool get isAlive => _inner.isAlive;
}

/// What one side showed.
typedef Outcome = ({List<String> trace, List<String> answers, Side side});

/// Runs [scenario] on a real session from a pool over [open].
Future<Outcome> runReal(Scenario scenario, OpenChannel open) async {
  final log = FakeAnswers();
  final pool = await MontyPool.startWith(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () {
      final inner = open();

      return PendingSpawn(
        (_) async => RecordingChannel(await inner.ready, log),
      );
    },
  );
  try {
    final session = await pool.checkout(options: scenario.config);
    final side = Side(session, scenario.feeds, isFake: false);
    try {
      await scenario.run(side);
    } finally {
      await session.close();
    }

    return (
      trace: side.trace,
      answers: [for (final a in log.answers) showAnswer(a)],
      side: side,
    );
  } finally {
    await pool.close();
  }
}

/// Runs [scenario] on a fake session.
Future<Outcome> runFake(Scenario scenario) async {
  final fake = FakeMontySession();
  scenario.script(fake);
  final side = Side(fake, scenario.feeds, isFake: true);
  try {
    await scenario.run(side);
  } finally {
    await fake.close();
  }

  return (
    trace: side.trace,
    answers: [for (final a in fake.answers) showAnswer(a)],
    side: side,
  );
}

/// Checks [outcome] against [scenario]'s expectations.
void expectOutcome(Scenario scenario, Outcome outcome) {
  expect(outcome.trace, scenario.trace, reason: 'trace');
  expect(outcome.answers, scenario.answers, reason: 'answers');
}
