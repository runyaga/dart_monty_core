/// Upstream's print collectors, [CollectStreams] and [CollectString]
/// (`monty-python/src/print_target.rs` at v1.1.0): pass one as a feed's
/// print callback to keep what the sandbox prints, under a byte cap. One
/// file holds both, named after the first.
///
/// Upstream's print target handles its collectors itself; a Dart print
/// callback is a function, so each collector is callable instead. Its
/// [CollectStreams.call] is what the session calls for each printed
/// fragment, and may be called directly too.
///
/// Internal until the cutover exports both; nothing here is exported.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/python_rules.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';

/// Upstream's `DEFAULT_MAX_PRINT_COLLECT_BYTES`: each collector's default
/// cap.
const int defaultMaxPrintCollectBytes = 10 << 20;

/// Upstream's `COLLECT_STREAMS_ENTRY_OVERHEAD`: the bytes a [CollectStreams]
/// charges for each entry beyond its text, so many tiny fragments cannot
/// outgrow the cap.
const int collectStreamsEntryOverhead = 64;

/// Collects each printed fragment as a `(stream, text)` record, in order
/// (upstream's `CollectStreams`).
///
/// Each record is charged its text's UTF-8 bytes plus
/// [collectStreamsEntryOverhead], against `maxBytes`
/// ([defaultMaxPrintCollectBytes] by default; null for no cap, for trusted
/// code only). The cap is the collector's own, not the session's
/// `maxMemory`.
final class CollectStreams {
  /// An empty collector capped at [maxBytes]. A negative [maxBytes] throws
  /// [ArgumentError], as upstream refuses it (`OverflowError` there).
  CollectStreams({int? maxBytes = defaultMaxPrintCollectBytes})
    : _maxBytes = _checkedCap(maxBytes);

  final int? _maxBytes;
  final List<(String, String)> _output = [];

  /// The bytes charged so far.
  int _charged = 0;

  /// Keeps [text] as printed to [stream], `'stdout'` or `'stderr'`; any
  /// other [stream] throws [ArgumentError].
  ///
  /// A fragment that would take the charge past the cap is refused whole,
  /// and nothing is kept or charged: it throws [MontyRuntimeError], Python
  /// `MemoryError` with upstream's text for a memory limit
  /// ([memoryLimitError]), the error a session's feed then fails with.
  void call(String stream, String text) {
    _checkStream(stream);
    final add = utf8Length(text) + collectStreamsEntryOverhead;
    _checkLimit(_charged, add, _maxBytes);
    _output.add((stream, text));
    _charged += add;
  }

  /// The records so far, in a new list: reading does not drain the
  /// collector, and changing the list does not reach it.
  List<(String, String)> get output => List.of(_output);

  /// Upstream's `repr`: `CollectStreams(output=[('stdout', 'text'), ...])`.
  @override
  String toString() {
    final records = _output
        .map((r) => '(${pythonRepr(r.$1)}, ${pythonRepr(r.$2)})')
        .join(', ');

    return 'CollectStreams(output=[$records])';
  }
}

/// Collects the printed text of both streams as one string, in order
/// (upstream's `CollectString`).
///
/// The text is charged its UTF-8 bytes, with no overhead, against
/// `maxBytes` ([defaultMaxPrintCollectBytes] by default; null for no cap,
/// for trusted code only). The cap is the collector's own, not the
/// session's `maxMemory`.
final class CollectString {
  /// An empty collector capped at [maxBytes]. A negative [maxBytes] throws
  /// [ArgumentError], as upstream refuses it (`OverflowError` there).
  CollectString({int? maxBytes = defaultMaxPrintCollectBytes})
    : _maxBytes = _checkedCap(maxBytes);

  final int? _maxBytes;
  final StringBuffer _output = StringBuffer();

  /// The UTF-8 length of [_output].
  int _bytes = 0;

  /// Whether [_output] ends with a lead surrogate, which a fragment that
  /// starts with a trail surrogate pairs with.
  bool _endsWithLead = false;

  /// Appends [text] as printed to [stream], `'stdout'` or `'stderr'`; the
  /// stream is not kept, and nothing separates fragments. Any other
  /// [stream] throws [ArgumentError].
  ///
  /// The charge is the UTF-8 length of the whole text: a surrogate pair
  /// split across two fragments is one 4-byte character, not two 3-byte
  /// halves. A fragment that would take the text past the cap is refused
  /// whole: it throws [MontyRuntimeError], as [CollectStreams.call] does.
  void call(String stream, String text) {
    _checkStream(stream);
    final pairs =
        _endsWithLead && text.isNotEmpty && _isTrail(text.codeUnitAt(0));
    // The lead was charged 3 alone and the trail 3; paired they are 4.
    final add = utf8Length(text) - (pairs ? 2 : 0);
    _checkLimit(_bytes, add, _maxBytes);
    _output.write(text);
    _bytes += add;
    if (text.isNotEmpty) {
      _endsWithLead = _isLead(text.codeUnitAt(text.length - 1));
    }
  }

  /// The text so far; reading does not drain the collector.
  String get output => _output.toString();

  /// Upstream's `repr`: `CollectString(output='text')`.
  @override
  String toString() => 'CollectString(output=${pythonRepr(output)})';
}

/// Per collector overflow thrown during a feed's print delivery, that
/// delivery ([deliverPrint]): only such an error passes through that feed
/// as it is (see [isCollectorOverflow]).
final Expando<Object> _overflows = Expando('print collector overflow');

/// The zone value naming the print delivery a callback runs in.
final Object _deliveryKey = Object();

/// Runs [callback] as part of [delivery], a feed's print delivery, so an
/// overflow a collector throws inside it, synchronously or after an await,
/// is known to come from that delivery.
FutureOr<void> deliverPrint(
  Object delivery,
  FutureOr<void> Function() callback,
) => runZoned(callback, zoneValues: {_deliveryKey: delivery});

/// Whether [error] is an overflow a collector threw during [delivery],
/// which that feed raises as it is, as upstream raises its collectors'
/// `MemoryError`. Anything else a print callback throws, an overflow
/// thrown elsewhere and rethrown too, is classified as a host exception.
bool isCollectorOverflow(Object error, Object delivery) =>
    error is MontyRuntimeError && identical(_overflows[error], delivery);

bool _isLead(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isTrail(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

int? _checkedCap(int? maxBytes) {
  validateUnsigned(maxBytes, 'maxBytes');

  return maxBytes;
}

void _checkStream(String stream) {
  if (stream != 'stdout' && stream != 'stderr') {
    throw ArgumentError.value(
      stream,
      'stream',
      "must be 'stdout' or 'stderr'",
    );
  }
}

/// Upstream's `check_print_collect_limit`: refuses a growth by [add] of
/// [current] past [limit]; equality fits, and a null [limit] is no cap.
void _checkLimit(int current, int add, int? limit) {
  if (limit == null) return;
  final used = current + add;
  if (used > limit) {
    final error = memoryLimitError(used, limit);
    if (Zone.current[_deliveryKey] case final Object delivery) {
      _overflows[error] = delivery;
    }
    throw error;
  }
}
