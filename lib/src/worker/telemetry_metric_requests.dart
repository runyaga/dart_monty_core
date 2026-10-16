part of 'telemetry_turn_metrics.dart';

/// Requests start work only once the frame has reached the wire.
extension TelemetryMetricRequests on TelemetryTurnMetrics {
  /// Starts a run/housekeeping turn, or answers the host round-trip.
  void beginTurn(pb.ParentRequest request) {
    final kind = request.whichKind();
    final now = Stopwatch()..start();
    switch (kind) {
      case pb.ParentRequest_Kind.configure:
        _resetRun();
        _reported = BigInt.zero;
        _turn = ('configure', now);
      case pb.ParentRequest_Kind.feed:
        _takePending();
        _feed = now;
        _runActive = true;
      case pb.ParentRequest_Kind.load:
        _runActive = false;
        _reported = BigInt.zero;
        _turn = ('load', now);
      case pb.ParentRequest_Kind.reset:
        _resetRun();
        _turn = ('reset', now);
      case pb.ParentRequest_Kind.shutdown:
        _resetRun();
        _turn = null;
      case pb.ParentRequest_Kind.dump:
        _turn = ('dump', now);
      case pb.ParentRequest_Kind.installDependencies:
        _turn = ('install_dependencies', now);
      case _:
        _resume(request);
    }
  }

  void _resetRun() {
    _feed = null;
    _runActive = false;
    _takePending();
  }

  void _resume(pb.ParentRequest request) {
    switch (request.whichKind()) {
      case pb.ParentRequest_Kind.resumeCall:
        _answer(_extOutcome(request.resumeCall.result));
      case pb.ParentRequest_Kind.resumeNameLookup:
        _answer(_lookupOutcome(request.resumeNameLookup));
      case pb.ParentRequest_Kind.resumeFutures:
        _answer(_futuresOutcome(request.resumeFutures));
      case pb.ParentRequest_Kind.abortFeed:
        _answer('aborted');
      case _:
        break;
    }
  }

  String _futuresOutcome(pb.ResumeFutures resume) {
    final eager = _pending?.eagerId;

    return switch (resume.results) {
      [final result] when eager != null && result.callId == eager =>
        _extOutcome(result.result),
      _ => 'resolved',
    };
  }
}

String _lookupOutcome(pb.ResumeNameLookup resume) =>
    switch (resume.whichKind()) {
      pb.ResumeNameLookup_Kind.value => 'value',
      pb.ResumeNameLookup_Kind.undefined => 'undefined',
      pb.ResumeNameLookup_Kind.error => 'error',
      pb.ResumeNameLookup_Kind.notSet => 'missing',
    };
