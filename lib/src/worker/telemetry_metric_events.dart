part of 'telemetry_turn_metrics.dart';

/// Events carry execution clocks and determine the operation's outcome.
extension TelemetryMetricEvents on TelemetryTurnMetrics {
  /// Handles a decoded event before the host sees it.
  void event(pb.ChildEvent event) {
    _rebaseLoad(event);
    switch (event.whichKind()) {
      case pb.ChildEvent_Kind.print:
        _print(event.print);
      case pb.ChildEvent_Kind.functionCall:
        final call = event.functionCall;
        _suspend(
          'function',
          eagerId: call.allowEagerAwait ? call.callId : null,
        );
      case pb.ChildEvent_Kind.osCall:
        _suspend('os', function: _osFunction(event.osCall));
      case pb.ChildEvent_Kind.nameLookup:
        _suspend('name_lookup');
      case pb.ChildEvent_Kind.resolveFutures:
        _suspend('futures');
      case _:
        _endEvent(event);
    }
  }

  void _rebaseLoad(pb.ChildEvent event) {
    if (_turn?.$1 != 'load') return;
    final total = _unsignedMicros(event);
    if (total > _reported) _reported = total;
  }

  void _endEvent(pb.ChildEvent event) {
    switch (event.whichKind()) {
      case pb.ChildEvent_Kind.complete:
        _endRun('complete', event);
      case pb.ChildEvent_Kind.error:
        if (_turn != null) {
          _endTurn('error');
        } else {
          _endRun('error', event);
        }
      case pb.ChildEvent_Kind.typingError:
        _endRun('typing_error', event);
      case pb.ChildEvent_Kind.dumpResult:
        TelemetryMetrics.snapshot.record(event.dumpResult.state.length, {
          'op': 'dump',
        });
        _endTurn('ok');
      case pb.ChildEvent_Kind.ok:
        _endTurn('ok');
      case pb.ChildEvent_Kind.fatalError:
        _terminal('fatal_error', event);
      case pb.ChildEvent_Kind.shutdown:
        _terminal('shutdown', event);
      case _:
        break;
    }
  }

  void _print(pb.Print printed) {
    final totals = {'stdout': 0, 'stderr': 0, 'unspecified': 0};
    for (final segment in printed.segments) {
      final stream = switch (segment.stream) {
        pb.PrintStream.PRINT_STREAM_STDOUT => 'stdout',
        pb.PrintStream.PRINT_STREAM_STDERR => 'stderr',
        _ => 'unspecified',
      };
      final bytes = utf8.encode(segment.text).length;
      totals.update(stream, (total) => total + bytes);
    }
    for (final MapEntry(key: stream, value: bytes) in totals.entries) {
      if (bytes > 0) TelemetryMetrics.print.record(bytes, {'stream': stream});
    }
  }
}

final _capitalLetter = RegExp('[A-Z]');

String _osFunction(pb.OsCall call) {
  final kind = call.whichCall();
  if (kind == pb.OsCall_Call.notSet) return 'unknown';

  return kind.name.replaceAllMapped(
    _capitalLetter,
    (match) => '_${match.group(0)?.toLowerCase() ?? ''}',
  );
}
