/// Port of monty-pool 1.1.0 telemetry/tracing.rs, excluding D-089's keys.
library;

import 'package:dart_monty_core/src/worker/arena_nodes.dart' show uuidString;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry.dart';
import 'package:dart_monty_core/src/worker/telemetry_attributes.dart';
import 'package:dart_monty_core/src/worker/telemetry_scalars.dart';
import 'package:dart_monty_core/src/worker/telemetry_values.dart';

part 'telemetry_requests.dart';
part 'telemetry_events.dart';

/// One checkout, with explicit span nesting independent of the current zone.
final class TelemetryRecorder {
  /// Captures the parent at checkout, but opens no span until Configure.
  TelemetryRecorder(this.bridge, this.workerPid)
    : captured = bridge.currentContext();

  /// Installation shared by all sessions, including disabled signals.
  final TelemetryBridge bridge;

  /// Native worker id, absent in the browser.
  final int? workerPid;

  /// Checkout's captured host context.
  final Object? captured;

  _Span? _session;
  _Span? _feed;
  _Span? _pending;
  _Span? _turn;
  bool _dumpTurn = false;

  Object? get _span => (_turn ?? _pending ?? _feed ?? _session)?.handle;

  /// A snapshot's entry context with the innermost suspension span current.
  Object? context(Object? entry) => bridge.contextWithSpan(entry, _span);

  /// The one callback invoker used for functions, lookups and OS handlers.
  R invoke<R>(R Function() body) => bridge.invoke(context(captured), body);

  /// Reset, Shutdown and death close every open span, innermost first.
  void close() {
    _endFeed();
    _end(_session);
    _session = null;
  }

  _Span _open(String name, TelemetryAttributes attributes, {Object? parent}) =>
      _Span(bridge.start(name, parent ?? context(captured), attributes.values));

  void _end(_Span? span) {
    if (span != null) bridge.end(span.handle, span.attributes.values);
  }

  void _endFeed() {
    _end(_turn);
    _turn = null;
    _end(_pending);
    _pending = null;
    _end(_feed);
    _feed = null;
  }

  void _answer(String key, Rendered value) {
    final pending = _pending;
    _pending = null;
    pending?.attributes.add(key, value);
    _end(pending);
  }

  void _log(
    String body,
    TelemetryAttributes attributes, {
    bool error = false,
    Object? span,
  }) => bridge.log(
    span ?? _span,
    error ? 'ERROR' : 'INFO',
    body,
    attributes.values,
  );
}

final class _Span {
  _Span(this.handle);
  final Object? handle;
  final attributes = TelemetryAttributes();
  int? eagerCallId;
}
