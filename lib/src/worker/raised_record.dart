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
/// The frames are rendered as given: the checks upstream applies to a
/// raised exception before rendering it (present positions, columns within
/// the preview line) are not made here.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

/// How many identical consecutive frames are shown before the rest collapse
/// (upstream's `REPEAT_FRAMES_SHOWN`, as CPython).
const int _repeatFramesShown = 3;

/// The indent every preview line is printed at.
const String _indent = '    ';

/// A raised Python exception: its type, its message and its traceback.
final class RaisedRecord {
  /// Creates a record. A null [message] is one the wire did not carry.
  const RaisedRecord(this.excType, this.message, this.traceback);

  /// The exception [raised] carries, its message null when unset.
  factory RaisedRecord.fromWire(pb.RaisedException raised) => RaisedRecord(
    raised.excType,
    raised.hasMessage() ? raised.message : null,
    List.unmodifiable(raised.traceback.map(TracebackFrame.fromWire)),
  );

  /// The exception type's name.
  final String excType;

  /// The message, or null when the wire carries none.
  final String? message;

  /// The frames, outermost first.
  final List<TracebackFrame> traceback;

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
