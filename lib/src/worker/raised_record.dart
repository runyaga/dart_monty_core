/// A raised Python exception as the worker reports it, and its renderings.
///
/// A port of upstream's `Display` for `MontyException` and `StackFrame`
/// (`monty-types/src/exceptions.rs` at the pinned tag) and of
/// pydantic-monty's `display()` formats, checked byte for byte against
/// upstream's own output (the parity suite's display cases). Two of
/// upstream's rules are kept as they are:
///
/// - more than 3 identical consecutive frames (same filename, start line
///   and frame name) collapse into `[Previous line repeated N more times]`;
/// - the caret padding subtracts the preview line's stripped indent counted
///   in UTF-8 bytes, while the columns count characters, so an indent of
///   non-ASCII whitespace shifts the carets left.
///
/// The record keeps the wire's absent message apart from an empty one: the
/// renderer prints `Type` for the first and `Type: ` for the second.
///
/// [RaisedRecord.checked] applies upstream's checks on a raised exception
/// before it is rendered (a known type, present positions, columns within
/// the preview line); [RaisedRecord.fromWire] renders the frames as given.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart'
    show exceptionTypeNames, rustDebug;
import 'package:dart_monty_core/src/worker/arena_reader.dart'
    show unsignedValue;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_rules.dart' show utf8Length;
import 'package:fixnum/fixnum.dart';

/// How many identical consecutive frames are shown before the rest collapse
/// (upstream's `REPEAT_FRAMES_SHOWN`, as CPython).
const int _repeatFramesShown = 3;

/// The indent every preview line is printed at.
const String _indent = '    ';

/// A raised Python exception: its type, its message and its traceback.
final class RaisedRecord {
  /// Creates a record. A null [message] is one the wire did not carry.
  const RaisedRecord(
    this.excType,
    this.message,
    this.traceback, {
    this.payload,
  });

  /// The exception [raised] carries, its message null when unset and its
  /// structured data sanitised as upstream's conversion does ([payloadOf]).
  factory RaisedRecord.fromWire(pb.RaisedException raised) => RaisedRecord(
    raised.excType,
    raised.hasMessage() ? raised.message : null,
    List.unmodifiable(raised.traceback.map(TracebackFrame.fromWire)),
    payload: raised.hasData() ? payloadOf(raised.data) : null,
  );

  /// The exception a host raised, [raised] built on this side and never
  /// sent: its message null when unset and its structured data kept as
  /// given, as upstream keeps a live exception's (`exc_py_to_monty`), with
  /// none of the checks [payloadOf] makes of data from the wire. It has no
  /// traceback.
  factory RaisedRecord.fromHost(pb.RaisedException raised) => RaisedRecord(
    raised.excType,
    raised.hasMessage() ? raised.message : null,
    const [],
    // Only a JSON error's data is built host side (`raisedException`).
    payload: raised.data.hasJson() ? _jsonAttributes(raised.data.json) : null,
  );

  /// The exception [raised] carries, after upstream's checks
  /// (`monty-proto`'s conversion of a `RaisedException`): its type must be
  /// one upstream knows, and each frame must have both positions and, for a
  /// span on one line with a preview line, an end column neither before the
  /// start column nor more than 2 past the preview's characters (a span
  /// over several lines is not checked). A frame's columns decide the caret
  /// padding and width, so this keeps an untrusted worker from making the
  /// renderer misplace carets or allocate without bound.
  ///
  /// Throws [InvalidRaisedException] with upstream's reason when a check
  /// fails.
  factory RaisedRecord.checked(pb.RaisedException raised) {
    if (!exceptionTypeNames.contains(raised.excType)) {
      throw InvalidRaisedException(
        'unknown exception type ${rustDebug(raised.excType)}',
      );
    }
    raised.traceback.forEach(_checkFrame);

    return RaisedRecord.fromWire(raised);
  }

  /// The exception type's name.
  final String excType;

  /// The message, or null when the wire carries none.
  final String? message;

  /// The frames, outermost first.
  final List<TracebackFrame> traceback;

  /// The structured data the exception carries, or null: none was sent, or
  /// it was dropped.
  final ExcPayload? payload;

  /// The exception rendered in [format], as upstream's `display()`:
  ///
  /// - `'traceback'`: the full traceback, then `Type: message`;
  /// - `'type-msg'`: `Type: message`, or `Type` with no message;
  /// - `'msg'`: the message alone, `''` with none.
  ///
  /// Any other [format] throws an [ArgumentError] with upstream's text
  /// (upstream raises `ValueError`).
  String display([String format = 'traceback']) => switch (format) {
    'traceback' => _traceback(),
    'type-msg' => _summary(),
    'msg' => message ?? '',
    _ => throw ArgumentError(
      "Invalid display format: '$format'. Expected 'traceback', "
      "'type-msg', or 'msg'",
    ),
  };

  String _summary() {
    final text = message;

    return text == null ? excType : '$excType: $text';
  }

  String _traceback() {
    final out = StringBuffer();
    if (traceback.isNotEmpty) out.write('Traceback (most recent call last):\n');
    // The run of identical consecutive frames being written: its first frame
    // and its length so far. Past the first few, a run is only counted.
    TracebackFrame? head;
    var run = 0;
    for (final frame in traceback) {
      if (head != null && head._repeats(frame)) {
        run++;
      } else {
        _writeCollapsed(out, run);
        head = frame;
        run = 1;
      }
      if (run <= _repeatFramesShown) frame._writeTo(out);
    }
    _writeCollapsed(out, run);
    out.write(_summary());

    return out.toString();
  }

  /// The line standing for the frames of a [run] that were not shown.
  static void _writeCollapsed(StringBuffer out, int run) {
    if (run <= _repeatFramesShown) return;
    out.write(
      '  [Previous line repeated ${run - _repeatFramesShown} more times]\n',
    );
  }
}

/// One frame of a raised exception's traceback, as the wire carries it.
final class TracebackFrame {
  /// Creates a frame. Lines and columns are 1-based; columns count
  /// characters.
  const TracebackFrame({
    required this.filename,
    required this.startLine,
    required this.startColumn,
    required this.endLine,
    required this.endColumn,
    this.frameName,
    this.previewLine,
    this.hideCaret = false,
    this.hideFrameName = false,
  });

  /// The frame [frame] carries. An unset frame name or preview line is null;
  /// a set empty one is kept.
  factory TracebackFrame.fromWire(pb.StackFrame frame) => TracebackFrame(
    filename: frame.filename,
    startLine: frame.start.line,
    startColumn: frame.start.column,
    endLine: frame.end.line,
    endColumn: frame.end.column,
    frameName: frame.hasFrameName() ? frame.frameName : null,
    previewLine: frame.hasPreviewLine() ? frame.previewLine : null,
    hideCaret: frame.hideCaret,
    hideFrameName: frame.hideFrameName,
  );

  /// The source the frame is in.
  final String filename;

  /// The line the span starts on.
  final int startLine;

  /// The column the span starts at.
  final int startColumn;

  /// The line the span ends on.
  final int endLine;

  /// The column the span ends at.
  final int endColumn;

  /// The function's name; null at module level.
  final String? frameName;

  /// The source line, or for a span over several lines the dedented block.
  final String? previewLine;

  /// Whether the frame is shown without carets.
  final bool hideCaret;

  /// Whether the frame's line omits `, in <name>`.
  final bool hideFrameName;

  /// Whether [other] counts as the same frame for collapsing repeats.
  bool _repeats(TracebackFrame other) =>
      filename == other.filename &&
      startLine == other.startLine &&
      frameName == other.frameName;

  void _writeTo(StringBuffer out) {
    out.write('  File "$filename", line $startLine');
    if (!hideFrameName) out.write(', in ${frameName ?? '<module>'}');
    final line = previewLine;
    if (line == null) {
      out.write('\n');

      return;
    }
    if (startLine != endLine) {
      // A pre-rendered, dedented block: each line at the indent, no carets.
      out.write('\n');
      for (final blockLine in _rustLines(line)) {
        out.write('$_indent$blockLine\n');
      }

      return;
    }
    final trimmed = _trimStart(line);
    out.write('\n$_indent$trimmed\n');
    if (hideCaret) return;
    // Bytes, as upstream's `line.len() - trimmed.len()`.
    final leading = _utf8Length(line, line.length - trimmed.length);
    final caretStart = startColumn > leading
        ? _indent.length + startColumn - leading - 1
        : _indent.length;
    // At least one caret. Upstream subtracts u32s here and rejects a
    // reversed span before rendering; one caret is rendered for it here.
    final span = endColumn - startColumn;
    out
      ..write(' ' * caretStart)
      ..write('~' * (span < 1 ? 1 : span))
      ..write('\n');
  }
}

/// [text] without its leading whitespace, as Rust's `str::trim_start`:
/// the Unicode `White_Space` code points, which unlike Dart's `trimLeft`
/// do not include U+FEFF.
String _trimStart(String text) {
  var i = 0;
  while (i < text.length && _isWhiteSpace(text.codeUnitAt(i))) {
    i++;
  }

  return text.substring(i);
}

/// Whether [c] has the Unicode `White_Space` property. All of them are in
/// the Basic Multilingual Plane, so one UTF-16 code unit decides.
bool _isWhiteSpace(int c) => _whiteSpace.contains(c);

/// The Unicode `White_Space` code points.
const Set<int> _whiteSpace = {
  0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680, //
  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008,
  0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
};

/// The UTF-8 length of [text]'s first [end] code units, which hold
/// whitespace only (so no surrogates).
int _utf8Length(String text, int end) {
  var bytes = 0;
  for (var i = 0; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (c < 0x80) {
      bytes += 1;
    } else if (c < 0x800) {
      bytes += 2;
    } else {
      bytes += 3;
    }
  }

  return bytes;
}

/// [text]'s lines, as Rust's `str::lines`: split at `\n`, a `\r` before it
/// dropped, and a final line ending adding no line.
List<String> _rustLines(String text) {
  final lines = <String>[];
  var start = 0;
  while (start < text.length) {
    final nl = text.indexOf('\n', start);
    if (nl < 0) {
      lines.add(text.substring(start));
      break;
    }
    final end = nl > start && text.codeUnitAt(nl - 1) == 0x0d ? nl - 1 : nl;
    lines.add(text.substring(start, end));
    start = nl + 1;
  }

  return lines;
}

/// A raised exception that fails upstream's checks; [detail] is upstream's
/// reason (its `ProtoConvertError` text).
final class InvalidRaisedException implements Exception {
  /// Creates the failure for [detail].
  const InvalidRaisedException(this.detail);

  /// Upstream's reason.
  final String detail;

  @override
  String toString() => 'InvalidRaisedException: $detail';
}

void _checkFrame(pb.StackFrame frame) {
  if (!frame.hasStart()) {
    throw const InvalidRaisedException(
      'missing required field StackFrame.start',
    );
  }
  if (!frame.hasEnd()) {
    throw const InvalidRaisedException('missing required field StackFrame.end');
  }
  final start = frame.start;
  final end = frame.end;
  if (!frame.hasPreviewLine() || start.line != end.line) return;
  if (end.column < start.column) {
    throw InvalidRaisedException(
      'invalid value for StackFrame.end.column: ${end.column} is before '
      'start column ${start.column}',
    );
  }
  // Characters as Rust counts them: Unicode scalar values.
  final chars = frame.previewLine.runes.length;
  if (end.column > chars + 2) {
    throw InvalidRaisedException(
      'invalid value for StackFrame.end.column: ${end.column} is beyond '
      'the $chars-character preview line',
    );
  }
}

/// Which of upstream's `ExcData` arms a payload is, with the kind of object
/// a Unicode error carries.
enum PayloadKind {
  /// A Unicode error on a `bytes` object: a decode error's.
  unicodeBytes,

  /// A Unicode error on a `str` object: an encode error's.
  unicodeStr,

  /// A `json.JSONDecodeError`'s.
  json,
}

/// A raised exception's structured data (upstream's `ExcData`), as the
/// attributes the host-side exception gets.
final class ExcPayload {
  /// Data of [kind], read as [attributes].
  const ExcPayload(this.kind, this.attributes);

  /// Which arm it came in.
  final PayloadKind kind;

  /// Upstream's attribute names and values: `encoding`, `object`, `start`,
  /// `end` and `reason` for a Unicode error; `msg`, `doc` (`''` when the
  /// sender dropped it), `pos`, `lineno` and `colno` for a JSON error.
  final Map<String, MontyValue> attributes;
}

/// The largest `object`, `encoding`, `reason`, `msg` or `doc`, in UTF-8
/// bytes or bytes, a payload may carry (upstream's
/// `UnicodeErrorData::MAX_OBJECT_LEN` and `JsonErrorData::MAX_DOC_LEN`).
const int maxPayloadLength = 64 * 1024;

/// [data] sanitised as upstream's conversion does
/// (`monty-proto/src/convert/exception.rs`, `sanitize_unicode_data`,
/// `sanitize_json_data`): null, the payload dropped, when a string or object
/// is over [maxPayloadLength], when a Unicode error's range is not a
/// non-empty slice of its object (bytes for a `bytes` object, characters for
/// a `str`), when a JSON error's `lineno` or `colno` is 0, or when its `pos`
/// is past its document. Never a rejection: the exception keeps its type and
/// message. An error without the right payload carries a plain `ValueError`
/// while the renderer retains the original exception type.
ExcPayload? payloadOf(pb.ExcData data) => switch (data.whichKind()) {
  pb.ExcData_Kind.unicode => _unicodePayload(data.unicode),
  pb.ExcData_Kind.json => _jsonPayload(data.json),
  pb.ExcData_Kind.notSet => null,
};

ExcPayload? _unicodePayload(pb.UnicodeErrorData data) {
  if (utf8Length(data.encoding) > maxPayloadLength ||
      utf8Length(data.reason) > maxPayloadLength) {
    return null;
  }
  final (PayloadKind kind, MontyValue object, int length) object;
  switch (data.whichObject()) {
    case pb.UnicodeErrorData_Object.objectBytes:
      final bytes = data.objectBytes;
      if (bytes.length > maxPayloadLength) return null;
      object = (
        PayloadKind.unicodeBytes,
        MontyBytes(Uint8List.fromList(bytes).asUnmodifiableView()),
        bytes.length,
      );
    case pb.UnicodeErrorData_Object.objectStr:
      final text = data.objectStr;
      if (utf8Length(text) > maxPayloadLength) return null;
      object = (PayloadKind.unicodeStr, MontyString(text), text.runes.length);
    case pb.UnicodeErrorData_Object.notSet:
      return null;
  }
  final (kind, value, length) = object;
  final start = _bounded(data.start, length);
  final end = _bounded(data.end, length);
  if (start == null || end == null || start >= end) return null;

  return ExcPayload(kind, {
    'encoding': MontyString(data.encoding),
    'object': value,
    'start': MontyInt(start),
    'end': MontyInt(end),
    'reason': MontyString(data.reason),
  });
}

ExcPayload? _jsonPayload(pb.JsonErrorData data) {
  if (utf8Length(data.msg) > maxPayloadLength) return null;
  final doc = data.hasDoc() ? data.doc : null;
  if (doc != null && utf8Length(doc) > maxPayloadLength) return null;
  if (data.lineno.isZero || data.colno.isZero) return null;
  if (doc != null && _bounded(data.pos, doc.runes.length) == null) return null;

  return _jsonAttributes(data);
}

ExcPayload _jsonAttributes(pb.JsonErrorData data) {
  final doc = data.hasDoc() ? data.doc : null;

  return ExcPayload(PayloadKind.json, {
    'msg': MontyString(data.msg),
    // Upstream's host object takes '' for a document the sender dropped.
    'doc': MontyString(doc ?? ''),
    'pos': unsignedValue(data.pos),
    'lineno': unsignedValue(data.lineno),
    'colno': unsignedValue(data.colno),
  });
}

/// [value], an unsigned 64-bit field, when it is at most [max]; else null.
int? _bounded(Int64 value, int max) =>
    value.isNegative || value > max ? null : value.toInt();
