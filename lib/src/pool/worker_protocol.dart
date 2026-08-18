/// The typed host↔worker protocol.
///
/// The frames on the wire are JSON objects, so `Map<String, Object?>` is the
/// honest type of a *decoded frame* — that is what `json.decode` produces and
/// there is nothing more precise to say about it. But it is a terrible type for
/// a **caller** to hold: `reply['value']` is a lookup that compiles whatever
/// you spell, returns `Object?`, and pushes every cast to a call site that has
/// no idea what shape it is looking at.
///
/// So the untyped map stops here. Above this file the protocol is a pair of
/// sealed hierarchies, matched with patterns: adding a request or a reply
/// variant turns every incomplete `switch` into a compile error instead of a
/// runtime surprise, which is the same reasoning that made
/// `WireJson` a nominal type rather than a `String`
/// (`lib/src/platform/wire_json.dart`).
///
/// Backend-neutral by construction — pure Dart, no `dart:io`, no `dart:ffi`,
/// no JS interop. The native channel frames these over a pipe and the web
/// channel posts them to a Worker; both speak the same types, so the pool above
/// them is written once for FFI, dart2js and dart2wasm alike.
library;

import 'package:dart_monty_core/src/platform/monty_limits.dart';

/// Something the host asks a worker to do.
sealed class WorkerRequest {
  /// Encodes this request as a frame payload.
  ///
  /// The `id` is added by the channel, not here: correlation is the channel's
  /// job, and a request that carried its own id could be sent twice with the
  /// same one.
  Map<String, Object?> toFrame();
}

/// An empty round trip, used to measure the channel itself.
final class PingRequest implements WorkerRequest {
  /// Creates a [PingRequest].
  const PingRequest();

  @override
  Map<String, Object?> toFrame() => const {'op': 'ping'};
}

/// Creates the worker's REPL session.
final class CreateSessionRequest implements WorkerRequest {
  /// Creates a [CreateSessionRequest].
  const CreateSessionRequest({this.scriptName, this.limits});

  /// Filename used in tracebacks, or null for the engine default.
  final String? scriptName;

  /// Session-scoped resource limits, or null for an unbounded session.
  final MontyLimits? limits;

  @override
  Map<String, Object?> toFrame() => {
    'op': 'create',
    'scriptName': ?scriptName,
    'limits': ?limits?.toJson(),
  };
}

/// Feeds Python and runs it to completion.
final class FeedRunRequest implements WorkerRequest {
  /// Creates a [FeedRunRequest] for [code].
  const FeedRunRequest(this.code);

  /// The Python source to run.
  final String code;

  @override
  Map<String, Object?> toFrame() => {'op': 'feedRun', 'code': code};
}

/// Disposes the session but leaves the worker running.
final class DisposeSessionRequest implements WorkerRequest {
  /// Creates a [DisposeSessionRequest].
  const DisposeSessionRequest();

  @override
  Map<String, Object?> toFrame() => const {'op': 'dispose'};
}

/// Asks the worker to dispose its session and exit.
final class ShutdownRequest implements WorkerRequest {
  /// Creates a [ShutdownRequest].
  const ShutdownRequest();

  @override
  Map<String, Object?> toFrame() => const {'op': 'shutdown'};
}

/// Parses a request frame on the worker side.
///
/// Returns null for an unrecognised `op` so the worker can answer with a
/// protocol failure rather than dying — an unknown op is the far end being
/// wrong, and killing the worker for it would turn a version skew into an
/// outage.
WorkerRequest? parseWorkerRequest(Map<String, Object?> frame) =>
    switch (frame['op']) {
      'ping' => const PingRequest(),
      'create' => CreateSessionRequest(
        scriptName: frame['scriptName'] as String?,
        limits: switch (frame['limits']) {
          final Map<String, Object?> json => MontyLimits.fromJson(json),
          _ => null,
        },
      ),
      'feedRun' => switch (frame['code']) {
        final String code => FeedRunRequest(code),
        _ => null,
      },
      'dispose' => const DisposeSessionRequest(),
      'shutdown' => const ShutdownRequest(),
      _ => null,
    };

/// What a worker sends back for one request.
sealed class WorkerReply {
  /// Encodes this reply as a frame payload.
  Map<String, Object?> toFrame();
}

/// The request succeeded and carried no result.
final class WorkerAck implements WorkerReply {
  /// Creates a [WorkerAck].
  const WorkerAck();

  @override
  Map<String, Object?> toFrame() => const {'kind': 'ack'};
}

/// A completed `feedRun`.
///
/// [pythonError] being non-null is **not** a worker failure: the interpreter
/// raised, the session is still healthy, and the pool must not recycle the
/// worker for it. Only a dead process is a worker failure. Keeping the two in
/// one type, distinguished by a field rather than by a class, is deliberate —
/// they are the same event from the channel's point of view.
final class WorkerRunResult implements WorkerReply {
  /// Creates a [WorkerRunResult].
  const WorkerRunResult({
    required this.value,
    this.pythonError,
    this.printOutput,
  });

  /// The `toString()` of the returned `MontyValue`.
  ///
  /// A rendered string rather than a decoded value because this is the M1
  /// spike: proxying values properly means routing them through
  /// `MontyValue.encodeForWire`, which is the M2 `ReplBindings` proxy's job.
  /// Naming it `value` while it holds a rendering would be the kind of quiet
  /// lie the wire work exists to prevent, so it is documented here instead.
  final String value;

  /// The rendered Python exception, when the program raised.
  final String? pythonError;

  /// Captured `print()` output, when there was any.
  final String? printOutput;

  @override
  Map<String, Object?> toFrame() => {
    'kind': 'run',
    'value': value,
    'pythonError': ?pythonError,
    'printOutput': ?printOutput,
  };
}

/// The worker caught something while serving the request.
///
/// The session may or may not be usable afterwards; the host decides. What it
/// is NOT is a dead worker — that arrives as a process exit, not as a frame.
final class WorkerFailure implements WorkerReply {
  /// Creates a [WorkerFailure] described by [error].
  const WorkerFailure(this.error);

  /// The rendered error.
  final String error;

  @override
  Map<String, Object?> toFrame() => {'kind': 'failure', 'error': error};
}

/// The host asked for something the worker does not implement.
final class WorkerUnsupported implements WorkerReply {
  /// Creates a [WorkerUnsupported] described by [detail].
  const WorkerUnsupported(this.detail);

  /// What was unsupported.
  final String detail;

  @override
  Map<String, Object?> toFrame() => {'kind': 'unsupported', 'detail': detail};
}

/// Parses a reply frame on the host side.
///
/// Returns null when the frame is not a reply this version understands, which
/// the channel treats as a protocol error — unlike an unknown *request*, an
/// unintelligible reply means the two ends disagree about the wire and there is
/// nothing safe to do with the session.
WorkerReply? parseWorkerReply(Map<String, Object?> frame) =>
    switch (frame['kind']) {
      'ack' => const WorkerAck(),
      'run' => switch (frame['value']) {
        final String value => WorkerRunResult(
          value: value,
          pythonError: frame['pythonError'] as String?,
          printOutput: frame['printOutput'] as String?,
        ),
        _ => null,
      },
      'failure' => switch (frame['error']) {
        final String error => WorkerFailure(error),
        _ => null,
      },
      'unsupported' => switch (frame['detail']) {
        final String detail => WorkerUnsupported(detail),
        _ => null,
      },
      _ => null,
    };
