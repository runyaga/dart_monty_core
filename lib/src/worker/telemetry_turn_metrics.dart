/// Independent metric state machine from upstream telemetry/metrics.rs.
library;

import 'dart:convert';

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry_metrics.dart';

part 'telemetry_metric_requests.dart';
part 'telemetry_metric_events.dart';

/// One worker's execution clock, housekeeping turn and outstanding suspension.
final class TelemetryTurnMetrics {
  Stopwatch? _feed;
  bool _runActive = false;
  (String, Stopwatch)? _turn;
  BigInt _reported = BigInt.zero;
  _Suspension? _pending;

  /// A worker disappearing abandons its host round-trip without timing it.
  void close() => _takePending();

  void _endTurn(String outcome) {
    final turn = _turn;
    _turn = null;
    if (turn case (final kind, final clock)) {
      TelemetryMetrics.turn.elapsed(clock, {'turn': kind, 'outcome': outcome});
    }
  }

  void _endRun(String outcome, pb.ChildEvent event) {
    _runActive = false;
    _takePending();
    _endTurn(outcome);
    final feed = _feed;
    _feed = null;
    if (feed != null) TelemetryMetrics.run.elapsed(feed, {'outcome': outcome});
    final total = _unsignedMicros(event);
    final delta = total > _reported ? total - _reported : BigInt.zero;
    if (total > _reported) _reported = total;
    TelemetryMetrics.execution.record(delta.toDouble() / 1000000);
  }

  void _terminal(String outcome, pb.ChildEvent event) {
    if (_runActive) {
      _endRun(outcome, event);
    } else {
      _endTurn(outcome);
    }
  }

  void _suspend(String kind, {String? function, int? eagerId}) {
    if (_turn?.$1 == 'load') _endTurn('ok');
    _runActive = true;
    TelemetryMetrics.suspensions.record(1, {'kind': kind});
    _takePending();
    _pending = _Suspension(kind, function, eagerId);
    TelemetryMetrics.suspended.record(1);
  }

  _Suspension? _takePending() {
    final pending = _pending;
    _pending = null;
    if (pending != null) TelemetryMetrics.suspended.record(-1);

    return pending;
  }

  void _answer(String outcome) {
    final pending = _takePending();
    if (pending == null) return;
    TelemetryMetrics.call.elapsed(pending.clock, {
      'kind': pending.kind,
      'outcome': outcome,
      'function': ?pending.function,
    });
  }
}

final class _Suspension {
  _Suspension(this.kind, this.function, this.eagerId);

  final String kind;
  final String? function;
  final int? eagerId;
  final clock = Stopwatch()..start();
}

String _extOutcome(pb.ExtFunctionResult result) => switch (result.whichKind()) {
  pb.ExtFunctionResult_Kind.returnValue => 'value',
  pb.ExtFunctionResult_Kind.error => 'error',
  pb.ExtFunctionResult_Kind.future => 'future',
  pb.ExtFunctionResult_Kind.notFound => 'not_found',
  pb.ExtFunctionResult_Kind.notHandled => 'not_handled',
  pb.ExtFunctionResult_Kind.notSet => 'missing',
};

BigInt _unsignedMicros(pb.ChildEvent event) =>
    BigInt.parse(event.totalExecutionMicros.toStringUnsigned());
