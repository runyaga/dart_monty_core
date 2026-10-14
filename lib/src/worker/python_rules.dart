/// The Python rules upstream's decoder applies when it builds objects.
///
/// Upstream turns each arena node into a Python object
/// (`python/decode.rs`), and Python's constructors add rules of their own:
/// a dict or set drops keys equal to an earlier one and refuses unhashable
/// ones, `collections.namedtuple` refuses invalid names, `timedelta` refuses
/// more than 999999999 days, and `PurePosixPath` normalizes its text. The
/// reader applies the same rules, so it accepts and builds what upstream's
/// Python host would.
///
/// Internal to the package; nothing here is exported.
library;

/// Python's `str.isidentifier()`.
///
/// The first character is `_` or has the XID_Start property, the rest
/// XID_Continue. The properties come from the platform's Unicode tables, so a
/// character assigned after the Unicode version of either side can differ.
bool isIdentifier(String name) => _identifier.hasMatch(name);

final RegExp _identifier = RegExp(
  r'^[_\p{XID_Start}]\p{XID_Continue}*$',
  unicode: true,
);

/// `keyword.kwlist`, which has not changed since Python 3.7.
const Set<String> pythonKeywords = {
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', //
  'break', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except',
  'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda',
  'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with',
  'yield',
};

/// Why `collections.namedtuple(name, fields)._make(values)` would raise for
/// a named tuple [typeName] with [fieldNames] and [valueCount] values, or
/// null when it would not.
///
/// Upstream calls `namedtuple` with the part of [typeName] after its last
/// `.` (the rest becomes `module=`), so only that part must be a name.
/// The checks run in `namedtuple`'s order: each name an identifier and not
/// a keyword, then each field without a leading underscore and not repeated,
/// then `_make`'s length check.
///
/// The rules are CPython 3.12's, the oracle's pinned version. The ones
/// that need Unicode NFKC normalization, which Dart does not have, are not
/// applied, so these are accepted here: two field names that normalize alike
/// (`K` and KELVIN SIGN), which 3.12 rejects with `SyntaxError` when it
/// compiles the constructor; and, on Python 3.14 and later only, a name that
/// normalizes to `None`, `True` or `False` (fullwidth `Ｎｏｎｅ`).
String? namedTupleError(
  String typeName,
  List<String> fieldNames,
  int valueCount,
) {
  final simple = typeName.substring(typeName.lastIndexOf('.') + 1);
  for (final name in [simple, ...fieldNames]) {
    if (!isIdentifier(name)) {
      return 'ValueError: Type names and field names must be valid '
          'identifiers: ${pythonRepr(name)}';
    }
    if (pythonKeywords.contains(name)) {
      return 'ValueError: Type names and field names cannot be a keyword: '
          '${pythonRepr(name)}';
    }
  }
  final seen = <String>{};
  for (final name in fieldNames) {
    if (name.startsWith('_')) {
      return 'ValueError: Field names cannot start with an underscore: '
          '${pythonRepr(name)}';
    }
    if (!seen.add(name)) {
      return 'ValueError: Encountered duplicate field name: '
          '${pythonRepr(name)}';
    }
  }
  if (valueCount != fieldNames.length) {
    return 'TypeError: Expected ${fieldNames.length} arguments, got '
        '$valueCount';
  }

  return null;
}

/// The most days a `datetime.timedelta` holds, either way.
const int maxTimedeltaDays = 999999999;

/// The text `PurePosixPath(path)` gives back.
///
/// Empty and `.` segments go, `..` stays, a trailing `/` goes, and an empty
/// result is `.`. A path that starts with exactly two slashes keeps them, as
/// POSIX allows; one or three or more become one.
String purePosixPath(String path) {
  final slashes = RegExp('^/*').stringMatch(path)?.length ?? 0;
  final root = switch (slashes) {
    0 => '',
    2 => '//',
    _ => '/',
  };
  final parts = [
    for (final part in path.split('/'))
      if (part.isNotEmpty && part != '.') part,
  ];
  final joined = root + parts.join('/');

  return joined.isEmpty ? '.' : joined;
}

/// [s] as Python's `repr()` renders a `str`.
///
/// Single quotes unless [s] has a single quote and no double quote; `\\`,
/// the quote, `\t`, `\n` and `\r` escaped; other characters Python does not
/// print as `\x`, `\u` or `\U` escapes. What is printable comes from the
/// platform's Unicode tables.
String pythonRepr(String s) {
  final quote = s.contains("'") && !s.contains('"') ? '"' : "'";
  final out = StringBuffer(quote);
  for (final c in _codePoints(s)) {
    out.write(c < 0x80 ? _asciiRepr(c, quote) : _wideRepr(c));
  }
  out.write(quote);

  return out.toString();
}

String _asciiRepr(int c, String quote) {
  final ch = String.fromCharCode(c);

  return switch (c) {
    0x5c => r'\\',
    0x09 => r'\t',
    0x0a => r'\n',
    0x0d => r'\r',
    _ when ch == quote => '\\$quote',
    < 0x20 || 0x7f => '\\x${_hex(c, 2)}',
    _ => ch,
  };
}

String _wideRepr(int c) {
  final ch = String.fromCharCode(c);
  if (!_unprintable.hasMatch(ch)) return ch;

  return switch (c) {
    <= 0xff => '\\x${_hex(c, 2)}',
    <= 0xffff => '\\u${_hex(c, 4)}',
    _ => '\\U${_hex(c, 8)}',
  };
}

/// The categories `str.isprintable()` rejects, space excepted.
final RegExp _unprintable = RegExp(
  r'^[\p{Cc}\p{Cf}\p{Cs}\p{Co}\p{Cn}\p{Zl}\p{Zp}\p{Zs}]$',
  unicode: true,
);

String _hex(int c, int width) => c.toRadixString(16).padLeft(width, '0');

/// [s]'s code points, with an unpaired surrogate as its own code point.
Iterable<int> _codePoints(String s) sync* {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (_isLead(c) && i + 1 < s.length && _isTrail(s.codeUnitAt(i + 1))) {
      yield ((c - 0xd800) << 10) + (s.codeUnitAt(i + 1) - 0xdc00) + 0x10000;
      i++;
    } else {
      yield c;
    }
  }
}

/// Whether [s] has a UTF-16 surrogate without its pair.
///
/// Such a string has no UTF-8 form, so upstream's encoder cannot take it.
///
/// A loop, not `_codePoints(s).any(_isSurrogate)`: that tear-off makes
/// `dart compile wasm` (3.13.5) abort with "Conversion between non-reference
/// types (from f64 to i64)" in any app that reaches it, and the consumer
/// probes (tool/consumers) are such apps.
bool hasUnpairedSurrogate(String s) {
  for (final c in _codePoints(s)) {
    if (_isSurrogate(c)) return true;
  }

  return false;
}

/// [s] as PyO3's `to_string_lossy` converts it: encoded as UTF-8 with
/// `surrogatepass`, then decoded lossily, so each unpaired surrogate's three
/// bytes become three U+FFFD.
String lossyString(String s) {
  final out = StringBuffer();
  for (final c in _codePoints(s)) {
    out.write(_isSurrogate(c) ? '\uFFFD\uFFFD\uFFFD' : String.fromCharCode(c));
  }

  return out.toString();
}

/// The length of [s] in UTF-8 bytes; an unpaired surrogate counts as the
/// three bytes `surrogatepass` gives it.
int utf8Length(String s) {
  var bytes = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x80) {
      bytes += 1;
    } else if (c < 0x800) {
      bytes += 2;
    } else if (_isLead(c) &&
        i + 1 < s.length &&
        _isTrail(s.codeUnitAt(i + 1))) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }

  return bytes;
}

/// The message of the `UnicodeEncodeError` Python raises encoding [s] as
/// UTF-8, or null when [s] has no unpaired surrogate.
///
/// As CPython's strict UTF-8 encoder: the error covers the first run of
/// consecutive surrogate code points, and positions count code points, a
/// valid pair being one.
String? surrogateEncodeError(String s) {
  // The first run of surrogates: where it starts, its length and its first.
  var start = -1;
  var length = 0;
  var first = 0;
  for (final (i, c) in _codePoints(s).indexed) {
    if (!_isSurrogate(c)) {
      if (start >= 0) break;
      continue;
    }
    if (start < 0) {
      start = i;
      first = c;
    }
    length++;
  }
  if (start < 0) return null;
  const head = "'utf-8' codec can't encode";
  const tail = 'surrogates not allowed';

  return length == 1
      ? "$head character '\\u${_hex(first, 4)}' in position $start: $tail"
      : '$head characters in position $start-${start + length - 1}: $tail';
}

bool _isSurrogate(int c) => _isLead(c) || _isTrail(c);

bool _isLead(int c) => c >= 0xd800 && c <= 0xdbff;

bool _isTrail(int c) => c >= 0xdc00 && c <= 0xdfff;

/// Days from 0001-01-01 to the given proleptic Gregorian date.
int ordinalDay(int year, int month, int day) {
  // Howard Hinnant's days_from_civil, shifted so 0001-01-01 is day 0.
  final y = month <= 2 ? year - 1 : year;
  final era = (y >= 0 ? y : y - 399) ~/ 400;
  final yoe = y - era * 400;
  final mp = (month + 9) % 12;
  final doy = (mp * 153 + 2) ~/ 5 + day - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;

  return era * 146097 + doe - 306;
}
