// The ONE strict adjudicator for upstream's fixture directives.
//
// Every harness that judges a fixture against its own directives calls
// [adjudicateFixture]: the worker corpus runner (native, dart2js and
// dart2wasm). An expected exception is matched by its full `repr()`, not by
// type alone: `# Raise=ValueError('x')` is not satisfied by any ValueError,
// and a TRACEBACK docstring is compared frame by frame.
//
// What is compared is exactly what upstream's datatest runner compares
// (`crates/monty-datatest/src/main.rs`):
//
//   `# Raise=`     the raised exception's `py_repr()`, e.g. `ValueError('x')`
//   TRACEBACK      the exception's `Display`: every frame, then `Type: msg`
//   `# Return.str=` the result's `str()`
//
// The worker renders a traceback itself (`MontyRuntimeError.display()`), and
// that text is compared as it is. For an outcome that carries frames instead,
// the renderers below mirror upstream's `monty-types/src/exceptions.rs` and
// `monty-types/src/format.rs`. They are written from upstream's source, not
// from this package's encoder, so a decoding defect in core shows up as a
// mismatch rather than being agreed with.
//
// `# Return=` compares the value's `repr()` when the runner renders one, and
// `MontyValue` equality otherwise.

import 'package:dart_monty_core/dart_monty_core.dart';

import 'package:monty_conformance/src/fixture_parser.dart';

/// What one fixture run produced, as the adjudicator needs it.
final class FixtureOutcome {
  /// Creates a [FixtureOutcome].
  ///
  /// [excType] null means the run completed without raising.
  const FixtureOutcome({
    this.excType,
    this.message,
    this.traceback = const [],
    this.renderedTraceback,
    this.value,
    this.valueRepr,
  });

  /// The Python exception class raised, or null when nothing was raised.
  final String? excType;

  /// The exception message (`args[0]`). Empty and null both mean none.
  final String? message;

  /// The frames the backend reported, outermost first.
  final List<FixtureFrame> traceback;

  /// The traceback exactly as the backend rendered it, when it renders one
  /// itself (the worker does). Compared in place of rendering [traceback]
  /// here.
  final String? renderedTraceback;

  /// The value the fixture evaluated to, when it completed.
  final MontyValue? value;

  /// The value's Python `repr()`, when the backend renders one itself (the
  /// worker runner does, for the kinds it can). Compared with the
  /// directive's text, as upstream compares `py_repr()`, in place of value
  /// equality.
  final String? valueRepr;
}

/// One traceback frame as [renderMontyTraceback] needs it: the fields of
/// upstream's `StackFrame`.
final class FixtureFrame {
  /// Creates a [FixtureFrame]. Lines and columns are 1-based.
  const FixtureFrame({
    required this.filename,
    required this.startLine,
    required this.startColumn,
    this.endLine,
    this.endColumn,
    this.frameName,
    this.previewLine,
    this.hideCaret = false,
    this.hideFrameName = false,
  });

  /// The frame [frame] is, as the worker reported it.
  ///
  /// The worker's [Frame] does not say whether upstream hides the caret or
  /// the function name, so both are shown.
  FixtureFrame.fromFrame(Frame frame)
    : this(
        filename: frame.filename,
        startLine: frame.line,
        startColumn: frame.column,
        endLine: frame.endLine,
        endColumn: frame.endColumn,
        frameName: frame.functionName,
        previewLine: frame.sourceLine,
      );

  /// The source the frame is in.
  final String filename;

  /// The line the span starts on.
  final int startLine;

  /// The column the span starts at.
  final int startColumn;

  /// The line the span ends on; null is [startLine].
  final int? endLine;

  /// The column the span ends at; null is [startColumn].
  final int? endColumn;

  /// The function's name; null is module level.
  final String? frameName;

  /// The source line, or for a span over several lines the dedented block.
  final String? previewLine;

  /// Whether upstream prints no caret line under the source.
  final bool hideCaret;

  /// Whether upstream prints the frame without its function name.
  final bool hideFrameName;
}

/// Judges [outcome] against [expectation].
///
/// Returns null when the expectation held, otherwise the reason it did not —
/// stated with both what was expected and what happened.
String? adjudicateFixture(
  FixtureExpectation expectation,
  FixtureOutcome outcome,
) {
  final raised = outcome.excType;
  switch (expectation) {
    case MalformedFixture(:final reason):
      return 'malformed fixture: $reason';

    case ExpectXfail(:final expected):
      // Strict, like upstream: an xfail that passes is an error.
      if (adjudicateFixture(expected, outcome) == null) {
        return 'xfail=monty fixture PASSED — strict xfail: the marker is '
            'stale, or this backend diverges from upstream in the passing '
            'direction';
      }

      return null;

    case ExpectNoException():
      if (raised == null) return null;

      return 'expected no error, got ${_describe(outcome)}';

    case ExpectReturn(value: final fixtureValue, :final repr):
      final expected = MontyValue.fromDart(fixtureValue);
      if (raised != null) {
        return 'expected $expected, got error ${_describe(outcome)}';
      }
      final actualRepr = outcome.valueRepr;
      if (actualRepr != null && repr != null) {
        if (actualRepr == repr) return null;

        return 'repr mismatch: expected $repr, got $actualRepr';
      }
      if (outcome.value == expected) return null;

      return 'value mismatch: expected $expected, got ${outcome.value}';

    case ExpectReturnStr(:final text):
      if (raised != null) {
        return 'expected str() == ${pyStringRepr(text)}, got error '
            '${_describe(outcome)}';
      }
      final actual = _pyStr(outcome.value);
      if (actual == null) {
        return 'expected str() == ${pyStringRepr(text)}, but this '
            'adjudicator cannot render str() of ${outcome.value}';
      }
      if (actual == text) return null;

      return 'str() mismatch: expected ${pyStringRepr(text)}, got '
          '${pyStringRepr(actual)}';

    case ExpectRaise(:final excType, :final repr, :final traceback):
      if (raised == null) {
        return 'expected ${repr ?? excType}, got no exception '
            '(value ${outcome.value})';
      }
      if (traceback != null) {
        final actual =
            outcome.renderedTraceback ??
            renderMontyTraceback(raised, outcome.message, outcome.traceback);
        if (actual == traceback) return null;

        return 'traceback mismatch:\n--- expected\n$traceback\n'
            '--- actual\n$actual';
      }
      final want = repr ?? excType;
      final actual = pyExceptionRepr(raised, outcome.message);
      if (actual == want) return null;

      return 'exception mismatch: expected $want, got $actual';
  }
}

String _describe(FixtureOutcome o) {
  final type = o.excType ?? 'no error';
  final message = o.message;
  if (message == null) return type;
  final oneLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.isEmpty || oneLine == type) return type;
  final capped = oneLine.length > 200
      ? '${oneLine.substring(0, 200)}…'
      : oneLine;

  return '$type: $capped';
}

/// `str()` for the scalar results a `# Return.str=` can name, or null.
String? _pyStr(MontyValue? v) => switch (v) {
  MontyString(:final value) => value,
  MontyInt(:final value) => '$value',
  MontyBool(:final value) => value ? 'True' : 'False',
  MontyNone() => 'None',
  _ => null,
};

/// Upstream `MontyException::py_repr`: `Type('msg')`, or `Type()` when there
/// is no message.
///
/// A missing message and an empty one look the same here, so an empty
/// message is read as none. Upstream distinguishes `Type('')` from
/// `Type()`; this cannot, and a fixture stating `Type('')` fails here.
String pyExceptionRepr(String excType, String? message) =>
    message == null || message.isEmpty
    ? '$excType()'
    : '$excType(${pyStringRepr(message)})';

/// Upstream `MontyException`'s `Display`: the traceback header, each frame,
/// identical consecutive frames collapsed after three, then `Type: msg`.
String renderMontyTraceback(
  String excType,
  String? message,
  List<FixtureFrame> frames,
) {
  final out = StringBuffer();
  if (frames.isNotEmpty) out.writeln('Traceback (most recent call last):');
  const shown = 3;
  var i = 0;
  while (i < frames.length) {
    var repeat = 1;
    while (i + repeat < frames.length &&
        _sameFrame(frames[i], frames[i + repeat])) {
      repeat++;
    }
    if (repeat > shown) {
      for (var j = 0; j < shown; j++) {
        _writeFrame(out, frames[i + j]);
      }
      out.writeln('  [Previous line repeated ${repeat - shown} more times]');
    } else {
      for (var j = 0; j < repeat; j++) {
        _writeFrame(out, frames[i + j]);
      }
    }
    i += repeat;
  }
  out.write(
    message == null || message.isEmpty ? excType : '$excType: $message',
  );

  return out.toString();
}

bool _sameFrame(FixtureFrame a, FixtureFrame b) =>
    a.filename == b.filename &&
    a.startLine == b.startLine &&
    a.frameName == b.frameName;

/// Upstream `StackFrame`'s `Display`.
void _writeFrame(StringBuffer out, FixtureFrame f) {
  if (f.hideFrameName) {
    out.write('  File "${f.filename}", line ${f.startLine}');
  } else {
    out.write(
      '  File "${f.filename}", line ${f.startLine}, in '
      '${f.frameName ?? '<module>'}',
    );
  }
  final line = f.previewLine;
  if (line == null) {
    out.write('\n');

    return;
  }
  final endLine = f.endLine ?? f.startLine;
  if (f.startLine != endLine) {
    // Multi-line statement: a pre-rendered block, no carets.
    out.write('\n');
    for (final blockLine in _rustLines(line)) {
      out.writeln('    $blockLine');
    }

    return;
  }
  final trimmed = line.trimLeft();
  out.writeln('\n    $trimmed');
  if (!f.hideCaret) {
    final leading = line.length - trimmed.length;
    final caretStart = f.startColumn > leading
        ? 4 + f.startColumn - leading - 1
        : 4;
    final endColumn = f.endColumn ?? f.startColumn;
    final caretLen = endColumn - f.startColumn < 1
        ? 1
        : endColumn - f.startColumn;
    out
      ..write(' ' * caretStart)
      ..writeln('~' * caretLen);
  }
}

/// Rust's `str::lines`: split on `\n`, strip a trailing `\r`, drop one
/// trailing empty line.
List<String> _rustLines(String s) {
  final parts = s.split('\n');
  if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();

  return [for (final p in parts) p.replaceFirst(RegExp(r'\r$'), '')];
}

/// Upstream `string_repr_fmt`: CPython's `repr()` of a `str`.
///
/// Escapes control, format, surrogate, private-use and separator characters
/// (except the ASCII space). Unassigned code points are NOT escaped here —
/// that needs Unicode tables this package does not carry — so a message
/// containing one renders differently from upstream and fails, rather than
/// passing wrongly.
String pyStringRepr(String s) {
  final quote = s.contains("'") && !s.contains('"') ? '"' : "'";
  final out = StringBuffer(quote);
  for (final c in s.runes) {
    final ch = String.fromCharCode(c);
    if (ch == r'\') {
      out.write(r'\\');
    } else if (ch == '\n') {
      out.write(r'\n');
    } else if (ch == '\t') {
      out.write(r'\t');
    } else if (ch == '\r') {
      out.write(r'\r');
    } else if (ch == quote) {
      out.write('\\$quote');
    } else if (_reprNeedsEscape(c)) {
      if (c <= 0xFF) {
        out.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
      } else if (c <= 0xFFFF) {
        out.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
      } else {
        out.write('\\U${c.toRadixString(16).padLeft(8, '0')}');
      }
    } else {
      out.write(ch);
    }
  }
  out.write(quote);

  return out.toString();
}

bool _reprNeedsEscape(int c) {
  if (c == 0x20) return false;
  // Cc
  if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) return true;
  // Zs, Zl, Zp
  if (c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000) {
    return true;
  }
  // Cf (the BMP ranges CPython treats as non-printable)
  if (c == 0xAD ||
      (c >= 0x600 && c <= 0x605) ||
      c == 0x61C ||
      c == 0x6DD ||
      c == 0x70F ||
      c == 0x180E ||
      (c >= 0x200B && c <= 0x200F) ||
      (c >= 0x202A && c <= 0x202E) ||
      (c >= 0x2060 && c <= 0x2064) ||
      (c >= 0x2066 && c <= 0x206F) ||
      c == 0xFEFF ||
      (c >= 0xFFF9 && c <= 0xFFFB)) {
    return true;
  }
  // Cs, Co
  if ((c >= 0xD800 && c <= 0xDFFF) ||
      (c >= 0xE000 && c <= 0xF8FF) ||
      c >= 0xF0000) {
    return true;
  }

  return false;
}
