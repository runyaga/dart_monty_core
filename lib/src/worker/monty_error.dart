/// Upstream's error family for a session: [MontyError] and its four local
/// subclasses, [MontySyntaxError], [MontyRuntimeError], [MontyTypingError]
/// and [MontyCrashedError], and [Frame].
///
/// As upstream's binding splits its `MontyException`: every error has the
/// inner exception, [MontyError.exception]; syntax and runtime errors also
/// carry the traceback and `display()`; a typing error's `display()` is the
/// worker's rendering. `toString()` is upstream's `__str__`, and the inner
/// exception's message is `exception.message`.
///
/// Upstream's errors cannot be constructed from Python, so these have no
/// public constructor. Sessions and fake sessions build them from wire events.
library;

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart'
    show PythonRefusal;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/raised_record.dart';

/// A failure of the sandbox: the one type to catch.
sealed class MontyError implements Exception {
  const MontyError._(this._message, this.exception);

  /// The inner Python exception (upstream's `exception()`). Its message is
  /// `''` when the worker sent none.
  final MontyExceptionValue exception;

  /// Upstream's `str()` of the error, which [toString] returns; see each
  /// subclass.
  final String _message;

  @override
  String toString() => _message;
}

/// Fed code did not parse. [toString] is the parser's message alone.
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

/// Fed code raised an exception it did not catch: [toString] is
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
/// session survives. [toString] is the diagnostics as the worker rendered
/// them, in the session's `typeCheckFormat`.
final class MontyTypingError extends MontyError {
  MontyTypingError._(String diagnostics)
    : super._(
        diagnostics,
        MontyExceptionValue('TypeError', ''),
      );

  /// The diagnostics, as upstream's `display()` (which takes no format).
  String display() => _message;
}

/// The worker is gone, and the session with it: it died, was killed at a
/// deadline, or answered against the protocol. [toString] says which.
final class MontyCrashedError extends MontyError {
  MontyCrashedError._(
    String message, {
    required CrashCause cause,
    required this.timedOut,
    String? detail,
    int? exitCode,
    String? stderrTail,
    String? context,
  }) : _cause = cause,
       _detail = detail,
       _exitCode = exitCode,
       _stderrTail = stderrTail,
       _context = context,
       super._(
         message,
         MontyExceptionValue('RuntimeError', message),
       );

  /// Whether the worker was killed at a deadline: `requestTimeout`, or a
  /// duration backstop.
  final bool timedOut;

  /// The worker's exit code, when the OS reported one; null for a signal
  /// death, on the web, and for a worker killed at a deadline.
  int? get exitStatus {
    final code = _exitCode;

    return timedOut || code == null || code < 0 ? null : code;
  }

  final CrashCause _cause;
  final String? _detail;
  final int? _exitCode;
  final String? _stderrTail;
  final String? _context;
}

/// [MontyCrashedError]'s internal members (pass-3 G2): upstream's error has
/// only its message, [MontyCrashedError.timedOut] and
/// [MontyCrashedError.exitStatus]. The public libraries' `show` lists leave
/// this extension out.
extension MontyCrashedErrorInternal on MontyCrashedError {
  /// Why the worker stopped.
  CrashCause get cause => _cause;

  /// What the channel saw, before the message framed it.
  String? get detail => _detail;

  /// The worker process's exit code on native, negative for a signal.
  int? get exitCode => _exitCode;

  /// On native, the last 4 KiB or less of the worker's stderr.
  String? get stderrTail => _stderrTail;

  /// What the parent was doing when it found the worker gone, for a
  /// vanished worker; null is [waitingForReply].
  String? get context => _context;
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

  /// No worker could be started: none was found, or its process could not
  /// be launched (upstream's `PoolError::Spawn`).
  spawn,
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

/// Builds a syntax error for `SyntaxError` and a runtime error otherwise.
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

/// Builds a typing error from worker diagnostics.
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

  return MontyCrashedError._(
    _crashMessage(cause, detail, status, context),
    cause: cause,
    timedOut: timedOut,
    detail: detail,
    exitCode: exitCode,
    stderrTail: stderrTail,
    context: context,
  );
}

/// Upstream's `PoolError` text for a crash of [cause]; [status] is the
/// exit status, already formatted.
String _crashMessage(
  CrashCause cause,
  String? detail,
  String status,
  String? context,
) => switch (cause) {
  CrashCause.killed => detail ?? 'monty worker killed',
  CrashCause.protocol => 'monty worker protocol error: $detail',
  CrashCause.spawn => 'failed to spawn monty worker: $detail',
  // A worker that announced its end says why; one that vanished is
  // reported by what the parent was doing, as upstream's PoolError.
  CrashCause.fatal => 'monty worker crashed: ${detail ?? ''}$status',
  CrashCause.vanished || CrashCause.outOfMemory =>
    'monty worker crashed while ${context ?? waitingForReply}$status',
};

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

/// A worker that could not be started: upstream's message,
/// `failed to spawn monty worker: <detail>` (monty-pool 1.1.0 lib.rs:255).
MontyCrashedError spawnError(String detail) =>
    crashedError(CrashCause.spawn, detail: detail);

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

/// Rebuilds the exception value carried by a raised record.
MontyExceptionValue _exceptionOf(RaisedRecord record) {
  final message = record.message ?? '';
  final type = record.excType;
  final kind = _payloadKinds[type];
  if (kind == null) return MontyExceptionValue(type, message);
  final payload = record.payload;
  if (payload == null || payload.kind != kind) {
    return MontyExceptionValue('ValueError', message);
  }

  return MontyExceptionValue(type, message, payload.attributes);
}

/// The payload each type is rebuilt from: CPython's `UnicodeDecodeError`
/// takes a `bytes` object, `UnicodeEncodeError` a `str`; since Python 3.14
/// `tomllib.TOMLDecodeError` defines the same five attributes as
/// `json.JSONDecodeError`, so both travel as the JSON payload (upstream's
/// `exc_monty_to_py`).
const Map<String, PayloadKind> _payloadKinds = {
  'UnicodeDecodeError': PayloadKind.unicodeBytes,
  'UnicodeEncodeError': PayloadKind.unicodeStr,
  'json.JSONDecodeError': PayloadKind.json,
  'tomllib.TOMLDecodeError': PayloadKind.json,
};

List<Frame> _frames(RaisedRecord record) =>
    List.unmodifiable(record.traceback.map(Frame._));
