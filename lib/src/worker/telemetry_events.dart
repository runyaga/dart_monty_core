part of 'telemetry_recorder.dart';

/// Event-side records, before protocol classification or host callbacks.
extension TelemetryEvents on TelemetryRecorder {
  /// Records one decoded event, including prints and fatal errors.
  void event(pb.ChildEvent event) {
    metrics.event(event);
    if (event.hasRestoredScriptName()) {
      _turn?.attributes.text('script_name', event.restoredScriptName);
    }
    switch (event.whichKind()) {
      case pb.ChildEvent_Kind.print:
        _prints(event.print);
      case pb.ChildEvent_Kind.complete:
        _complete(event);
      case pb.ChildEvent_Kind.error:
        _error(event);
      case pb.ChildEvent_Kind.typingError:
        _log(
          'typing error',
          eventTiming(event)
            ..text('diagnostics', event.typingError.diagnostics),
          error: true,
        );
        _endFeed();
      case _:
        _otherEvent(event);
    }
  }

  void _otherEvent(pb.ChildEvent event) {
    switch (event.whichKind()) {
      case pb.ChildEvent_Kind.functionCall ||
          pb.ChildEvent_Kind.osCall ||
          pb.ChildEvent_Kind.nameLookup ||
          pb.ChildEvent_Kind.resolveFutures:
        _suspend(event);
      case _:
        _housekeeping(event);
    }
  }

  void _prints(pb.Print print) {
    for (final segment in print.segments) {
      final attributes = TelemetryAttributes({
        'stream': switch (segment.stream) {
          pb.PrintStream.PRINT_STREAM_STDOUT => 'stdout',
          pb.PrintStream.PRINT_STREAM_STDERR => 'stderr',
          _ => 'unspecified',
        },
      })..text('text', segment.text);
      _log('print ${attributes.values['stream']}', attributes);
    }
  }

  void _error(pb.ChildEvent event) {
    final attributes = errorAttributes(event);
    _log('error ${attributes.values['exc_type']}', attributes, error: true);
    if (_dumpTurn) {
      _end(_turn);
      _turn = null;
    } else {
      _endFeed();
    }
  }

  void _suspend(pb.ChildEvent event) {
    final attributes = eventTiming(event);
    final String name;
    switch (event.whichKind()) {
      case pb.ChildEvent_Kind.functionCall:
        name = 'call {function_name}';
        _functionAttributes(event.functionCall, attributes);
      case pb.ChildEvent_Kind.osCall:
        name = 'os call {function}';
        osAttributes(event.osCall, attributes);
      case pb.ChildEvent_Kind.nameLookup:
        final lookup = event.nameLookup;
        name = 'name lookup {name}';
        attributes
          ..text('name', lookup.name)
          ..position(lookup.hasPosition() ? lookup.position : null);
      case _:
        final futures = event.resolveFutures;
        name = 'resolve futures';
        attributes.position(futures.hasPosition() ? futures.position : null);
        if (futures.pendingCallIds.isNotEmpty) {
          attributes.add(
            'pending_call_ids',
            telemetryList(futures.pendingCallIds),
          );
        }
    }
    final pending = _open(name, attributes);
    if (event.hasFunctionCall() && event.functionCall.allowEagerAwait) {
      pending.eagerCallId = event.functionCall.callId;
    }
    _end(_pending);
    _pending = pending;
  }

  void _functionAttributes(
    pb.FunctionCall call,
    TelemetryAttributes attributes,
  ) {
    attributes.text('function_name', call.functionName);
    attributes.values['call_id'] = '${call.callId}';
    if (call.hasObjectId()) {
      attributes.values['object_id'] = uuidString(call.objectId.data);
    }
    attributes.position(call.hasPosition() ? call.position : null);
    if (call.args.isNotEmpty) {
      attributes.add('args', telemetrySequence(call.values, call.args));
    }
    if (call.kwargs.isNotEmpty) {
      attributes.add('kwargs', telemetryPairs(call.values, call.kwargs));
    }
  }

  void _complete(pb.ChildEvent event) {
    final complete = event.complete;
    final output = telemetryValue(complete.values, complete.value);
    final feed = _feed;
    _feed = null;
    if (feed == null) {
      _log('complete', eventTiming(event)..add('output', output));
    } else {
      feed.attributes.add('output', output);
      feed.attributes.values.addAll(eventTiming(event, signed: true).values);
      _end(feed);
    }
    _endFeed();
  }

  void _housekeeping(pb.ChildEvent event) {
    switch (event.whichKind()) {
      case pb.ChildEvent_Kind.dumpResult:
        final turn = _turn;
        if (turn != null) {
          turn.attributes.values
            ..addAll(eventTiming(event, signed: true).values)
            ..['state_bytes'] = event.dumpResult.state.length;
        }
        _end(turn);
        _turn = null;
      case pb.ChildEvent_Kind.ok:
        _end(_turn);
        _turn = null;
      case pb.ChildEvent_Kind.fatalError:
        _log(
          'fatal error',
          TelemetryAttributes()..text('message', event.fatalError.message),
          error: true,
        );
      case pb.ChildEvent_Kind.notSet:
        _log('event with no kind', TelemetryAttributes(), error: true);
      case _:
        break; // D-089: hosted-relay Shutdown records are omitted.
    }
  }
}
