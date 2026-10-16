part of 'telemetry_recorder.dart';

/// Request-side records, after the complete frame has been sent.
extension RecorderRequests on Recorder {
  /// Opens a turn or closes the suspension answered by this request.
  void beginTurn(pb.ParentRequest request) {
    final kind = request.whichKind();
    final resume =
        kind == pb.ParentRequest_Kind.resumeCall ||
        kind == pb.ParentRequest_Kind.resumeNameLookup ||
        kind == pb.ParentRequest_Kind.resumeFutures ||
        kind == pb.ParentRequest_Kind.abortFeed;
    if (!resume) {
      _end(_turn);
      _turn = null;
    }
    _dumpTurn = false;
    switch (kind) {
      case pb.ParentRequest_Kind.configure:
        close();
        _session = _open(
          'session {script_name}',
          configureAttributes(request.configure, workerPid),
          parent: captured,
        );
      case pb.ParentRequest_Kind.feed:
        _end(_pending);
        _pending = null;
        _end(_feed);
        _feed = null;
        _feed = _open('run code', feedAttributes(request.feed));
      case pb.ParentRequest_Kind.load:
        _turn = _open(
          'load',
          TelemetryAttributes({'state_bytes': '${request.load.state.length}'}),
        );
      case pb.ParentRequest_Kind.dump:
        _dumpTurn = true;
        _turn = _open('dump', TelemetryAttributes());
      case pb.ParentRequest_Kind.installDependencies:
        final attributes = TelemetryAttributes();
        final requirements = request.installDependencies.requirements;
        if (requirements.isNotEmpty) {
          attributes.add('requirements', telemetryList(requirements));
        }
        _turn = _open('install dependencies', attributes);
      case pb.ParentRequest_Kind.reset || pb.ParentRequest_Kind.shutdown:
        close();
      case _:
        _resumeRequest(request);
    }
  }

  void _resumeRequest(pb.ParentRequest request) {
    switch (request.whichKind()) {
      case pb.ParentRequest_Kind.resumeCall:
        final resume = request.resumeCall;
        _answer('return_value', telemetryResult(resume.result, resume.values));
      case pb.ParentRequest_Kind.resumeNameLookup:
        final resume = request.resumeNameLookup;
        final value = switch (resume.whichKind()) {
          pb.ResumeNameLookup_Kind.value => telemetryValue(
            resume.values,
            resume.value,
          ),
          pb.ResumeNameLookup_Kind.error => telemetryRaised(resume.error),
          pb.ResumeNameLookup_Kind.undefined => (
            value: 'undefined',
            cut: false,
          ),
          pb.ResumeNameLookup_Kind.notSet => (value: '<missing>', cut: false),
        };
        _answer('value', value);
      case pb.ParentRequest_Kind.abortFeed:
        final abort = request.abortFeed;
        _answer(
          'aborted_with',
          abort.hasException()
              ? telemetryRaised(abort.exception)
              : (value: '<missing>', cut: false),
        );
      case pb.ParentRequest_Kind.resumeFutures:
        _resumeFutures(request.resumeFutures);
      case _:
        break;
    }
  }

  void _resumeFutures(pb.ResumeFutures resume) {
    final results = resume.results;
    if (results.length == 1 && _pending?.eagerCallId == results.single.callId) {
      _answer(
        'return_value',
        telemetryResult(results.single.result, resume.values),
      );
      return;
    }
    final attributes = TelemetryAttributes();
    if (results.isNotEmpty) {
      final text = StringBuffer();
      var cut = false;
      for (final result in results) {
        final rendered = telemetryResult(result.result, resume.values);
        if (text.isNotEmpty) text.write(', ');
        text.write('${result.callId}: ${rendered.value}');
        cut |= rendered.cut;
        if (text.length > telemetryAttributeLimit) break;
      }
      final rendered = telemetryText(text.toString());
      attributes.add('results', (
        value: rendered.value,
        cut: cut || rendered.cut,
      ));
    }
    // Upstream uses an empty parent when no pending span is present.
    bridge.log(_pending?.handle, 'INFO', 'future results', attributes.values);
    _end(_pending);
    _pending = null;
  }
}
