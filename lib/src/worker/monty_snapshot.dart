/// Step-by-step driving of a session: what `feedStart` and each resume reach,
/// and the answers a host gives to a call.
///
/// The types become the public `MontySnapshot` family and the five
/// `ExternalResult` names at the cutover ([MontyComplete] then takes the
/// name `MontyComplete`); until then they are internal.
///
/// Internal to the package; nothing here is exported.
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
/// so a refused answer leaves it resumable. While a suspension is
/// unanswered the session refuses a new feed.
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

  /// The range a worker that sent no position reports: an empty file name
  /// and an empty range at offset 0 (upstream `SourceRange::unknown`).
  static const SourceRange unknown = SourceRange._unknown();

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

  /// Upstream's repr: the file name as it is, between single quotes.
  @override
  String toString() =>
      "SourceRange(filename='$filename', start=$start, end=$end)";
}

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

  /// What the call returned: a [MontyValue], or a host object's
  /// `ClassInstance` or `ClassType` wrapper. The wrappers join the
  /// [MontyValue] family at the cutover, and this narrows to it; any other
  /// object is refused by the resume with Python's `TypeError`.
  final Object value;

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

  /// Answers [snapshot]'s call from the feed's host functions or OS
  /// handler.
  Future<MontySnapshot> resumeCallAuto(FunctionSnapshot snapshot);

  /// Answers [snapshot]'s lookup with [value] (a [MontyValue] or a host
  /// object's wrapper), or as undefined when null.
  Future<MontySnapshot> resumeLookup(
    NameLookupSnapshot snapshot,
    Object? value,
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

  /// The session suspended at [snapshot], as the worker's opaque bytes.
  Future<Uint8List> dumpSnapshot(SuspendedSnapshot snapshot);
}

/// A suspension: the state shared by the three kinds.
sealed class SuspendedSnapshot extends MontySnapshot {
  SuspendedSnapshot._(SnapshotDriver driver, this.position, this.scriptName)
    : _driver = driver;

  /// Where the suspending expression is in the source.
  final SourceRange position;

  /// The session's script name.
  final String scriptName;

  final SnapshotDriver _driver;

  bool _isSpent = false;

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
  /// plain call.
  final String? objectId;

  final List<MontyValue> Function() _arguments;
  final Map<String, MontyValue> Function() _keywords;
  List<MontyValue>? _args;
  Map<String, MontyValue>? _kwargs;

  /// The positional arguments, read on first use. Throws if the worker sent
  /// a value this driver cannot read.
  List<MontyValue> get args => _args ??= List.unmodifiable(_arguments());

  /// The keyword arguments, in order, read on first use: the same mutable
  /// map on every read, as upstream's dict. Changing it changes no answer:
  /// [resumeAuto] calls with the arguments the worker sent.
  Map<String, MontyValue> get kwargs => _kwargs ??= Map.of(_keywords());

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
  /// plain name.
  final String? objectId;

  /// Binds the name to [value] (a [MontyValue] or a host object's wrapper)
  /// and runs on; with no value the name is undefined, and the sandbox
  /// raises `NameError`, or `AttributeError` for a lazy attribute.
  Future<MontySnapshot> resume({Object? value}) =>
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
  /// Whether a resume has taken this snapshot.
  bool get isSpent => _isSpent;

  /// Marks the snapshot used, or throws [StateError] if it already was.
  void spend() => _spend();
}
