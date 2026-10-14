/// Step-by-step driving of a session: what `feedStart` and each resume reach,
/// and the answers a host gives to a call.
///
/// The types become the public `MontySnapshot` family and the five
/// `ExternalResult` names at the cutover ([SessionComplete] then takes the
/// name `MontyComplete`); until then they are internal.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:meta/meta.dart';

/// What `feedStart` or a resume reached: the run's completion, or a
/// suspension the host answers by resuming it (upstream's `AsyncSnapshot`).
///
/// A suspension is resumed at most once: a second resume throws
/// [StateError]. A resume's answer is checked before the snapshot is spent,
/// so a refused answer leaves it resumable. While a suspension is
/// unanswered the session refuses a new feed.
sealed class MontySnapshot {
  const MontySnapshot();
}

/// Where a suspension is in the source: upstream's `SourceRange`.
@immutable
final class SourceRange {
  /// A range of [filename] from byte [start] to byte [end] (exclusive).
  const SourceRange(this.filename, this.start, this.end);

  /// The range a worker that sent no position reports: an empty file name
  /// and an empty range at offset 0 (upstream `SourceRange::unknown`).
  static const SourceRange unknown = SourceRange('', 0, 0);

  /// The source the range is in, named as a traceback frame names it:
  /// `<python-input-N>` for the session's N-th feed, `<string>` inside an
  /// `eval()` or `exec()` string.
  final String filename;

  /// The first byte, a UTF-8 offset into that source.
  final int start;

  /// The byte after the last one.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is SourceRange &&
      other.filename == filename &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(filename, start, end);

  @override
  String toString() => 'SourceRange($filename, $start, $end)';
}

/// A host's answer to a suspended call: upstream's `ExternalResult`.
sealed class ExternalResult {
  const ExternalResult();
}

/// An answer that settles the call: a value or an exception. The only kinds
/// a pending future may resolve to (upstream's `ExternalSettledResult`).
sealed class ExternalSettledResult extends ExternalResult {
  const ExternalSettledResult();
}

/// The call returned [value].
final class ExternalReturnValue extends ExternalSettledResult {
  /// The call returned [value].
  const ExternalReturnValue(this.value);

  /// What the call returned.
  final MontyValue value;
}

/// The call raised a Python exception of type [excType] with [message] and
/// [attributes].
///
/// [excType] must be one of upstream's exception type names; a resume that
/// carries another throws [ArgumentError] and leaves its snapshot unused.
///
/// The attributes are sent as upstream sends a live host exception's: only
/// a `json.JSONDecodeError`'s `msg`, `doc`, `pos`, `lineno` and `colno`
/// reach the sandbox; any other type's stay here.
@immutable
final class ExternalException extends ExternalSettledResult
    implements Exception {
  /// The call raised [excType] with [message] and [attributes].
  const ExternalException(
    this.excType, [
    this.message,
    this.attributes = const {},
  ]);

  /// The Python exception type, such as `ValueError`.
  final String excType;

  /// The exception's message, or none.
  final String? message;

  /// The exception's attributes by name, such as a `json.JSONDecodeError`'s
  /// `pos`.
  final Map<String, MontyValue> attributes;

  @override
  bool operator ==(Object other) =>
      other is ExternalException &&
      other.excType == excType &&
      other.message == message &&
      _sameAttributes(other.attributes, attributes);

  @override
  int get hashCode {
    var h = 0;
    for (final MapEntry(:key, :value) in attributes.entries) {
      h = (h + Object.hash(key, value)) & 0x7fffffff;
    }

    return Object.hash(excType, message, h);
  }

  @override
  String toString() =>
      'ExternalException($excType${message == null ? '' : ', $message'})';
}

/// Whether [a] and [b] hold equal values under equal keys, the keys compared
/// as strings: the maps' own lookup rules (a custom comparator) play no part,
/// as they play none in [ExternalException.hashCode].
bool _sameAttributes(Map<String, MontyValue> a, Map<String, MontyValue> b) {
  final left = {for (final MapEntry(:key, :value) in a.entries) key: value};
  final right = {for (final MapEntry(:key, :value) in b.entries) key: value};

  return left.length == right.length &&
      left.entries.every(
        (e) => right.containsKey(e.key) && right[e.key] == e.value,
      );
}

/// The call is asynchronous: the sandbox gets a pending future for it, to be
/// settled through a [FutureSnapshot] (upstream's `ExternalFuture`).
final class ExternalFuture extends ExternalResult {
  /// The call is asynchronous.
  const ExternalFuture();
}

/// Checks [result] as a resume carries it: an [ExternalException] must name
/// one of upstream's exception types.
void checkExternalResult(ExternalResult result) {
  if (result case ExternalException(
    :final excType,
  ) when !exceptionTypeNames.contains(excType)) {
    throw ArgumentError.value(
      excType,
      'excType',
      "Unknown exception type: '$excType'",
    );
  }
}

/// The run completed with [output] (the public `MontyComplete` at the
/// cutover).
final class SessionComplete extends MontySnapshot {
  /// The run completed with [output].
  const SessionComplete(this.output);

  /// The value of the snippet's last expression; `None` for a statement.
  final MontyValue output;
}

/// How a suspension is resumed: the session that owns it.
abstract interface class SnapshotDriver {
  /// Answers the call [snapshot] is suspended on with [result].
  Future<MontySnapshot> resumeCall(
    FunctionSnapshot snapshot,
    ExternalResult result,
  );

  /// Answers the OS call [snapshot] is suspended on with upstream's
  /// not-handled default.
  Future<MontySnapshot> resumeNotHandled(FunctionSnapshot snapshot);

  /// Answers [snapshot]'s call from the feed's host functions or OS
  /// handler.
  Future<MontySnapshot> resumeCallAuto(FunctionSnapshot snapshot);

  /// Answers [snapshot]'s lookup with [value], or as undefined when null.
  Future<MontySnapshot> resumeLookup(
    NameLookupSnapshot snapshot,
    MontyValue? value,
  );

  /// Answers [snapshot]'s lookup from the feed's host functions.
  Future<MontySnapshot> resumeLookupAuto(NameLookupSnapshot snapshot);

  /// Settles some or all of [snapshot]'s pending futures with [results].
  Future<MontySnapshot> resumeFutures(
    FutureSnapshot snapshot,
    Map<int, ExternalSettledResult> results,
  );

  /// Settles [snapshot]'s pending futures as the feed's host coroutines
  /// finish.
  Future<MontySnapshot> resumeFuturesAuto(FutureSnapshot snapshot);
}

/// A suspension: the state shared by the three kinds.
sealed class SuspendedSnapshot extends MontySnapshot {
  SuspendedSnapshot(SnapshotDriver driver, this.position, this.scriptName)
    : _driver = driver;

  /// Where the suspending expression is in the source.
  final SourceRange position;

  /// The session's script name.
  final String scriptName;

  final SnapshotDriver _driver;

  bool _isSpent = false;

  /// Whether a resume has taken this snapshot.
  bool get isSpent => _isSpent;

  /// Marks the snapshot used, or throws [StateError] if it already was.
  void spend() {
    if (_isSpent) throw StateError('snapshot has already been resumed');
    _isSpent = true;
  }
}

/// Suspended on a host function call or, when [isOsFunction], an OS call
/// (upstream's `AsyncFunctionSnapshot`).
final class FunctionSnapshot extends SuspendedSnapshot {
  /// A suspension on the call [callId] to [functionName].
  FunctionSnapshot(
    super.driver,
    super.position,
    super.scriptName, {
    required this.functionName,
    required this.callId,
    required this.isOsFunction,
    required this.allowEagerAwait,
    required List<MontyValue> Function() arguments,
    required Map<String, MontyValue> Function() keywords,
    this.objectId,
  }) : _arguments = arguments,
       _keywords = keywords;

  /// The called name: the host function's, or upstream's OS function name
  /// (`Path.read_text`, `os.getenv`, `system.sleep`, ...).
  final String functionName;

  /// The call's id, which a [FutureSnapshot] settles it by.
  final int callId;

  /// Whether this is an OS call.
  final bool isOsFunction;

  /// Whether the sandbox awaits the call with nothing else to run, so a
  /// coroutine answer may be awaited in place.
  final bool allowEagerAwait;

  /// The receiver's id for a method call on a host object; null for a
  /// plain call.
  final String? objectId;

  final List<MontyValue> Function() _arguments;
  final Map<String, MontyValue> Function() _keywords;
  List<MontyValue>? _args;
  Map<String, MontyValue>? _kwargs;

  /// The positional arguments, read on first use. Throws if the worker sent
  /// a value this driver cannot read.
  List<MontyValue> get args => _args ??= List.unmodifiable(_arguments());

  /// The keyword arguments, in order, read on first use.
  Map<String, MontyValue> get kwargs =>
      _kwargs ??= Map.unmodifiable(_keywords());

  /// Answers the call with [result] and runs to the next suspension or the
  /// end. An [ExternalFuture] leaves the call pending, to be settled
  /// through a [FutureSnapshot].
  Future<MontySnapshot> resume(ExternalResult result) =>
      _driver.resumeCall(this, result);

  /// Answers an OS call with upstream's default for an unhandled call:
  /// `PermissionError` naming the path for a filesystem call,
  /// `RuntimeError` for the rest. Throws [StateError], leaving the snapshot
  /// unused, for a host function call.
  Future<MontySnapshot> resumeNotHandled() => _driver.resumeNotHandled(this);

  /// Answers the call from the feed's host functions or OS handler, as
  /// `feedRun` would, and runs on.
  Future<MontySnapshot> resumeAuto() => _driver.resumeCallAuto(this);
}

/// Suspended on a name the sandbox could not resolve (upstream's
/// `AsyncNameLookupSnapshot`).
final class NameLookupSnapshot extends SuspendedSnapshot {
  /// A suspension on the lookup of [variableName].
  NameLookupSnapshot(
    super.driver,
    super.position,
    super.scriptName, {
    required this.variableName,
    this.objectId,
  });

  /// The name looked up.
  final String variableName;

  /// The receiver's id for a lazy attribute of a host object; null for a
  /// plain name.
  final String? objectId;

  /// Binds the name to [value] and runs on; with no value the name is
  /// undefined, and the sandbox raises `NameError`.
  Future<MontySnapshot> resume({MontyValue? value}) =>
      _driver.resumeLookup(this, value);

  /// Resolves the name from the feed's host functions, as `feedRun` would,
  /// and runs on.
  Future<MontySnapshot> resumeAuto() => _driver.resumeLookupAuto(this);
}

/// Every sandbox task is blocked on pending futures (upstream's
/// `AsyncFutureSnapshot`).
final class FutureSnapshot extends SuspendedSnapshot {
  /// A suspension on the futures [pendingCallIds].
  FutureSnapshot(
    super.driver,
    super.position,
    super.scriptName, {
    required List<int> pendingCallIds,
  }) : pendingCallIds = List.unmodifiable(pendingCallIds);

  /// The call ids whose futures are pending.
  final List<int> pendingCallIds;

  /// Settles some or all of the pending futures, by call id, and runs on;
  /// the ones left pending are reported again.
  Future<MontySnapshot> resume(Map<int, ExternalSettledResult> results) =>
      _driver.resumeFutures(this, results);

  /// Waits for one or more of the host coroutines earlier resumes started
  /// to finish, settles their futures and runs on. With none pending it
  /// ends the session (the worker is killed) and throws [StateError].
  Future<MontySnapshot> resumeAuto() => _driver.resumeFuturesAuto(this);
}
