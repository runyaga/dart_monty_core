/// Session snapshots and host-call answers.
library;

import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:meta/meta.dart';

/// The completion or current suspension reached by a feed.
///
/// A suspension resumes once. Manual resume validates its answer before it
/// spends the snapshot, so a refused value, type, or exception leaves it
/// reusable. An answer over 256 MiB spends the snapshot and leaves the worker
/// suspended until session close. Automatic resume spends first. A rethrown
/// host-side failure finishes the session, while a host throw becomes a
/// sandbox exception and leaves the session usable.
sealed class MontySnapshot {
  const MontySnapshot();
}

/// Where a suspension is in the source: upstream's `SourceRange`.
@immutable
final class SourceRange {
  /// Creates a source range with byte offsets.
  ///
  /// Each offset must fit 0 through 2^32 - 1 or the constructor throws
  /// [ArgumentError]. Reversed and past-end ranges are accepted, and
  /// [filename] remains unchanged.
  SourceRange({
    required this.filename,
    required this.start,
    required this.end,
  }) {
    _checkOffset(start, 'start');
    _checkOffset(end, 'end');
  }

  const SourceRange._unknown() : filename = '', start = 0, end = 0;

  /// The per-feed source name reported by the worker.
  ///
  /// Typical values are `<python-input-N>` and `<string>`. The session script
  /// name is separate and never appears here.
  final String filename;

  /// The inclusive UTF-8 byte offset.
  final int start;

  /// The exclusive UTF-8 byte offset.
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

  /// The value without conversion. Use [MontyValue.fromDart] for Dart data.
  final MontyValue value;

  @override
  bool operator ==(Object other) =>
      other is ExternalReturnValue && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A Python exception returned by the host for one call.
///
/// Manual resume accepts only exception type names known upstream. An unknown
/// type throws [ArgumentError] before spending the snapshot. The same value
/// thrown by live host code becomes plain Python `Exception` with that
/// validation error as its text.
///
/// Only `json.JSONDecodeError` sends structured attributes. It requires
/// string `msg` and `doc` values plus non-negative integer `pos`, `lineno`,
/// and `colno` values. A missing or mistyped value drops the payload while
/// preserving type and message. A document over 64 KiB is omitted while the
/// remaining payload stays present.
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

  /// The exception attributes supplied by the host.
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

  /// Decodes the last expression on every read.
  ///
  /// An arena value that cannot be built throws [FormatException] from this
  /// getter rather than from the completed turn.
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

  /// Answers a call snapshot through the feed's host side.
  Future<MontySnapshot> resumeCallAuto(FunctionSnapshot snapshot);

  /// Answers [snapshot]'s lookup with [value], or as undefined when null.
  Future<MontySnapshot> resumeLookup(
    NameLookupSnapshot snapshot,
    MontyValue? value,
  );

  /// Answers a lookup snapshot through the feed's host side.
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

/// Internal state shared by the exported suspension kinds.
///
/// Callers name the concrete kind they can answer. The shared supertype stays
/// unexported.
sealed class SuspendedSnapshot extends MontySnapshot {
  SuspendedSnapshot._(SnapshotDriver driver, this.position, this.scriptName)
    : _driver = driver;

  /// Where the suspending expression is in the source.
  final SourceRange position;

  /// The configured or restored session script name.
  ///
  /// Source positions use the worker's separate per-feed filename.
  final String scriptName;

  final SnapshotDriver _driver;

  bool _isSpent = false;
  Object? _capturedTraceContext;

  /// Returns the trace context captured for this suspension, or null without a
  /// telemetry adapter.
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

  /// The host-object receiver identifier for a method call.
  ///
  /// [resume] answers directly and ignores this identifier. [resumeAuto]
  /// dispatches through the registered host object. A restored dump starts
  /// without registrations, so automatic resume raises sandbox `RuntimeError`
  /// until the object is registered again.
  final String? objectId;

  final List<MontyValue> Function() _arguments;
  final Map<String, MontyValue> Function() _keywords;
  List<MontyValue>? _args;
  Map<String, MontyValue>? _kwargs;

  /// The positional arguments, decoded on first use.
  ///
  /// The first invalid value throws [FormatException] from this getter.
  List<MontyValue> get args => _args ??= List.unmodifiable(_arguments());

  /// The keyword arguments, decoded on first use.
  ///
  /// Every read returns the same mutable map. Changes do not affect arguments
  /// passed by [resumeAuto]. Invalid values fail like [args].
  Map<String, MontyValue> get kwargs => _kwargs ??= Map.of(_keywords());

  /// Answers the call with [result] and runs to the next suspension or the
  /// end. An [ExternalFuture] leaves the call pending, to be settled
  /// through a [FutureSnapshot].
  Future<MontySnapshot> resume(ExternalResult result) =>
      _driver.resumeCall(this, result);

  /// Answers an OS call with upstream's unhandled-call default.
  ///
  /// A host-function or method-call snapshot throws [StateError] and remains
  /// unused.
  Future<MontySnapshot> resumeNotHandled() => _driver.resumeNotHandled(this);

  /// Answers the call through the feed's host side and resumes the feed.
  ///
  /// An OS call reaches the feed's mounts, then its OS handler. A method call
  /// with [objectId] reaches its registered host object. A plain call reaches
  /// the feed's host functions. System sleep calls follow the OS route without
  /// a session-side wait.
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

  /// The host-object receiver identifier for a lazy attribute lookup.
  ///
  /// [resume] binds directly and ignores this identifier. [resumeAuto] reads
  /// from the registered host object. After dump restoration without a new
  /// registration, automatic resume leaves the attribute undefined.
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
