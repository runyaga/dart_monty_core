/// Step-by-step driving of a session: what `feedStart` and each resume reach,
/// and the answers a host gives to a call.
///
/// The package exports the snapshot family ([MontySnapshot], [MontyComplete],
/// [FunctionSnapshot], [FutureSnapshot], [NameLookupSnapshot]), the answers
/// a host gives ([ExternalResult], [ExternalReturnValue],
/// [ExternalSettledResult], [ExternalFuture]), [ExternalException] and
/// [SourceRange]; the rest of this library is internal.
library;

import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:meta/meta.dart';

/// What `feedStart` or a resume reached: the run's completion, or a
/// suspension the host answers by resuming it (upstream's `AsyncSnapshot`).
///
/// A suspension is resumed at most once: a second resume throws
/// [StateError]. A resume's answer is checked before the snapshot is spent,
/// so a refused answer — an [ArgumentError] for a value Python cannot
/// build or an exception type upstream does not know, a `MontyRuntimeError`
/// for one Python refuses — leaves it resumable. An answer whose request
/// frame is over the limit (256 MiB) is refused only at the send, after the
/// snapshot is spent: the resume throws `MontyRuntimeError`, the suspension
/// stays pending, every later feed throws [StateError], and only closing
/// the session recovers the worker. While a suspension is unanswered the
/// session refuses a new feed.
sealed class MontySnapshot {
  const MontySnapshot();
}

/// Where a suspension is in the source: upstream's `SourceRange`.
@immutable
final class SourceRange {
  /// A range of [filename] from byte [start] to byte [end] (exclusive), as
  /// upstream's keyword-only constructor builds one.
  ///
  /// Throws [ArgumentError] when [start] or [end] is outside 0..2^32-1, as
  /// upstream's constructor takes `u32`s. A reversed range, or one past the
  /// end of its source, is accepted, as upstream accepts it. [filename] is
  /// kept as given; only a position decoded from a worker is cut.
  SourceRange({
    required this.filename,
    required this.start,
    required this.end,
  }) {
    _checkOffset(start, 'start');
    _checkOffset(end, 'end');
  }

  const SourceRange._unknown() : filename = '', start = 0, end = 0;

  /// The source the range is in, named as a traceback frame names it:
  /// `<python-input-N>` for the session's N-th feed, `<string>` inside an
  /// `eval()` or `exec()` string. That name is the worker's, generated per
  /// feed — not the session's `scriptName`, which is another name entirely
  /// and never appears in a position: snapshots, dumps and telemetry report
  /// it instead ([SuspendedSnapshot.scriptName]).
  final String filename;

  /// Where the range starts: the UTF-8 byte offset of its first byte.
  final int start;

  /// Where the range ends: the UTF-8 byte offset just past its last byte.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is SourceRange &&
      other.filename == filename &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(filename, start, end);

  /// Upstream's repr: the file name as it is, between single quotes.
  @override
  String toString() =>
      "SourceRange(filename='$filename', start=$start, end=$end)";
}

/// The range a worker that sent no position reports: an empty file name and
/// an empty range at offset 0 (upstream `SourceRange::unknown`). Not
/// exported.
const SourceRange unknownSourceRange = SourceRange._unknown();

/// The largest offset a [SourceRange] holds: `u32::MAX`.
const int _maxOffset = 0xFFFFFFFF;

void _checkOffset(int offset, String name) {
  if (offset < 0 || offset > _maxOffset) {
    throw RangeError.range(offset, 0, _maxOffset, name);
  }
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
///
/// Two are equal when their values are, as upstream's is a dict.
@immutable
final class ExternalReturnValue extends ExternalSettledResult {
  /// The call returned [value].
  const ExternalReturnValue(this.value);

  /// What the call returned: a [MontyValue], always — the constructor
  /// converts nothing. Convert a plain Dart value with
  /// [MontyValue.fromDart] yourself.
  final MontyValue value;

  @override
  bool operator ==(Object other) =>
      other is ExternalReturnValue && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// The call raised a Python exception of type [excType] with [message] and
/// [attributes].
///
/// [excType] must be one of upstream's exception type names; a resume that
/// carries another throws [ArgumentError] and leaves its snapshot unused.
/// Thrown from live host code (a host function, an OS handler, a coroutine)
/// instead, an unknown name raises plain Python `Exception` in the sandbox,
/// carrying that [ArgumentError]'s text.
///
/// The attributes are sent as upstream sends a live host exception's: only
/// a `json.JSONDecodeError`'s `msg`, `doc`, `pos`, `lineno` and `colno`
/// reach the sandbox; any other type's stay here. All five must be there
/// and of their kinds — `msg` and `doc` a `str` with a UTF-8 form, `pos`,
/// `lineno` and `colno` an `int` from 0 to 2^64 - 1 — or the payload is
/// dropped, leaving the exception its type and message alone; a `doc`
/// over 64 KiB of UTF-8 is left out while the rest is kept.
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
  /// `pos`. Only that type's reach the sandbox, and only when all five are
  /// there and of their kinds; a dropped payload leaves the exception its
  /// type and message.
  final Map<String, MontyValue> attributes;

  @override
  bool operator ==(Object other) =>
      other is ExternalException &&
      other.excType == excType &&
      other.message == message &&
      _sameAttributes(_byName(other.attributes), _byName(attributes));

  @override
  int get hashCode {
    var h = 0;
    for (final MapEntry(:key, :value) in _byName(attributes).entries) {
      h = (h + Object.hash(key, value)) & 0x7fffffff;
    }

    return Object.hash(excType, message, h);
  }

  @override
  String toString() =>
      'ExternalException($excType${message == null ? '' : ', $message'})';
}

/// [attributes] as a plain map keyed by string value: a map's own lookup
/// rules (a custom comparator, identity) play no part in equality or the
/// hash.
Map<String, MontyValue> _byName(Map<String, MontyValue> attributes) => {
  for (final MapEntry(:key, :value) in attributes.entries) key: value,
};

bool _sameAttributes(Map<String, MontyValue> a, Map<String, MontyValue> b) =>
    a.length == b.length &&
    a.entries.every((e) => b.containsKey(e.key) && b[e.key] == e.value);

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
    throw unknownExcType(excType);
  }
}

/// The [ArgumentError] for an [ExternalException] naming [excType], which is
/// not one of upstream's exception types (upstream raises `TypeError`
/// "Unknown exception type").
ArgumentError unknownExcType(String excType) => ArgumentError.value(
  excType,
  'excType',
  "Unknown exception type: '$excType'",
);

/// The run completed with [output].
///
/// As upstream's, [output] is converted on each access: every read gives a
/// value of its own (a fresh list, say), and a failure to convert is thrown
/// by the read. Two completions are equal only when identical.
final class MontyComplete extends MontySnapshot {
  /// The run completed with the value its argument gives on each read.
  const MontyComplete._(this._decode);

  final MontyValue Function() _decode;

  /// The value of the snippet's last expression; `None` for a statement.
  ///
  /// Built on each read: a value the worker's arena cannot build throws
  /// `FormatException` from the read, never the turn that completed it.
  MontyValue get output => _decode();

  /// Upstream's repr, with the value's own [toString] for its repr.
  @override
  String toString() => 'MontyComplete(output=$output)';
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

  /// Answers [snapshot]'s call through the feed's host side: an OS call
  /// through the feed's mounts first and then the OS handler, a method
  /// call ([FunctionSnapshot.objectId]) through the host object registered
  /// under its id, a plain call through the feed's host functions.
  Future<MontySnapshot> resumeCallAuto(FunctionSnapshot snapshot);

  /// Answers [snapshot]'s lookup with [value], or as undefined when null.
  Future<MontySnapshot> resumeLookup(
    NameLookupSnapshot snapshot,
    MontyValue? value,
  );

  /// Answers [snapshot]'s lookup from the feed's host functions, or, for a
  /// lazy attribute ([NameLookupSnapshot.objectId]), through the host
  /// object registered under its id.
  Future<MontySnapshot> resumeLookupAuto(NameLookupSnapshot snapshot);

  /// Settles some or all of [snapshot]'s pending futures with [results].
  Future<MontySnapshot> resumeFutures(
    FutureSnapshot snapshot,
    Map<int, ExternalSettledResult> results,
  );

  /// Settles [snapshot]'s pending futures as the feed's host coroutines
  /// finish.
  Future<MontySnapshot> resumeFuturesAuto(FutureSnapshot snapshot);

  /// The session suspended at [snapshot], as the worker's opaque bytes.
  Future<Uint8List> dumpSnapshot(SuspendedSnapshot snapshot);
}

/// A suspension: the state shared by the three kinds.
sealed class SuspendedSnapshot extends MontySnapshot {
  SuspendedSnapshot._(SnapshotDriver driver, this.position, this.scriptName)
    : _driver = driver;

  /// Where the suspending expression is in the source.
  final SourceRange position;

  /// The session's script name: the one `checkout` configured, or a
  /// restored dump's. It names the session — snapshots, dumps and telemetry
  /// report it — never a feed's source, which positions and traceback
  /// frames name `<python-input-N>` ([SourceRange.filename]).
  final String scriptName;

  final SnapshotDriver _driver;

  bool _isSpent = false;
  Object? _capturedTraceContext;

  /// Context captured at feed/load entry, with the suspension's span current.
  /// Returns null without an installed telemetry adapter (D-087).
  /// Throws [StateError] after this snapshot has been resumed.
  Object? traceContext() {
    if (_isSpent) throw StateError('snapshot has already been resumed');

    return _capturedTraceContext;
  }

  /// The session suspended here, as opaque bytes that the session's
  /// `loadSnapshot` restores, in this session's worker or another
  /// (upstream's `dump`). The snapshot stays unspent.
  ///
  /// Throws [StateError] once the snapshot has been resumed, and once the
  /// session is finished.
  Future<Uint8List> dump() => _driver.dumpSnapshot(this);

  void _spend() {
    if (_isSpent) throw StateError('snapshot has already been resumed');
    _isSpent = true;
  }
}

/// Suspended on a host function call or, when [isOsFunction], an OS call
/// (upstream's `AsyncFunctionSnapshot`).
final class FunctionSnapshot extends SuspendedSnapshot {
  /// A suspension on the call [callId] to [functionName].
  FunctionSnapshot._(
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
       _keywords = keywords,
       super._();

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
  /// plain call. The name is the method's, and [resumeAuto] dispatches the
  /// call to the host object the session registered under that id; [resume]
  /// answers the call directly, whatever the id. A dump restored into a
  /// fresh session registers nothing under it, so there [resumeAuto] raises
  /// `RuntimeError` in the sandbox and only [resume] answers.
  final String? objectId;

  final List<MontyValue> Function() _arguments;
  final Map<String, MontyValue> Function() _keywords;
  List<MontyValue>? _args;
  Map<String, MontyValue>? _kwargs;

  /// The positional arguments, read on first use: a value the worker's
  /// arena cannot build throws `FormatException` from that first read (the
  /// frame's arrival checked only its structure), and a `StateError` is an
  /// internal inconsistency, not the worker's.
  List<MontyValue> get args => _args ??= List.unmodifiable(_arguments());

  /// The keyword arguments, in order, read on first use: the same mutable
  /// map on every read, as upstream's dict, throwing as [args] does.
  /// Changing it changes no answer: [resumeAuto] calls with the arguments
  /// the worker sent.
  Map<String, MontyValue> get kwargs => _kwargs ??= Map.of(_keywords());

  /// Answers the call with [result] and runs to the next suspension or the
  /// end. An [ExternalFuture] leaves the call pending, to be settled
  /// through a [FutureSnapshot].
  Future<MontySnapshot> resume(ExternalResult result) =>
      _driver.resumeCall(this, result);

  /// Answers an OS call with upstream's default for an unhandled call:
  /// `PermissionError` naming the path for a filesystem call,
  /// `RuntimeError` for the rest. Throws [StateError], leaving the snapshot
  /// unused, for a host function call, a host object's method call included.
  Future<MontySnapshot> resumeNotHandled() => _driver.resumeNotHandled(this);

  /// Answers the call through the feed's host side, as `feedRun` answers
  /// it, and runs on: an OS call reaches the feed's mount table first and
  /// then the `os` handler; a method call ([objectId] set) reaches the host
  /// object the session registered under that id; a plain call reaches the
  /// feed's host functions. A system sleep is not waited here as `feedRun`
  /// waits it: `system.sleep` and `system.async_sleep` reach the mounts and
  /// the OS handler like any other call, for the host to wait, decline or
  /// raise.
  Future<MontySnapshot> resumeAuto() => _driver.resumeCallAuto(this);
}

/// Suspended on a name the sandbox could not resolve (upstream's
/// `AsyncNameLookupSnapshot`).
final class NameLookupSnapshot extends SuspendedSnapshot {
  /// A suspension on the lookup of [variableName].
  NameLookupSnapshot._(
    super.driver,
    super.position,
    super.scriptName, {
    required this.variableName,
    this.objectId,
  }) : super._();

  /// The name looked up.
  final String variableName;

  /// The receiver's id for a lazy attribute of a host object; null for a
  /// plain name. [resumeAuto] reads the attribute through the host object
  /// the session registered under that id; [resume] binds the name
  /// directly, whatever the id. A dump restored into a fresh session
  /// registers nothing under it, so there [resumeAuto] leaves the attribute
  /// undefined and only [resume] answers.
  final String? objectId;

  /// Binds the name to [value] and runs on (`MontyNone` binds Python
  /// `None`); with no value the name is undefined, and the sandbox raises
  /// `NameError`, or `AttributeError` for a lazy attribute.
  Future<MontySnapshot> resume({MontyValue? value}) =>
      _driver.resumeLookup(this, value);

  /// Resolves the name as `feedRun` would, and runs on: a plain name from
  /// the feed's host functions, a lazy attribute ([objectId] set) through
  /// the host object the session registered under that id. The host
  /// object's lookup may raise: an `AttributeError` leaves the attribute
  /// undefined, any other exception is raised in the sandbox.
  Future<MontySnapshot> resumeAuto() => _driver.resumeLookupAuto(this);
}

/// Every sandbox task is blocked on pending futures (upstream's
/// `AsyncFutureSnapshot`).
final class FutureSnapshot extends SuspendedSnapshot {
  /// A suspension on the futures [pendingCallIds].
  FutureSnapshot._(
    super.driver,
    super.position,
    super.scriptName, {
    required List<int> pendingCallIds,
  }) : pendingCallIds = List.unmodifiable(pendingCallIds),
       super._();

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

/// The snapshot factories. Internal: the public show list leaves them out,
/// so only the session builds snapshots.
abstract final class Snapshots {
  /// A completed run whose output [output] gives on each read.
  static MontyComplete complete(MontyValue Function() output) =>
      MontyComplete._(output);

  /// A suspension on a host function or OS call.
  static FunctionSnapshot function(
    SnapshotDriver driver,
    SourceRange position,
    String scriptName,
    FunctionCallParts call,
  ) => FunctionSnapshot._(
    driver,
    position,
    scriptName,
    functionName: call.functionName,
    callId: call.callId,
    isOsFunction: call.isOsFunction,
    allowEagerAwait: call.allowEagerAwait,
    arguments: call.arguments,
    keywords: call.keywords,
    objectId: call.objectId,
  );

  /// A suspension on a name lookup.
  static NameLookupSnapshot nameLookup(
    SnapshotDriver driver,
    SourceRange position,
    String scriptName, {
    required String variableName,
    String? objectId,
  }) => NameLookupSnapshot._(
    driver,
    position,
    scriptName,
    variableName: variableName,
    objectId: objectId,
  );

  /// A suspension on pending futures.
  static FutureSnapshot futures(
    SnapshotDriver driver,
    SourceRange position,
    String scriptName, {
    required List<int> pendingCallIds,
  }) => FutureSnapshot._(
    driver,
    position,
    scriptName,
    pendingCallIds: pendingCallIds,
  );
}

/// What [Snapshots.function] needs to know about a call. Internal.
typedef FunctionCallParts = ({
  String functionName,
  int callId,
  bool isOsFunction,
  bool allowEagerAwait,
  List<MontyValue> Function() arguments,
  Map<String, MontyValue> Function() keywords,
  String? objectId,
});

/// [SuspendedSnapshot]'s internal members: the public show list leaves this
/// extension out.
extension SuspendedSnapshotInternal on SuspendedSnapshot {
  /// Sets the context once, as the driver creates this suspension.
  set capturedTraceContext(Object? value) => _capturedTraceContext = value;

  /// Whether a resume has taken this snapshot.
  bool get isSpent => _isSpent;

  /// Marks the snapshot used, or throws [StateError] if it already was.
  void spend() => _spend();
}
