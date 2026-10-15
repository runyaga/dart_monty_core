/// Upstream's error family for a session: [MontyError] and its four local
/// subclasses, [MontySyntaxError], [MontyRuntimeError], [MontyTypingError]
/// and [MontyCrashedError], and [Frame].
///
/// As upstream's binding splits its `MontyException`: every error has the
/// inner exception, [MontyError.exception]; syntax and runtime errors also
/// carry the traceback and `display()`; a typing error's `display()` is the
/// worker's rendering. `message` and `toString()` are upstream's `__str__`.
///
/// Upstream's errors cannot be constructed from Python, so these have no
/// public constructor: the session builds them from wire events through
/// the factory functions here ([raisedError], [typingError], [crashedError],
/// [protocolError]), which a fake session uses too.
///
/// Internal until the cutover exports the classes in place of today's
/// public errors; nothing here is exported.
library;

import 'package:dart_monty_core/src/platform/exception_attributes.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart'
    show PythonRefusal;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/raised_record.dart';

/// A failure of the sandbox: the one type to catch.
sealed class MontyError implements Exception {
  const MontyError._(this.message, this.exception);

  /// Upstream's `str()` of the error; see each subclass.
  final String message;

  /// The inner Python exception (upstream's `exception()`). Its message is
  /// `''` when the worker sent none.
  final MontyExceptionValue exception;

  @override
  String toString() => message;
}

/// Fed code did not parse. [message] is the parser's message alone.
final class MontySyntaxError extends MontyError {
  MontySyntaxError._(this._record)
    : traceback = _frames(_record),
      super._(_record.message ?? '', _exceptionOf(_record));

  /// The frames, outermost first.
  final List<Frame> traceback;

  final RaisedRecord _record;

  /// The error rendered in [format], as upstream's `display()`:
  /// `'traceback'` (the default), `'type-msg'` or `'msg'`. Any other
  /// [format] throws [ArgumentError] with upstream's text.
  String display([String format = 'traceback']) => _record.display(format);
}

/// Fed code raised an exception it did not catch: [message] is
/// `Type: message`, or `Type` when the message is absent or empty. Resource
/// limits, the suspension and sleep budgets and a memory-limit exit arrive
/// this way; the session survives each except the last.
final class MontyRuntimeError extends MontyError {
  MontyRuntimeError._(this._record)
    : traceback = _frames(_record),
      super._(_summary(_record), _exceptionOf(_record));

  /// The frames, outermost first.
  final List<Frame> traceback;

  final RaisedRecord _record;

  /// The error rendered in [format], as upstream's `display()`:
  /// `'traceback'` (the default), `'type-msg'` or `'msg'`. Any other
  /// [format] throws [ArgumentError] with upstream's text.
  String display([String format = 'traceback']) => _record.display(format);
}

/// The session's type check rejected a fed snippet, which did not run; the
/// session survives. [message] is the diagnostics as the worker rendered
/// them, in the session's `typeCheckFormat`.
final class MontyTypingError extends MontyError {
  const MontyTypingError._(String diagnostics)
    : super._(
        diagnostics,
        const MontyExceptionValue(excType: 'TypeError', message: ''),
      );

  /// The diagnostics, as upstream's `display()` (which takes no format).
  String display() => message;
}

/// The worker is gone, and the session with it: it died, was killed at a
/// deadline, or answered against the protocol. [message] says which.
final class MontyCrashedError extends MontyError {
  MontyCrashedError._(
    String message, {
    required this.cause,
    required this.timedOut,
    this.detail,
    this.exitCode,
    this.stderrTail,
    this.context,
  }) : super._(
         message,
         MontyExceptionValue(excType: 'RuntimeError', message: message),
       );

  /// Whether the worker was killed at a deadline: `requestTimeout`, or a
  /// duration backstop.
  final bool timedOut;

  /// The worker's exit code, when the OS reported one; null for a signal
  /// death, on the web, and for a worker killed at a deadline.
  int? get exitStatus {
    final code = exitCode;

    return timedOut || code == null || code < 0 ? null : code;
  }

  /// Why the worker stopped. Internal: upstream has only [message].
  final CrashCause cause;

  /// What the channel saw, before [message] framed it. Internal.
  final String? detail;

  /// The worker process's exit code on native, negative for a signal.
  /// Internal: [exitStatus] is upstream's.
  final int? exitCode;

  /// On native, the last 4 KiB or less of the worker's stderr. Internal.
  final String? stderrTail;

  /// What the parent was doing when it found the worker gone, for a
  /// vanished worker; null is [waitingForReply]. Internal.
  final String? context;
}

/// Why a worker stopped answering.
enum CrashCause {
  /// The worker's allocator refused an allocation over its hard limit and
  /// the worker exited with upstream's `OOM_EXIT_CODE` (65).
  outOfMemory,

  /// The worker sent a `FatalError` and exited: protocol version skew, a
  /// desynchronised request stream, or a panic.
  fatal,

  /// The worker ended without a `FatalError`: EOF, a torn frame, a signal
  /// such as a native stack overflow's abort, or a wasm trap.
  vanished,

  /// The parent killed it: a deadline, or a close during a turn.
  killed,

  /// The worker answered against the protocol (an event that cannot follow
  /// the request, a payload that does not decode); the parent discarded it.
  protocol,
}

/// One traceback frame, read-only, as upstream's `Frame`.
///
/// Lines and columns are 1-based. Upstream's `Frame` defines no equality,
/// so two frames are equal only when identical.
final class Frame {
  Frame._(TracebackFrame frame)
    : filename = frame.filename,
      line = frame.startLine,
      column = frame.startColumn,
      endLine = frame.endLine,
      endColumn = frame.endColumn,
      functionName = frame.frameName,
      sourceLine = frame.previewLine;

  /// The source the frame is in.
  final String filename;

  /// The line the span starts on.
  final int line;

  /// The column the span starts at.
  final int column;

  /// The line the span ends on.
  final int endLine;

  /// The column the span ends at.
  final int endColumn;

  /// The function's name, `'<module>'` at module level, as the worker
  /// reports it.
  final String? functionName;

  /// The source line, or for a span over several lines the dedented block.
  final String? sourceLine;

  /// Upstream's `str(frame)`: its `repr`, with the fields inserted as they
  /// are, unquoted and unescaped, and `<module>` for a frame with no name.
  @override
  String toString() =>
      "Frame(filename='$filename', line=$line, column=$column, "
      "function_name='${functionName ?? '<module>'}')";
}

/// The error an `Error` event's [raised] exception is: [MontySyntaxError]
/// for a `SyntaxError`, else [MontyRuntimeError].
///
/// Upstream's checks on the exception run first ([RaisedRecord.checked]);
/// one it fails is a protocol violation, returned as [MontyCrashedError].
MontyError raisedError(pb.RaisedException raised) {
  final RaisedRecord record;
  try {
    record = RaisedRecord.checked(raised);
  } on InvalidRaisedException catch (e) {
    return protocolError('invalid exception payload: ${e.detail}');
  }

  return recordError(record);
}

/// The error [record] is, unchecked: for an exception the parent made
/// itself, such as a memory-limit exit's `MemoryError`.
MontyError recordError(RaisedRecord record) => record.excType == 'SyntaxError'
    ? MontySyntaxError._(record)
    : MontyRuntimeError._(record);

/// The error a print collector's overflow is (upstream's
/// `check_print_collect_limit`): [MontyRuntimeError] with Python
/// `MemoryError` and upstream's text for a memory limit, [used] the bytes
/// the refused growth would have reached, and no traceback.
MontyRuntimeError memoryLimitError(int used, int limit) => MontyRuntimeError._(
  RaisedRecord(
    'MemoryError',
    'memory limit exceeded: $used bytes > $limit bytes',
    const [],
  ),
);

/// The error a host value the writer refused ([refusal]) is at the caller
/// of an input or a manual resume, as upstream's binding raises a
/// conversion failure there: [MontyRuntimeError] with the Python exception,
/// and no traceback.
MontyRuntimeError refusalError(PythonRefusal refusal) =>
    MontyRuntimeError._(RaisedRecord(refusal.excType, refusal.text, const []));

/// Runs [encode], which writes host values for an input or a manual resume,
/// throwing a [PythonRefusal] as its [refusalError]. The writer's other
/// refusals, of values Python cannot build, stay [ArgumentError]s.
T encodingInput<T>(T Function() encode) {
  try {
    return encode();
    // The writer's refusal is an ArgumentError for its own callers; this is
    // where it becomes upstream's error.
    // ignore: avoid_catching_errors
  } on PythonRefusal catch (refusal) {
    throw refusalError(refusal);
  }
}

/// The error a `TypingError` event's [diagnostics] are.
MontyTypingError typingError(String diagnostics) =>
    MontyTypingError._(diagnostics);

/// A dead or killed worker.
///
/// [detail] is what the channel saw, kept for diagnostics. The message is
/// upstream's `PoolError` text: `monty worker crashed: <detail>` for a
/// worker that announced its end (`FatalError`), and for one that vanished
/// `monty worker crashed while` what the parent was doing ([context],
/// [waitingForReply] by default), each with the exit status when known;
/// [detail] alone for a worker the parent killed.
MontyCrashedError crashedError(
  CrashCause cause, {
  String? detail,
  int? exitCode,
  String? stderrTail,
  bool timedOut = false,
  String? context,
}) {
  final status = switch (exitCode) {
    null => '',
    final code when code < 0 => ' (${_signal(-code)})',
    final code => ' (exit status: $code)',
  };
  final message = switch (cause) {
    CrashCause.killed => detail ?? 'monty worker killed',
    CrashCause.protocol => 'monty worker protocol error: $detail',
    // A worker that announced its end says why; one that vanished is
    // reported by what the parent was doing, as upstream's PoolError.
    CrashCause.fatal => 'monty worker crashed: ${detail ?? ''}$status',
    CrashCause.vanished || CrashCause.outOfMemory =>
      'monty worker crashed while ${context ?? waitingForReply}$status',
  };

  return MontyCrashedError._(
    message,
    cause: cause,
    timedOut: timedOut,
    detail: detail,
    exitCode: exitCode,
    stderrTail: stderrTail,
    context: context,
  );
}

/// Upstream's contexts for a worker that vanished: what the parent was
/// doing when it found the worker gone.
const String waitingForReply = 'waiting for a reply';

/// See [waitingForReply]: the request could not be written.
const String sendingRequest = 'sending a request';

/// See [waitingForReply]: an `AbortFeed` could not be written.
const String abortingFeed = 'aborting a feed';

/// [crash] found while the parent was [context] instead.
MontyCrashedError inContext(MontyCrashedError crash, String context) =>
    crashedError(
      crash.cause,
      detail: crash.detail,
      exitCode: crash.exitCode,
      stderrTail: crash.stderrTail,
      timedOut: crash.timedOut,
      context: context,
    );

/// A signal as Rust's `ExitStatus` shows it: `signal: 9 (SIGKILL)` for the
/// signals numbered alike on Linux and macOS, the number alone otherwise.
String _signal(int signal) {
  final name = _signalNames[signal];

  return name == null ? 'signal: $signal' : 'signal: $signal ($name)';
}

const Map<int, String> _signalNames = {
  1: 'SIGHUP',
  2: 'SIGINT',
  3: 'SIGQUIT',
  4: 'SIGILL',
  5: 'SIGTRAP',
  6: 'SIGABRT',
  8: 'SIGFPE',
  9: 'SIGKILL',
  11: 'SIGSEGV',
  13: 'SIGPIPE',
  14: 'SIGALRM',
  15: 'SIGTERM',
};

/// A worker that answered against the protocol: upstream's message,
/// `monty worker protocol error: <detail>`. The caller discards the worker.
MontyCrashedError protocolError(String detail) =>
    crashedError(CrashCause.protocol, detail: detail);

String _summary(RaisedRecord record) {
  final text = record.message;

  return text == null || text.isEmpty
      ? record.excType
      : '${record.excType}: $text';
}

/// The exception upstream's binding builds for [record]
/// (`exc_monty_to_py`): a Unicode or JSON decode error is rebuilt from its
/// payload, with the payload's attributes; without one of the right kind it
/// is a plain `ValueError`, as upstream's fallback is. Its rendering still
/// names the original type.
MontyExceptionValue _exceptionOf(RaisedRecord record) {
  final message = record.message ?? '';
  final type = record.excType;
  final kind = _payloadKinds[type];
  if (kind == null) return MontyExceptionValue(excType: type, message: message);
  final payload = record.payload;
  if (payload == null || payload.kind != kind) {
    return MontyExceptionValue(excType: 'ValueError', message: message);
  }

  return exceptionWithAttributes(
    excType: type,
    message: message,
    attributes: payload.attributes,
  );
}

/// The payload each type is rebuilt from: CPython's `UnicodeDecodeError`
/// takes a `bytes` object, `UnicodeEncodeError` a `str`.
const Map<String, PayloadKind> _payloadKinds = {
  'UnicodeDecodeError': PayloadKind.unicodeBytes,
  'UnicodeEncodeError': PayloadKind.unicodeStr,
  'json.JSONDecodeError': PayloadKind.json,
};

List<Frame> _frames(RaisedRecord record) =>
    List.unmodifiable(record.traceback.map(Frame._));
