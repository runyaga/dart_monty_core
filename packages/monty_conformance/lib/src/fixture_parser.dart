// Fixture directive parser for upstream monty's `test_cases/*.py`.
//
// THE FORMAT IS UPSTREAM'S, AND SO ARE ITS RULES. The reference is
// `parse_fixture` in monty's `crates/monty-datatest/src/main.rs` (v0.0.23):
//
//   * Config directives are unindented comment lines anywhere in the file,
//     matched by prefix: `xfail=`, `call-external`, `run-async`, `mount-fs`,
//     `gc-interval=`, `skip-cpython-windows`, `cpython-main-module`.
//   * An expectation is read from the LAST line only: `# Raise=`,
//     `# Return=`, `# Return.str=`, `# Return.type=`, `# ref-counts=`.
//   * A `"""\nTRACEBACK:\n ... \n"""` docstring takes precedence over the last
//     line, and is compared VERBATIM against the rendered traceback.
//   * `xfail=` is STRICT: a fixture marked xfail that passes is a failure.
//
// Where this parser is STRICTER than upstream, it is deliberately so, and only
// in one direction — a malformed fixture fails instead of silently asserting
// less. Upstream ignores an unrecognised directive, which turns a typo such as
// `# Raises=ValueError()` into "must not raise" and reports it green. Here
// every such case becomes [MalformedFixture], which no backend can pass:
//
//   * a directive-shaped line in the header block or on the last line whose
//     key is not in [knownFixtureDirectives];
//   * an expectation directive anywhere but the last line;
//   * a TRACEBACK docstring AND an expectation line (upstream silently picks
//     the docstring);
//   * an `xfail=` target other than `monty` / `cpython`, or a non-integer
//     `gc-interval=`;
//   * `# Return.type=`, which is upstream vocabulary this adjudicator does not
//     implement — failing loudly beats asserting nothing.
//
// Returns null when the caller asked to skip the fixture's mode.

import 'package:dart_monty_core/dart_monty_core.dart';

/// What a fixture's directives say must happen when it runs.
sealed class FixtureExpectation {
  /// Creates a [FixtureExpectation].
  const FixtureExpectation();
}

/// The fixture declared `# Return=<repr>`: it must complete with that value.
final class ExpectReturn extends FixtureExpectation {
  /// Creates an [ExpectReturn] expecting [value]; [repr] is the directive's
  /// text, which is what upstream compares (`py_repr()`).
  const ExpectReturn(this.value, {this.repr});

  /// The parsed Python repr, as a plain Dart value. Compare against a real
  /// result with `MontyValue.fromDart(value)`.
  final Object? value;

  /// The `# Return=` text verbatim, e.g. `[[...]]`.
  final String? repr;
}

/// The fixture declared `# Return.str=<text>`: it must complete with a value
/// whose `str()` is exactly [text].
final class ExpectReturnStr extends FixtureExpectation {
  /// Creates an [ExpectReturnStr].
  const ExpectReturnStr(this.text);

  /// The expected `str()` of the result, verbatim.
  final String text;
}

/// The fixture declared `# Raise=<ExcType>(<repr>)`, or carried a
/// `TRACEBACK:` docstring, so running it must raise.
final class ExpectRaise extends FixtureExpectation {
  /// Creates an [ExpectRaise].
  const ExpectRaise({
    required this.excType,
    required this.message,
    this.repr,
    this.traceback,
  });

  /// The Python exception class name, e.g. `ValueError`.
  final String excType;

  /// The exception message, unquoted. Informational: the strict comparison is
  /// on [repr] or [traceback], whichever the fixture stated.
  final String message;

  /// The `# Raise=` text verbatim, e.g. `ValueError('bad')` — compared against
  /// the raised exception's Python `repr()`, as upstream does.
  final String? repr;

  /// The TRACEBACK docstring body verbatim (frames and final line) — compared
  /// against the rendered traceback, as upstream does.
  final String? traceback;
}

/// The fixture declared no outcome directive: it must simply not raise.
///
/// Also what `# ref-counts=` means here: upstream checks ref counts only under
/// its `ref-count-return` feature and otherwise just requires a clean run.
final class ExpectNoException extends FixtureExpectation {
  /// Creates an [ExpectNoException].
  const ExpectNoException();
}

/// The fixture is marked `# xfail=monty`: [expected] must NOT hold.
///
/// Strict, like upstream: if the fixture meets [expected], that is a failure
/// and the marker must be removed.
final class ExpectXfail extends FixtureExpectation {
  /// Creates an [ExpectXfail].
  const ExpectXfail(this.expected);

  /// What the fixture would assert if it were not marked xfail.
  final FixtureExpectation expected;
}

/// The fixture's directives could not be read. Always adjudicated as a
/// failure, on every backend, naming [reason].
final class MalformedFixture extends FixtureExpectation {
  /// Creates a [MalformedFixture].
  const MalformedFixture(this.reason);

  /// What is wrong with the directives.
  final String reason;
}

/// Every directive key upstream's datatest runner understands at v0.0.23.
///
/// A directive-shaped comment whose key is not here makes the fixture
/// [MalformedFixture]. `Return.type` is listed so its rejection says "not
/// implemented" rather than "unknown".
const knownFixtureDirectives = <String>{
  'xfail',
  'call-external',
  'run-async',
  'mount-fs',
  'gc-interval',
  'timezone',
  'skip-cpython-windows',
  'cpython-main-module',
  'Raise',
  'Return',
  'Return.str',
  'Return.type',
  'ref-counts',
};

const _expectationKeys = <String>{
  'Raise',
  'Return',
  'Return.str',
  'Return.type',
  'ref-counts',
};

/// `key` or `key=value`, where a bare key must contain `-` or `.` to count as
/// directive-shaped. A one-word prose comment (`# membership`) is not.
final _directiveShape = RegExp(
  r'^([A-Za-z][A-Za-z0-9_]*(?:[.-][A-Za-z0-9_]+)*)(=.*)?$',
);

/// The unindented comment lines among [lines], `#`s stripped and trimmed —
/// upstream's `comment_lines`.
List<String> _commentLines(List<String> lines) => [
  for (final l in lines)
    if (l.startsWith('#')) l.replaceFirst(RegExp('^#+'), '').trim(),
];

/// Splits like Rust's `str::lines`: CRLF folded, one trailing empty dropped.
List<String> _lines(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

  return lines;
}

bool _hasConfig(String source, String key) =>
    _commentLines(_lines(source)).any((c) => c.startsWith(key));

/// Returns `true` when [source] declares a `# call-external` directive,
/// meaning the fixture requires external function dispatch to run.
bool fixtureIsCallExternal(String source) =>
    _hasConfig(source, 'call-external');

/// Returns `true` when [source] declares a `# run-async` directive,
/// meaning the fixture uses top-level `await` and requires async dispatch.
bool fixtureIsRunAsync(String source) => _hasConfig(source, 'run-async');

/// Returns `true` when [source] declares a `# mount-fs` directive,
/// meaning the fixture expects a `root` Path variable pointing to a
/// pre-populated virtual filesystem.
bool fixtureMountsFs(String source) => _hasConfig(source, 'mount-fs');

/// The integer a `# gc-interval=<N>` directive names, or null when [source]
/// has none (upstream's `parse_usize_directive`: the value ends at the first
/// whitespace).
int? fixtureGcInterval(String source) {
  final line = _commentLines(
    _lines(source),
  ).where((c) => c.startsWith('gc-interval=')).firstOrNull;
  if (line == null) return null;

  return int.tryParse(
    line.substring('gc-interval='.length).split(RegExp(r'\s')).first,
  );
}

/// The IANA zone a `# timezone=<NAME>` directive names, or null when
/// [source] has none (upstream's `parse_str_directive`: the value ends at the
/// first whitespace).
String? fixtureTimezone(String source) {
  final line = _commentLines(
    _lines(source),
  ).where((c) => c.startsWith('timezone=')).firstOrNull;
  if (line == null) return null;

  return line.substring('timezone='.length).split(RegExp(r'\s')).first;
}

/// Why the directives in [lines] are malformed, or null when well formed.
String? _directiveProblem(List<String> lines, {required bool hasTraceback}) {
  // Header block: leading lines that are blank or comments.
  final header = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.trim().isEmpty) continue;
    if (!l.startsWith('#')) break;
    header.add(i);
  }
  final last = lines.length - 1;
  for (final i in {...header, if (last >= 0) last}) {
    final l = lines[i];
    if (!l.startsWith('#')) continue;
    final body = l.replaceFirst(RegExp('^#+'), '').trim();
    final m = _directiveShape.firstMatch(body);
    if (m == null) continue;
    final key = m.group(1)!;
    final isAssignment = m.group(2) != null;
    if (!isAssignment && !key.contains('-') && !key.contains('.')) continue;
    if (!knownFixtureDirectives.contains(key)) {
      return 'unknown directive `# $key${isAssignment ? '=' : ''}` on line '
          '${i + 1}; known: ${knownFixtureDirectives.join(', ')}';
    }
  }

  // Expectation directives anywhere but the last line are ignored upstream.
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (!l.startsWith('# ')) continue;
    final key = l.substring(2).split('=').first;
    if (i != last && l.contains('=') && _expectationKeys.contains(key)) {
      return '`# $key=` on line ${i + 1} is not the last line, where upstream '
          'reads expectations — it would be silently ignored';
    }
  }
  if (hasTraceback && last >= 0) {
    final key = lines[last].startsWith('# ')
        ? lines[last].substring(2).split('=').first
        : '';
    if (lines[last].contains('=') && _expectationKeys.contains(key)) {
      return 'both a TRACEBACK docstring and `# $key=`; upstream silently '
          'uses the docstring';
    }
  }

  final comments = _commentLines(lines);
  final xfail = comments.where((c) => c.startsWith('xfail=')).firstOrNull;
  if (xfail != null) {
    final value = xfail.substring('xfail='.length).split(RegExp(r'\s')).first;
    final bad = value
        .split(',')
        .where((t) => t != 'monty' && t != 'cpython')
        .toList();
    if (value.isEmpty || bad.isNotEmpty) {
      return '`# $xfail`: xfail targets must be `monty` and/or `cpython`';
    }
  }
  final gc = comments.where((c) => c.startsWith('gc-interval=')).firstOrNull;
  if (gc != null) {
    final v = gc.substring('gc-interval='.length).split(RegExp(r'\s')).first;
    if (int.tryParse(v) == null) return '`# $gc`: not an integer';
  }

  return null;
}

/// Parses a `.py` fixture and returns the expected outcome.
///
/// Returns `null` when the fixture should be skipped because it needs a mode
/// the caller did not opt into: `# call-external` (unless [skipCallExternal]
/// is false), `# run-async` (unless [skipRunAsync] is false), `# mount-fs`
/// (unless [skipMountFs] is false).
///
/// Never returns null for malformed directives — that is [MalformedFixture],
/// checked first so a skipped mode cannot hide it.
///
/// `# xfail=monty` yields [ExpectXfail]: the fixture RUNS, and must fail.
/// `# xfail=cpython` changes nothing here — monty is expected to pass.
FixtureExpectation? parseFixture(
  String source, {
  bool skipCallExternal = true,
  bool skipMountFs = true,
  bool skipRunAsync = true,
}) {
  final lines = _lines(source);
  final traceback = _parseTracebackDocstring(source);

  final problem = _directiveProblem(lines, hasTraceback: traceback != null);
  if (problem != null) return MalformedFixture(problem);

  final comments = _commentLines(lines);
  bool has(String key) => comments.any((c) => c.startsWith(key));
  if ((skipCallExternal && has('call-external')) ||
      (skipRunAsync && has('run-async')) ||
      (skipMountFs && has('mount-fs'))) {
    return null;
  }

  final expectation = traceback ?? _parseLastLine(lines);
  final xfail = comments.where((c) => c.startsWith('xfail=')).firstOrNull;
  if (xfail != null && xfail.contains('monty')) {
    return ExpectXfail(expectation);
  }

  return expectation;
}

FixtureExpectation _parseLastLine(List<String> lines) {
  final last = lines.isEmpty ? '' : lines.last;
  if (last.startsWith('# ref-counts=')) return const ExpectNoException();
  if (last.startsWith('# Return.str=')) {
    return ExpectReturnStr(last.substring('# Return.str='.length));
  }
  if (last.startsWith('# Return.type=')) {
    return const MalformedFixture(
      '`# Return.type=` is upstream vocabulary this adjudicator does not '
      'implement',
    );
  }
  if (last.startsWith('# Return=')) {
    final raw = last.substring('# Return='.length);

    return ExpectReturn(_parseReturnValue(raw), repr: raw);
  }
  if (last.startsWith('# Raise=')) {
    return _parseRaise(last.substring('# Raise='.length));
  }

  return const ExpectNoException();
}

/// Upstream's `parse_traceback_expectation`: the text between
/// `"""\nTRACEBACK:\n` and the next `\n"""`, verbatim.
ExpectRaise? _parseTracebackDocstring(String source) {
  const marker = '"""\nTRACEBACK:\n';
  final content = source.replaceAll('\r\n', '\n');
  final start = content.indexOf(marker);
  if (start < 0) return null;
  final after = content.substring(start + marker.length);
  final end = after.indexOf('\n"""');
  if (end < 0) return null;
  final block = after.substring(0, end);

  // excType/message are informational; the comparison uses [block].
  final finalLine = block.split('\n').last;
  final colon = finalLine.indexOf(': ');
  final excType = colon < 0 ? finalLine : finalLine.substring(0, colon);
  final message = colon < 0 ? '' : finalLine.substring(colon + 2);

  return ExpectRaise(excType: excType, message: message, traceback: block);
}

Object? _parseReturnValue(String raw) {
  final trimmed = raw.trim();

  // Nested list/dict reprs (only the cyclic fixtures use these). A bracket pair
  // containing just `...` is the cycle marker, which the engine serialises as a
  // tagged `cycle` envelope, so it parses to the matching typed value.
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    final parser = _ReprParser(trimmed);
    final value = parser.tryParse();
    if (value != _ReprParser.failed) return value;
    // Fall through to scalar handling on parse failure.
  }

  return _parseScalarRepr(trimmed);
}

Object? _parseScalarRepr(String raw) {
  if (raw == 'None') return null;
  if (raw == 'True') return true;
  if (raw == 'False') return false;

  final asInt = int.tryParse(raw);
  if (asInt != null) return asInt;

  final asDouble = double.tryParse(raw);
  if (asDouble != null) {
    // Typed, not a bare Dart double. The directive's TEXT is the only place the
    // int/float distinction reliably survives: on dart2js `2.0 is int` is true,
    // so by the time a caller reaches MontyValue.fromDart the double is
    // indistinguishable from an int and yields MontyInt(2). MontyValue.fromDart
    // passes a MontyValue through unchanged, so no call site changes.
    return MontyFloat(asDouble);
  }

  if ((raw.startsWith("'") && raw.endsWith("'")) ||
      (raw.startsWith('"') && raw.endsWith('"'))) {
    return raw.substring(1, raw.length - 1);
  }

  return raw;
}

/// Minimal recursive-descent parser for the Python-repr subset used in
/// `# Return=` directives: nested lists/dicts, scalars, and the cycle
/// markers `[...]` / `{...}`, which become `MontyOpaque(cycle, …)` since wire
/// format v3 gave the cycle marker its own type.
class _ReprParser {
  _ReprParser(this._s);

  static const Object failed = Object();

  final String _s;
  int _i = 0;
  bool _error = false;

  Object? tryParse() {
    final value = _value();
    _skipSpace();
    if (_error || _i != _s.length) return failed;

    return value;
  }

  Object? _value() {
    _skipSpace();
    if (_i >= _s.length) {
      _error = true;

      return null;
    }
    final c = _s[_i];
    if (c == '[') return _collection(']', '[...]', isDict: false);
    if (c == '{') return _collection('}', '{...}', isDict: true);

    return _scalar();
  }

  Object? _collection(String close, String marker, {required bool isDict}) {
    _i++; // consume the already-matched opening bracket
    _skipSpace();
    if (_peek() == '.') {
      // `...` is the cycle marker. Since wire format v3 the engine sends it as
      // `{"__type":"cycle","text":"[...]"}` rather than the bare string
      // `[...]`, so the expectation must be the typed value, or comparison
      // fails with two values that PRINT identically — how this was found:
      //   "expected MontyList(1 items), got MontyList(1 items)"
      if (!_consume('...')) return null;
      _skipSpace();
      if (!_consume(close)) return null;

      return MontyOpaque(MontyOpaqueKind.cycle, marker);
    }
    final list = <Object?>[];
    final map = <String, Object?>{};
    while (true) {
      _skipSpace();
      if (_peek() == close) {
        _i++;
        break;
      }
      final key = _value();
      if (_error) return null;
      if (isDict) {
        _skipSpace();
        if (!_consume(':')) return null;
        final val = _value();
        if (_error) return null;
        map['$key'] = val;
      } else {
        list.add(key);
      }
      _skipSpace();
      if (_peek() == ',') {
        _i++;
      }
    }

    return isDict ? map : list;
  }

  Object? _scalar() {
    final start = _i;
    final first = _peek();
    if (first == "'" || first == '"') {
      _i++;
      final buf = StringBuffer();
      while (_i < _s.length && _s[_i] != first) {
        buf.write(_s[_i]);
        _i++;
      }
      if (_i >= _s.length) {
        _error = true;

        return null;
      }
      _i++; // closing quote

      return buf.toString();
    }
    while (_i < _s.length && !',]}:'.contains(_s[_i])) {
      _i++;
    }

    return _parseScalarRepr(_s.substring(start, _i).trim());
  }

  String _peek() => _i < _s.length ? _s[_i] : '';

  bool _consume(String token) {
    if (_s.startsWith(token, _i)) {
      _i += token.length;

      return true;
    }
    _error = true;

    return false;
  }

  void _skipSpace() {
    while (_i < _s.length && _s[_i] == ' ') {
      _i++;
    }
  }
}

/// `# Raise=` text. [ExpectRaise.repr] keeps it verbatim — that is what is
/// compared; type and message are split out for display only.
FixtureExpectation _parseRaise(String raw) {
  final parenIdx = raw.indexOf('(');
  if (parenIdx < 0) {
    return ExpectRaise(excType: raw.trim(), message: '', repr: raw);
  }
  final excType = raw.substring(0, parenIdx).trim();
  final msgRaw = raw.substring(parenIdx + 1, raw.length - 1).trim();

  final message =
      ((msgRaw.startsWith("'") && msgRaw.endsWith("'")) ||
          (msgRaw.startsWith('"') && msgRaw.endsWith('"')))
      ? msgRaw.substring(1, msgRaw.length - 1)
      : msgRaw;

  return ExpectRaise(excType: excType, message: message, repr: raw);
}
