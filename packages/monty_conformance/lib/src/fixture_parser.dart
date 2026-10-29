// Fixture directive parser for upstream monty's `test_cases/*.py`.
//
// THE FORMAT IS UPSTREAM'S, AND SO ARE ITS RULES. The reference is
// `parse_fixture` in monty's `crates/monty-datatest/src/main.rs` at the
// pinned tag (tool/upstream/upstream-pin.json):
//
//   * Config directives come in TWO forms, and both are read here. The OLD
//     one (upstream 1.1.0) is unindented comment lines anywhere in the file,
//     matched by prefix: `xfail=`, `call-external`, `run-async`, `mount-fs`,
//     `timezone=`, `gc-interval=`, `skip-cpython-windows`,
//     `cpython-main-module`. The NEW one (upstream 1.2.0) is the `# /// monty`
//     HEADER BLOCK, which upstream reads with `monty_fixture::Header::parse`
//     (`crates/monty-fixture/src/lib.rs`): a PEP 723 comment block whose TOML
//     carries the same names in kebab-case — `xfail = ['monty']`,
//     `timezone = 'Asia/Kathmandu'`, `gc-interval = 200`,
//     `call-external = true` — and which closes with a `# ///` line.
//
//     The block is read here by upstream's own reader, and by its rules:
//     `extract_block` finds the block (it must open with the exact line
//     `# /// monty`, before any code, and there may be only one),
//     `read_block_body` reads the lines after it (a line that is `#` alone is
//     an empty line, a line that starts with `# ` is one line of TOML) and
//     `toml::from_str` reads the TOML they spell — so a key may be set only
//     once, a key upstream's `Header` does not have is an error, and the
//     block's lines are never read as flat directives.
//
//     The TOML is read by the `toml` crate's rules, so the block's own
//     shapes are the ones upstream accepts: a dotted key (`bench.data = ...`)
//     names a table's field, a quoted key (`"gc-interval" = 200`) is a key,
//     an inline table (`bench = { mount = true }`) is a table, and a value
//     that does not fit the field it fills is an error. A newline may stand
//     where a space may inside an inline table — `bench = { mount =` and the
//     `true }` on the next line are one pair — and a line may end with a
//     CRLF, which the crate reads as one newline (`toml_parser`'s
//     `decode_newline` takes a carriage return only when a newline follows
//     it). Where the TOML 1.1 grammar and the crate disagree, the crate is
//     what upstream reads: upstream v1.2.0's `Cargo.lock` pins `toml` 1.1.6
//     and `toml_parser` 1.1.3, and `Header::parse` reads the block with
//     `toml::from_str`.
//
//     The values themselves are read by the same crate's rules, so they are
//     read here by the same ones: a key may not be set twice — not at the
//     top level and not inside an inline table — a multiline string
//     (`"""…"""`) drops the newline that follows its opening delimiter and
//     reads a backslash at the end of a line as a continuation, and an
//     integer may carry a sign only in decimal (`0x10` may not be signed).
//     A string carries no control character other than a tab (a multiline
//     string carries a newline, LF or CRLF), and an escape spells its
//     character: the single-character ones, and the `\x`, `\u` and `\U`
//     forms, which carry a Unicode scalar value in exactly two, four or
//     eight hexadecimal digits, so a surrogate is an error there and here.
//
//     A value is one of the four scalar kinds the crate reads — a boolean,
//     an integer, a float or a date-time — so all of them are read here: a
//     float is a decimal number with a fraction and/or an exponent or one
//     of the special floats `inf` and `nan`, and a date-time is one of
//     TOML's four date-time shapes (a local date, a local date-time, a
//     local time, or an offset date-time). A value upstream never reads —
//     an element past the four fields of its `Bench`, say — is a value
//     here too, so it does not make the fixture malformed: upstream drops
//     it, and so does this parser.
//
//     The block's own text is read the way Rust reads it. Upstream's
//     `extract_block` asks whether a line comes before any code with Rust's
//     `str::trim`, whose whitespace is the Unicode `White_Space` property:
//     Dart's own whitespace less a byte order mark (U+FEFF), which Dart's
//     `trim()` takes for whitespace and Rust's does not, so a line that
//     carries one is code, not a blank line. The `toml_parser` lexer skips
//     one byte order mark at the start of the TOML it reads (`Lexer::new`,
//     which takes the BOM off the front of the input), so a block whose
//     first body line starts with one spells the TOML that follows it.
//
//     The text of the block carries no control character other than a tab
//     and a newline, and a carriage return only as part of a CRLF: the
//     `toml` crate's decoder refuses every other control character wherever
//     it stands — in a string, in a comment (a comment carries a tab, the
//     printable ASCII and the non-ASCII characters, and nothing else) and
//     outside one — so the block is refused here too. The whitespace TOML
//     counts is a space and a tab and nothing else, so a value padded with
//     any other whitespace (`gc-interval = <no-break space>200`) is not a
//     value, and neither is it one to the `toml` crate.
//
//     The block wins where it speaks; the flat lines still work.
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
//   * a directive-shaped line in the leading comments or on the last line
//     whose key is not in [knownFixtureDirectives];
//   * an expectation directive anywhere but the last line;
//   * a TRACEBACK docstring AND an expectation line (upstream silently picks
//     the docstring);
//   * an `xfail=` target other than `monty` / `cpython`, or a non-integer
//     `gc-interval=`, and the same mistakes in the `# /// monty` header: a key
//     upstream's `Header` does not have (it denies unknown fields), an
//     `xfail` target that is not `monty` / `cpython`, a `timezone` that is
//     not a quoted string, a `gc-interval` that is not an integer, a key set
//     twice (TOML refuses that) or a value of the wrong type;
//   * `# Return.type=`, which is upstream vocabulary this adjudicator does not
//     implement — failing loudly beats asserting nothing.
//
// Returns null when the caller asked to skip the fixture's mode.

import 'package:dart_monty_core/dart_monty_core.dart';

/// What a fixture's directives say must happen when it runs.
//
// The file is named for the PARSER; the type it parses into is the
// expectation, and that type is the package's public vocabulary — the
// adjudicator, the worker runner and their callers all name it.
// ignore: prefer-match-file-name
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

/// Every directive key upstream's datatest runner understands at the pinned
/// tag.
///
/// A directive-shaped comment whose key is not here makes the fixture
/// [MalformedFixture]. `Return.type` is listed so its rejection says "not
/// implemented" rather than "unknown".
const knownFixtureDirectives = {
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

const _expectationKeys = {
  'Raise',
  'Return',
  'Return.str',
  'Return.type',
  'ref-counts',
};

/// The keys upstream's `# /// monty` header carries at v1.2.0, and the type
/// each one's value must have.
///
/// Upstream reads the header into `monty_fixture::Header`
/// (`crates/monty-fixture/src/lib.rs`), whose fields are these names in
/// kebab-case; `deny_unknown_fields` makes a key that is not one of them an
/// error there, so it is one here too. The types are the fields' types:
/// serde refuses a value that does not fit the field it fills.
const Map<String, _ValueType> _headerTypes = {
  'call-external': _ValueType.boolean,
  'run-async': _ValueType.boolean,
  'mount-fs': _ValueType.boolean,
  'skip-cpython-windows': _ValueType.boolean,
  'cpython-main-module': _ValueType.boolean,
  'xfail': _ValueType.stringList,
  'gc-interval': _ValueType.integer,
  'timezone': _ValueType.string,
};

/// The keys of upstream's `[bench]` table, and the type each one's value
/// must have.
///
/// The table is upstream's own (`crates/monty-fixture/src/lib.rs`), read by
/// `monty-bench` rather than by the datatest harness, but it is part of the
/// header, so a key that is not one of these is an error here too.
const Map<String, _ValueType> _benchTypes = {
  'data': _ValueType.string,
  'mount': _ValueType.boolean,
  'overlay': _ValueType.boolean,
  'limits': _ValueType.boolean,
};

/// The line that opens a monty header block (upstream's `BLOCK_START`).
const _blockStart = '# /// monty';

/// The line that closes a monty header block (upstream's `BLOCK_END`).
const _blockEnd = '# ///';

/// The type of a header value, as the `Header` field it fills.
enum _ValueType {
  /// A TOML boolean, `true` or `false`.
  boolean('a boolean'),

  /// A TOML integer, as `usize`: a whole number that is not negative and
  /// fits in 64 bits.
  integer('a non-negative integer'),

  /// A TOML string.
  string('a string'),

  /// A TOML array of strings.
  stringList('a list of strings');

  const _ValueType(this.label);

  /// How the type is named in a complaint about a value.
  final String label;
}

/// A TOML float, as the `toml` crate reads one.
///
/// No field of upstream's `Header` takes a float, so the value is kept as
/// the text it was spelled with: it is a value the crate reads, and one this
/// parser must not call malformed — upstream ignores the values past the
/// four fields of its `Bench`, and a float is one of them.
final class _TomlFloat {
  const _TomlFloat(this.text);

  /// The text the float was spelled with.
  final String text;
}

/// A TOML date-time, as the `toml` crate reads one.
///
/// No field of upstream's `Header` takes a date-time, so the value is kept
/// as the text it was spelled with: it is a value the crate reads, and one
/// this parser must not call malformed — upstream ignores the values past
/// the four fields of its `Bench`, and a date-time is one of them.
final class _TomlDateTime {
  const _TomlDateTime(this.text);

  /// The text the date-time was spelled with.
  final String text;
}

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

/// The code units Rust's `char::is_whitespace` calls whitespace: the Unicode
/// `White_Space` property — a tab to a carriage return, a space, U+0085,
/// U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F and
/// U+3000.
///
/// Dart's own whitespace is these plus a byte order mark (U+FEFF), which
/// Rust does not trim.
const Set<int> _rustWhitespaceCodes = {
  0x09,
  0x0a,
  0x0b,
  0x0c,
  0x0d,
  0x20,
  0x85,
  0xa0,
  0x1680,
  0x2000,
  0x2001,
  0x2002,
  0x2003,
  0x2004,
  0x2005,
  0x2006,
  0x2007,
  0x2008,
  0x2009,
  0x200a,
  0x2028,
  0x2029,
  0x202f,
  0x205f,
  0x3000,
};

/// Whether [code] is whitespace as Rust's `char::is_whitespace` sees it.
bool _isRustWhitespace(int code) => _rustWhitespaceCodes.contains(code);

/// [text] without the whitespace at its ends, as Rust's `str::trim` sees it.
///
/// Upstream's `extract_block` reads a line with Rust's `str::trim`, whose
/// whitespace is the Unicode `White_Space` property (see
/// [_isRustWhitespace]); Dart's `trim()` would also take a byte order mark
/// for whitespace, and Rust's does not.
String _rustTrim(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && _isRustWhitespace(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isRustWhitespace(text.codeUnitAt(end - 1))) {
    end--;
  }

  return text.substring(start, end);
}

/// [text] without the whitespace at its start, as Rust's `str::trim_start`
/// sees it.
///
/// Upstream's `is_block_marker` reads a line with Rust's `str::trim_start`,
/// whose whitespace is the Unicode `White_Space` property (see
/// [_isRustWhitespace]); Dart's `trimLeft()` would also take a byte order
/// mark for whitespace, and Rust's does not.
String _rustTrimStart(String text) {
  var start = 0;
  while (start < text.length && _isRustWhitespace(text.codeUnitAt(start))) {
    start++;
  }

  return text.substring(start);
}

/// Whether [lines] carry a flat directive that starts with [key].
///
/// The lines of a `# /// monty` block are not flat directives — upstream
/// reads them as TOML — so they are left out.
bool _hasConfig(List<String> lines, Set<int> blockLines, String key) =>
    _commentLines(_flatLines(lines, blockLines)).any((c) => c.startsWith(key));

/// The boolean the `# /// monty` header's [key] carries, or null when the
/// header does not carry it.
bool? _headerFlag(_Header header, String key) {
  final value = header.values[key];

  return value is bool ? value : null;
}

/// Returns `true` when [source] declares a `# call-external` directive,
/// meaning the fixture requires external function dispatch to run.
///
/// The directive is the flat `# call-external` line of upstream 1.1.0 or the
/// `call-external = true` line of upstream 1.2.0's `# /// monty` header.
bool fixtureIsCallExternal(String source) {
  final lines = _lines(source);
  final header = _readHeader(lines);

  return _headerFlag(header, 'call-external') ??
      _hasConfig(lines, header.blockLines, 'call-external');
}

/// Returns `true` when [source] declares a `# run-async` directive,
/// meaning the fixture uses top-level `await` and requires async dispatch.
///
/// The directive is the flat `# run-async` line of upstream 1.1.0 or the
/// `run-async = true` line of upstream 1.2.0's `# /// monty` header.
bool fixtureIsRunAsync(String source) {
  final lines = _lines(source);
  final header = _readHeader(lines);

  return _headerFlag(header, 'run-async') ??
      _hasConfig(lines, header.blockLines, 'run-async');
}

/// Returns `true` when [source] declares a `# mount-fs` directive,
/// meaning the fixture expects a `root` Path variable pointing to a
/// pre-populated virtual filesystem.
///
/// The directive is the flat `# mount-fs` line of upstream 1.1.0 or the
/// `mount-fs = true` line of upstream 1.2.0's `# /// monty` header.
bool fixtureMountsFs(String source) {
  final lines = _lines(source);
  final header = _readHeader(lines);

  return _headerFlag(header, 'mount-fs') ??
      _hasConfig(lines, header.blockLines, 'mount-fs');
}

/// The integer a `# gc-interval=<N>` directive names, or null when [source]
/// has none (upstream's `parse_usize_directive`: the value ends at the first
/// whitespace).
///
/// The directive is the flat `# gc-interval=<N>` line of upstream 1.1.0 or the
/// `gc-interval = <N>` line of upstream 1.2.0's `# /// monty` header.
int? fixtureGcInterval(String source) {
  final lines = _lines(source);
  final header = _readHeader(lines);
  final block = header.values['gc-interval'];
  if (block is int) return block;
  // An interval the `toml` crate reads but Dart's `int` cannot hold is a
  // value no worker can use: it is read as no interval at all.
  if (block is BigInt) return block.isValidInt ? block.toInt() : null;
  final line = _commentLines(
    _flatLines(lines, header.blockLines),
  ).where((c) => c.startsWith('gc-interval=')).firstOrNull;
  if (line == null) return null;

  return int.tryParse(
    line.substring('gc-interval='.length).split(RegExp(r'\s')).firstOrNull ??
        '',
  );
}

/// The IANA zone a `# timezone=<NAME>` directive names, or null when
/// [source] has none (upstream's `parse_str_directive`: the value ends at the
/// first whitespace).
///
/// The directive is the flat `# timezone=<NAME>` line of upstream 1.1.0 or the
/// `timezone = '<NAME>'` line of upstream 1.2.0's `# /// monty` header, whose
/// value is a quoted string.
String? fixtureTimezone(String source) {
  final lines = _lines(source);
  final header = _readHeader(lines);
  final block = header.values['timezone'];
  if (block is String) return block;
  final line = _commentLines(
    _flatLines(lines, header.blockLines),
  ).where((c) => c.startsWith('timezone=')).firstOrNull;
  if (line == null) return null;

  return line.substring('timezone='.length).split(RegExp(r'\s')).firstOrNull;
}

/// Why the directives in [lines] are malformed, or null when well formed.
String? _directiveProblem(List<String> lines, {required bool hasTraceback}) {
  // The `# /// monty` header of upstream 1.2.0, read as upstream reads it.
  final header = _readHeader(lines);
  if (header.problem != null) return header.problem;

  final unknown = _unknownDirectiveProblem(lines, header.blockLines);
  if (unknown != null) return unknown;

  final misplaced = _misplacedExpectationProblem(lines, header.blockLines);
  if (misplaced != null) return misplaced;

  if (hasTraceback) {
    final contradiction = _tracebackExpectationProblem(lines);
    if (contradiction != null) return contradiction;
  }

  return _flatValueProblem(lines, header.blockLines);
}

/// Why a directive-shaped comment names a key upstream does not have, or null
/// when every such comment names one it does.
///
/// The lines of a `# /// monty` block are TOML, not flat directives, so they
/// are not read here.
String? _unknownDirectiveProblem(List<String> lines, Set<int> blockLines) {
  final last = lines.length - 1;
  for (final i in {..._leadingCommentLines(lines), if (last >= 0) last}) {
    if (blockLines.contains(i)) continue;
    final l = lines.elementAtOrNull(i);
    if (l == null) continue;
    if (!l.startsWith('#')) continue;
    final problem = _unknownDirectiveOn(l, i + 1);
    if (problem != null) return problem;
  }

  return null;
}

/// Why the comment on line [number] names a key upstream does not have, or null
/// when it does not name a directive at all.
String? _unknownDirectiveOn(String line, int number) {
  final body = line.replaceFirst(RegExp('^#+'), '').trim();
  final m = _directiveShape.firstMatch(body);
  if (m == null) return null;
  final key = m.group(1);
  if (key == null) return null;
  final isAssignment = m.group(2) != null;
  if (!isAssignment && !key.contains('-') && !key.contains('.')) return null;
  if (knownFixtureDirectives.contains(key)) return null;

  return 'unknown directive `# $key${isAssignment ? '=' : ''}` on line '
      '$number; known: ${knownFixtureDirectives.join(', ')}';
}

/// The indices of the leading lines of [lines] that are blank or comments —
/// upstream's header block.
List<int> _leadingCommentLines(List<String> lines) {
  final header = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final l = lines.elementAtOrNull(i);
    if (l == null) continue;
    if (l.trim().isEmpty) continue;
    if (!l.startsWith('#')) break;
    header.add(i);
  }

  return header;
}

/// Why an expectation directive sits where upstream would not read it, or null
/// when every one of them sits where it does.
///
/// The lines of a `# /// monty` block are TOML, not flat directives, so they
/// are not read here.
String? _misplacedExpectationProblem(List<String> lines, Set<int> blockLines) {
  final last = lines.length - 1;
  for (var i = 0; i < lines.length; i++) {
    if (blockLines.contains(i)) continue;
    final l = lines.elementAtOrNull(i);
    if (l == null) continue;
    if (!l.startsWith('# ')) continue;
    final key = l.substring(2).split('=').firstOrNull ?? '';
    if (i != last && l.contains('=') && _expectationKeys.contains(key)) {
      return '`# $key=` on line ${i + 1} is not the last line, where upstream '
          'reads expectations — it would be silently ignored';
    }
  }

  return null;
}

/// Why the last line's expectation contradicts a TRACEBACK docstring, or null
/// when the two do not contradict each other.
String? _tracebackExpectationProblem(List<String> lines) {
  final last = lines.length - 1;
  if (last < 0) return null;
  final lastLine = lines.elementAtOrNull(last) ?? '';
  if (!lastLine.contains('=')) return null;
  final key = lastLine.startsWith('# ')
      ? lastLine.substring(2).split('=').firstOrNull ?? ''
      : '';
  if (!_expectationKeys.contains(key)) return null;

  return 'both a TRACEBACK docstring and `# $key=`; upstream silently '
      'uses the docstring';
}

/// Why a flat directive's value is malformed, or null when they are well
/// formed.
///
/// The lines of a `# /// monty` block are TOML, not flat directives, so they
/// are not read here.
String? _flatValueProblem(List<String> lines, Set<int> blockLines) {
  final comments = _commentLines(_flatLines(lines, blockLines));
  final xfail = comments.where((c) => c.startsWith('xfail=')).firstOrNull;
  if (xfail != null) {
    final value =
        xfail.substring('xfail='.length).split(RegExp(r'\s')).firstOrNull ?? '';
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
    final v =
        gc.substring('gc-interval='.length).split(RegExp(r'\s')).firstOrNull ??
        '';
    if (int.tryParse(v) == null) return '`# $gc`: not an integer';
  }

  return null;
}

/// A fixture's `# /// monty` header block: the directives it carries, the
/// problem that made it unreadable, and the lines its body occupies.
final class _Header {
  const _Header({
    required this.values,
    required this.problem,
    required this.blockLines,
    required this.endIndex,
  });

  /// The directives the block carries, by key, with their values.
  final Map<String, Object?> values;

  /// Why the block could not be read, or null when it could.
  final String? problem;

  /// The indices of the lines the block's body occupies.
  final Set<int> blockLines;

  /// The index of the line that closes the block, or -1 when there is none.
  final int endIndex;

  /// The header of a source that carries no block.
  static const none = _Header(
    values: {},
    problem: null,
    blockLines: {},
    endIndex: -1,
  );
}

/// A header that could not be read, for the reason [problem] names.
_Header _headerProblem(String problem) => _Header(
  values: const {},
  problem: problem,
  blockLines: const {},
  endIndex: -1,
);

/// Reads the `# /// monty` header block out of [lines], if it has one.
///
/// Upstream's reader is `monty_fixture::Header::parse` (upstream v1.2.0,
/// `crates/monty-fixture/src/lib.rs`): `extract_block` finds the block,
/// `read_block_body` reads the lines that follow it, and `toml::from_str`
/// reads the TOML they spell. This is that reader, and its rules:
///
///   * the block opens with the exact line `# /// monty` and closes with
///     `# ///`; a block after code, a second block, or any other `# ///`
///     line is an error;
///   * every body line is `#` alone (an empty line) or `# ` plus content,
///     which is one line of TOML;
///   * the content is TOML, so a key may be set only once, a key upstream's
///     `Header` does not have is an error, and the text carries no control
///     character other than a tab and a newline.
_Header _readHeader(List<String> lines) {
  var beforeCode = true;
  var header = _Header.none;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    beforeCode =
        beforeCode && (line.startsWith('#') || _rustTrim(line).isEmpty);
    if (!_isBlockMarker(line)) continue;
    if (line != _blockStart) {
      return _headerProblem(
        "line ${index + 1}: `$line` is not `# /// monty` or a block's "
        'closing `# ///`',
      );
    }
    if (!beforeCode) {
      return _headerProblem(
        'line ${index + 1}: `# /// monty` must come before any code',
      );
    }
    if (header.endIndex >= 0) {
      return _headerProblem('line ${index + 1}: second `# /// monty` block');
    }
    final body = _readBlockBody(lines, index);
    if (body.problem != null) return body;
    header = body;
    index = body.endIndex;
  }

  return header;
}

/// Reads the body of the header block that opens at [start].
///
/// Upstream's `read_block_body` (upstream v1.2.0,
/// `crates/monty-fixture/src/lib.rs`) reads the lines after the opening
/// marker up to the closing `# ///`: a line that is `#` alone is an empty
/// line, and a line that starts with `# ` is one line of TOML.
_Header _readBlockBody(List<String> lines, int start) {
  final entries = <({String text, int number})>[];
  final blockLines = <int>{};
  var index = start + 1;
  for (; index < lines.length; index++) {
    final line = lines.elementAtOrNull(index);
    if (line == null) break;
    if (line == _blockEnd) break;
    blockLines.add(index);
    if (line != '#' && !line.startsWith('# ')) {
      return _headerProblem(
        'line ${index + 1}: `$line` inside the `# /// monty` header is not a '
        '`# ` comment',
      );
    }
    entries.add((
      text: line == '#' ? '' : line.substring(2),
      number: index + 1,
    ));
  }
  if (index >= lines.length) {
    return _headerProblem('line ${start + 1}: `# /// monty` is never closed');
  }
  final parsed = _parseHeaderToml(entries);
  if (parsed.problem case final String reason) {
    return _headerProblem(reason);
  }

  return _Header(
    values: parsed.values,
    problem: null,
    blockLines: blockLines,
    endIndex: index,
  );
}

/// The values upstream's header carries, read from [entries] as TOML, or the
/// problem with them.
///
/// Upstream reads the block with the `toml` crate
/// (`crates/monty-fixture/src/lib.rs`), so the TOML is read by the same rules:
/// a key may be set only once, a dotted key names a table's field, a quoted
/// key is a key, and a value's type must fit the field it fills. Each entry
/// names the file line it came from, for the complaints.
({Map<String, Object?> values, String? problem}) _parseHeaderToml(
  List<({String text, int number})> entries,
) {
  final document = _TomlDocument.read(entries);
  if (document.problem case final String reason) {
    return (values: const {}, problem: reason);
  }

  return (values: document.root, problem: null);
}

/// A TOML document read out of a `# /// monty` header block.
///
/// The document holds the header's own keys and the reason it could not be
/// read.
final class _TomlDocument {
  const _TomlDocument({required this.root, required this.problem});

  /// Reads the TOML the [entries] of a header block spell.
  factory _TomlDocument.read(List<({String text, int number})> entries) {
    final scanner = _TomlScanner(entries);
    final characters = scanner.characterProblem();
    if (characters != null) {
      return _TomlDocument(root: const {}, problem: characters);
    }
    final state = _TomlState();
    while (true) {
      scanner.skipBlank();
      if (scanner.atEnd) break;
      final problem = scanner.peek == '['
          ? _readTable(scanner, state)
          : _readEntry(scanner, state);
      if (problem != null) {
        return _TomlDocument(root: const {}, problem: problem);
      }
    }

    return _TomlDocument(root: state.root, problem: null);
  }

  /// The header's own keys, by name.
  final Map<String, Object?> root;

  /// Why the document could not be read, or null when it could.
  final String? problem;
}

/// The state of a header block's TOML as it is read: the keys set so far,
/// and the table the reader is in.
final class _TomlState {
  /// The header's own keys, by name.
  final Map<String, Object?> root = <String, Object?>{};

  /// The `[bench]` table's keys, by name.
  final Map<String, Object?> bench = <String, Object?>{};

  /// Whether the `[bench]` table has been declared.
  bool benchDeclared = false;

  /// Whether the `[bench]` table was set as an inline table, which cannot be
  /// extended afterwards.
  bool benchInline = false;

  /// Whether the `[bench]` table was set as a sequence of values, which
  /// cannot be extended afterwards either.
  bool benchSeq = false;

  /// Whether the reader is inside the `[bench]` table.
  bool inBench = false;

  /// Whether the `[bench]` table exists already — declared, set as an inline
  /// table, set as a sequence, or filled by a dotted key.
  bool get benchDefined =>
      benchDeclared || benchInline || benchSeq || bench.isNotEmpty;
}

/// Reads the `[bench]` table header the scanner is at, or the problem with it.
///
/// Upstream's `Header` has one table, `bench`, and `deny_unknown_fields`
/// makes any other one an error.
///
/// TOML's rule for a table header is `std-table-open key std-table-close`,
/// and the whitespace around the key is the reader's to skip: the `toml`
/// crate's parser reads the whitespace after `[` and before `]` (see
/// `toml_parser`'s `on_table`, which calls `opt_whitespace` on both sides of
/// the key), so `[ bench ]` is a table named `bench` there and here.
String? _readTable(_TomlScanner scanner, _TomlState state) {
  final line = scanner.line;
  scanner
    ..next()
    ..skipSpaces();
  final parts = scanner.keyPath();
  if (parts == null) return scanner.problem;
  scanner.skipSpaces();
  if (scanner.peek != ']') {
    scanner.fail('is not a table', line);

    return scanner.problem;
  }
  scanner.next();
  if (!scanner.endOfEntry()) {
    scanner.fail('is not a table', line);

    return scanner.problem;
  }
  if (parts.rest.isNotEmpty || parts.head != 'bench') {
    scanner.fail(
      'unknown table `${parts.head}` in the `# /// monty` header',
      line,
    );

    return scanner.problem;
  }
  if (state.benchDefined) {
    scanner.fail('`[bench]` is set twice in the `# /// monty` header', line);

    return scanner.problem;
  }
  state
    ..benchDeclared = true
    ..inBench = true;

  return null;
}

/// Reads the `key = value` entry the scanner is at, or the problem with it.
String? _readEntry(_TomlScanner scanner, _TomlState state) {
  final line = scanner.line;
  final parts = scanner.keyPath();
  if (parts == null) return scanner.problem;
  scanner.skipSpaces();
  if (scanner.peek != '=') {
    scanner.fail('is not a `key = value` directive', line);

    return scanner.problem;
  }
  scanner
    ..next()
    ..skipSpaces();
  final value = scanner.value();
  if (scanner.problem != null) return scanner.problem;
  if (!scanner.endOfEntry()) {
    scanner.fail('is not a value', line);

    return scanner.problem;
  }

  return state.inBench
      ? _readBenchEntry(parts, value, state, line, scanner.valueText)
      : _readRootEntry(parts, value, state, line, scanner.valueText);
}

/// Reads one entry of the `[bench]` table into [state].
///
/// Upstream's `Bench` denies unknown fields, so a key that is not one of
/// them is an error, and TOML refuses a key set twice.
String? _readBenchEntry(
  ({String head, List<String> rest}) key,
  Object? value,
  _TomlState state,
  int line,
  String text,
) {
  if (key.rest.isNotEmpty) {
    return 'line $line: unknown field `${key.head}` in the `[bench]` table';
  }
  final name = key.head;
  final type = _benchTypes[name];
  if (type == null) {
    return 'line $line: unknown field `$name` in the `[bench]` table; '
        'known: ${_benchTypes.keys.join(', ')}';
  }
  if (state.bench.containsKey(name)) {
    return 'line $line: `$name` is set twice in the `[bench]` table';
  }
  final problem = _valueProblem(name, value, type, line, text);
  if (problem != null) return problem;
  state.bench[name] = value;

  return null;
}

/// Reads one entry of the header's own keys into [state].
///
/// Upstream's `Header` denies unknown fields, so a key that is not one of
/// them is an error, and TOML refuses a key set twice.
String? _readRootEntry(
  ({String head, List<String> rest}) key,
  Object? value,
  _TomlState state,
  int line,
  String text,
) {
  if (key.head == 'bench') {
    return _readBenchTable(key, value, state, line, text);
  }
  if (key.rest.isNotEmpty) {
    return 'line $line: unknown field `${key.head}` in the `# /// monty` '
        'header';
  }
  final name = key.head;
  final type = _headerTypes[name];
  if (type == null) {
    return 'line $line: unknown directive `$name` in the `# /// monty` header; '
        'known: ${_headerTypes.keys.join(', ')}';
  }
  if (state.root.containsKey(name)) {
    return 'line $line: `$name` is set twice in the `# /// monty` header';
  }
  final problem = _valueProblem(name, value, type, line, text);
  if (problem != null) return problem;
  if (name == 'xfail' && value is List<Object?>) {
    final bad = value.where(
      (target) => target != 'monty' && target != 'cpython',
    );
    if (bad.isNotEmpty) {
      return 'line $line: `$name`: xfail targets must be `monty` and/or '
          '`cpython`';
    }
  }
  state.root[name] = value;

  return null;
}

/// Reads a `bench` entry — the table itself, or one of its fields — into
/// [state].
///
/// Upstream's `Header` has a `bench` field, so `bench = { ... }` sets it and
/// `bench.data = ...` sets one of its fields.
String? _readBenchTable(
  ({String head, List<String> rest}) key,
  Object? value,
  _TomlState state,
  int line,
  String text,
) {
  if (key.rest.isEmpty) {
    if (state.benchDefined) {
      return 'line $line: `bench` is set twice in the `# /// monty` header';
    }

    return _readBenchValue(value, state, line, text);
  }
  if (state.benchInline) {
    return 'line $line: the inline `bench` table cannot be extended';
  }
  if (state.benchSeq) {
    return 'line $line: the `bench` table cannot be extended';
  }

  return _readBenchEntry(
    (head: key.rest.firstOrNull ?? key.head, rest: key.rest.skip(1).toList()),
    value,
    state,
    line,
    text,
  );
}

/// Reads the value a whole `bench` table spells into [state].
///
/// A table is read from a map — an inline table — or from a sequence of the
/// values that fill its fields.
String? _readBenchValue(
  Object? value,
  _TomlState state,
  int line,
  String text,
) {
  final table = value;
  if (table is Map<String, Object?>) {
    state.benchInline = true;
    for (final entry in table.entries) {
      final problem = _readBenchEntry(
        (head: entry.key, rest: const []),
        entry.value,
        state,
        line,
        text,
      );
      if (problem != null) return problem;
    }

    return null;
  }
  if (table is List<Object?>) {
    state.benchSeq = true;

    return _readBenchSequence(table, state, line, text);
  }

  return 'line $line: `bench` is not a table';
}

/// Reads the `bench` table a sequence of values spells into [state].
///
/// Serde reads a struct from a sequence as well as from a table: the values
/// fill the fields in the order they are declared, the fields the sequence
/// does not reach keep their defaults, and the values past the last field
/// are ignored.
String? _readBenchSequence(
  List<Object?> values,
  _TomlState state,
  int line,
  String text,
) {
  final fields = values.iterator;
  for (final field in _benchTypes.entries) {
    if (!fields.moveNext()) break;
    final value = fields.current;
    final problem = _valueProblem(field.key, value, field.value, line, text);
    if (problem != null) return problem;
    state.bench[field.key] = value;
  }

  return null;
}

/// Whether [value] has the type [type], as upstream's `Header` field does.
bool _hasType(Object? value, _ValueType type) => switch (type) {
  _ValueType.boolean => value is bool,
  _ValueType.integer => switch (value) {
    final int v => v >= 0,
    final BigInt v => v.sign >= 0 && v <= _u64Max,
    _ => false,
  },
  _ValueType.string => value is String,
  _ValueType.stringList =>
    value is List<Object?> && value.every((v) => v is String),
};

/// The problem with a header value, or null when it fits the field it fills.
///
/// Upstream's `Header` fields are typed, so serde refuses a value that does
/// not fit the field it fills.
String? _valueProblem(
  String name,
  Object? value,
  _ValueType type,
  int line,
  String text,
) {
  if (_hasType(value, type)) return null;

  return 'line $line: `$name = $text` is not ${type.label}';
}

/// A scanner over the TOML a `# /// monty` header block spells.
///
/// The block's lines are joined with newlines, as upstream's
/// `read_block_body` joins them, and the scanner reads that text the way the
/// `toml` crate does: a key, `=`, a value; a `[table]` header; a comment
/// running to the end of the line; and the values' own shapes.
final class _TomlScanner {
  _TomlScanner(List<({String text, int number})> entries)
    : text = _withoutLeadingBom(
        entries.isEmpty
            ? ''
            : '${entries.map((entry) => entry.text).join('\n')}\n',
      ),
      _firstLine = entries.firstOrNull?.number ?? 1;

  /// The block's lines joined with newlines, one after the other: the TOML
  /// upstream parses.
  ///
  /// Upstream's `read_block_body` writes each line's content and a newline
  /// after it, so the text ends with a newline too. A byte order mark at the
  /// start of it is not part of it: the `toml_parser` lexer skips one there
  /// (`Lexer::new`, which takes the BOM off the front of the input it
  /// lexes), so the TOML upstream reads is the one that follows it.
  final String text;

  /// The text of the value that was read last, for the complaints.
  String valueText = '';

  /// The file line the block's first entry came from.
  final int _firstLine;

  int _pos = 0;
  String? _problem;

  /// Whether the scanner has read all the text.
  bool get atEnd => _pos >= text.length;

  /// The character at the scanner, or the empty string at the end.
  String get peek => atEnd ? '' : text[_pos];

  /// Why the text could not be read, or null when it could.
  String? get problem => _problem;

  /// The file line the scanner is at.
  int get line => _lineAt(_pos);

  /// Moves the scanner on one character.
  void next() => _pos++;

  /// Records [message] as the problem, unless one is already recorded.
  void fail(String message, [int? at]) {
    _problem ??= 'line ${at ?? line}: $message';
  }

  /// Skips the spaces and tabs at the scanner.
  void skipSpaces() {
    _pos = _skipSpaces(text, _pos);
  }

  /// Skips the whitespace and the comments at the scanner.
  void skipBlank() {
    _pos = _skipBlank(text, _pos);
  }

  /// The problem with the characters the text carries, or null when they are
  /// all characters TOML allows.
  ///
  /// TOML's text carries no control character other than a tab and a
  /// newline, and a carriage return only as part of a CRLF: the `toml`
  /// crate's decoder refuses every other control character wherever it
  /// stands — in a string (`decode_basic_string`), in a comment
  /// (`decode_comment`, which reads every byte of a comment against
  /// `non-eol`: a tab, the printable ASCII and the non-ASCII bytes) and
  /// outside one — and a carriage return that is not followed by a newline
  /// ("carriage return must be followed by newline").
  String? characterProblem() {
    for (var index = 0; index < text.length; index++) {
      final char = text[index];
      if (char == '\r') {
        if (!text.startsWith('\n', index + 1)) {
          fail('has a carriage return that is not a newline', _lineAt(index));
        }
        continue;
      }
      if (_isForbiddenControl(char)) {
        fail('has a control character', _lineAt(index));
      }
    }

    return problem;
  }

  /// Whether the rest of the entry is a comment and the end of the line, and
  /// consumes it.
  ///
  /// The end of the line is a LF or a CRLF: the `toml` crate reads both as
  /// one line ending (see `toml_parser`'s `decode_newline`, which takes a
  /// carriage return only when a newline follows it), so the entry ends here
  /// on either.
  bool endOfEntry() {
    var index = _skipSpaces(text, _pos);
    if (index >= text.length) {
      _pos = index;

      return true;
    }
    if (text[index] == '#') {
      while (index < text.length && text[index] != '\n') {
        index++;
      }
      _pos = index;

      return true;
    }
    if (text.startsWith('\r\n', index)) {
      _pos = index + 2;

      return true;
    }
    if (text[index] == '\n') {
      _pos = index + 1;

      return true;
    }
    _pos = index;

    return false;
  }

  /// The dotted key at the scanner — its first part and the parts after it —
  /// or null when there is none.
  ({String head, List<String> rest})? keyPath() {
    final parts = <String>[];
    while (true) {
      final part = _simpleKey();
      if (part == null) return null;
      parts.add(part);
      _pos = _skipSpaces(text, _pos);
      if (peek != '.') break;
      next();
      _pos = _skipSpaces(text, _pos);
    }
    final head = parts.firstOrNull;
    if (head == null) return null;

    return (head: head, rest: parts.sublist(1));
  }

  /// The value at the scanner, or null when there is none.
  Object? value() {
    final start = _pos;
    final read = _readValue(text, _pos);
    _pos = read.next;
    valueText = text.substring(start, _pos);
    if (read.problem case final String reason) {
      fail(reason, _lineAt(start));
    }

    return read.value;
  }

  /// The file line the text at [pos] is on.
  ///
  /// The block's lines are joined with newlines, one per line, so the lines
  /// the text has passed are the newlines it holds.
  int _lineAt(int pos) {
    final passed = '\n'.allMatches(text.substring(0, pos)).length;

    return _firstLine + passed;
  }

  String? _simpleKey() {
    if (atEnd) {
      fail('is not a key');

      return null;
    }
    final char = text[_pos];
    if (char == '"' || char == "'") {
      if (_isMultilineDelimiter(text, _pos)) {
        fail('is not a key');

        return null;
      }
      final read = _readString(text, _pos);
      _pos = read.next;
      if (read.problem case final String reason) {
        fail(reason);

        return null;
      }

      return read.value ?? '';
    }
    final start = _pos;
    while (!atEnd && _isBareKeyChar(text[_pos])) {
      _pos++;
    }
    if (_pos == start) {
      fail('is not a key');

      return null;
    }

    return text.substring(start, _pos);
  }
}

/// [text] without the byte order mark it starts with, if it has one.
///
/// The `toml_parser` lexer skips one byte order mark at the start of the
/// text it lexes (`Lexer::new`, which takes the BOM off the front of the
/// input), so the TOML upstream reads is the one that follows the mark.
String _withoutLeadingBom(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;

/// The position after the spaces and tabs at [pos] in [text].
int _skipSpaces(String text, int pos) {
  var index = pos;
  while (index < text.length && (text[index] == ' ' || text[index] == '\t')) {
    index++;
  }

  return index;
}

/// [text] without the spaces and tabs at its ends.
///
/// TOML's whitespace is a space or a tab and nothing else, so a value may
/// not be padded with any other whitespace: `gc-interval = <no-break
/// space>200` is a value the `toml` crate refuses ("string values must be
/// quoted"), where Dart's `trim()` would have taken the no-break space for
/// whitespace and read `200`.
String _trimTomlSpace(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && (text[start] == ' ' || text[start] == '\t')) {
    start++;
  }
  while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t')) {
    end--;
  }

  return text.substring(start, end);
}

/// The position after the whitespace and the comments at [pos] in [text].
///
/// The whitespace is a space, a tab or a newline — TOML's own whitespace is
/// a space or a tab, and a newline is a line ending, so a carriage return
/// left in a line is not whitespace here either: the `toml` crate refuses
/// one ("carriage return must be followed by newline"), and so does the
/// character check the text gets before it is read (see
/// `_TomlScanner.characterProblem`).
///
/// A newline is a LF or a CRLF: the `toml` crate reads a carriage return as
/// part of the newline that follows it, so a CRLF is one newline here too.
int _skipBlank(String text, int pos) {
  var index = pos;
  while (index < text.length) {
    final char = text[index];
    if (char == ' ' || char == '\t' || char == '\n') {
      index++;
      continue;
    }
    if (text.startsWith('\r\n', index)) {
      index += 2;
      continue;
    }
    if (char == '#') {
      while (index < text.length && text[index] != '\n') {
        index++;
      }
      continue;
    }
    break;
  }

  return index;
}

/// The value at [pos] in [text], and the position after it.
///
/// A null problem means the value was read; otherwise it says why the text
/// does not spell a value there.
({Object? value, int next, String? problem}) _readValue(String text, int pos) {
  if (pos >= text.length) {
    return (value: null, next: pos, problem: 'is not a value');
  }
  final char = text[pos];
  if (char == '"' || char == "'") return _readString(text, pos);
  if (char == '[') return _readArray(text, pos);
  if (char == '{') return _readInlineTable(text, pos);

  return _readScalar(text, pos);
}

/// The string at [pos] in [text], and the position after it.
///
/// TOML's rule for a string's own characters: it carries no control
/// character other than a tab (`basic-unescaped = wschar / %x21 / %x23-5B /
/// %x5D-7E / non-ascii`, and the same for a literal string), so the `toml`
/// crate's decoder refuses a character in U+0000 to U+0008, U+000A to
/// U+001F or U+007F (see `toml_parser`'s `decode_basic_string` and
/// `decode_literal_string`, which check every byte against those ranges).
({String? value, int next, String? problem}) _readString(String text, int pos) {
  final quote = text[pos];
  if (text.startsWith(quote * 3, pos)) {
    return _readMultilineString(text, pos, quote);
  }
  var index = pos + 1;
  final buffer = StringBuffer();
  while (index < text.length) {
    final char = text[index];
    if (char == '\n') break;
    if (quote == '"' && char == r'\') {
      final escape = _tomlEscape(text, index + 1);
      if (escape == null) {
        return (value: null, next: index, problem: 'is not an escape');
      }
      buffer.write(escape.value);
      index = escape.next;
      continue;
    }
    if (char == quote) {
      return (value: buffer.toString(), next: index + 1, problem: null);
    }
    if (_isForbiddenControl(char)) {
      return (value: null, next: index, problem: 'has a control character');
    }
    buffer.write(char);
    index++;
  }

  return (value: null, next: index, problem: 'is not a closed string');
}

/// Whether [char] may not be written into a TOML string as it stands.
///
/// TOML's rule: a string carries no control character other than a tab, and
/// a multiline string carries a newline — so U+0000 to U+0008, U+000A to
/// U+001F (the newline excepted, which ends a one-line string) and U+007F
/// are all refused by the `toml` crate's decoder.
bool _isForbiddenControl(String char) {
  final code = char.codeUnitAt(0);
  if (code == 0x09) return false;
  if (code == 0x0a) return false;

  return code < 0x20 || code == 0x7f;
}

/// Whether the string at [pos] in [text] opens with a multiline delimiter.
///
/// TOML does not allow a multiline string as a key.
bool _isMultilineDelimiter(String text, int pos) =>
    text.startsWith('"""', pos) || text.startsWith("'''", pos);

/// The string that starts at [pos] in [text] with the delimiter [quote], and
/// the position after it.
///
/// TOML's rules for a multiline string: a newline straight after the opening
/// delimiter is trimmed, in a basic one a backslash at the end of a line
/// trims that line's end and the whitespace that follows it, and a run of
/// quotes ends the string — the last three of the run close it, the ones
/// before them are the string's own, and a run of more than five is an error
/// because a multiline string may not carry three quotes of its own.
///
/// A multiline string carries a newline (a LF or a CRLF) and no other
/// control character: the `toml` crate's decoder reads a CR as part of a
/// CRLF and refuses one that is not (`decode_ml_basic_string` and
/// `decode_ml_literal_string`, which report "carriage return must be
/// followed by newline"), and refuse every other control character.
({String? value, int next, String? problem}) _readMultilineString(
  String text,
  int pos,
  String quote,
) {
  var index = _skipOpeningNewline(text, pos + 3);
  final buffer = StringBuffer();
  while (index < text.length) {
    final char = text[index];
    if (char == quote) {
      final run = _quoteRun(text, index, quote);
      if (run >= 3) return _closeMultiline(index, run, quote, buffer);
      buffer.write(quote * run);
      index += run;
      continue;
    }
    if (quote == '"' && char == r'\') {
      final escape = _readEscape(text, index);
      if (escape.problem != null) {
        return (value: null, next: escape.next, problem: escape.problem);
      }
      buffer.write(escape.value);
      index = escape.next;
      continue;
    }
    final content = _readMultilineChar(text, index, buffer);
    if (content.problem != null) {
      return (value: null, next: content.next, problem: content.problem);
    }
    index = content.next;
  }

  return (value: null, next: text.length, problem: 'is not a closed string');
}

/// The position after the newline that follows a multiline string's opening
/// delimiter, which TOML trims.
///
/// The newline is a LF or a CRLF: the `toml` crate's decoder trims both
/// (`strip_start_newline`).
int _skipOpeningNewline(String text, int pos) {
  if (text.startsWith('\r\n', pos)) return pos + 2;
  if (text.startsWith('\n', pos)) return pos + 1;

  return pos;
}

/// The character at [pos] in a multiline string, written into [buffer].
///
/// A multiline string carries a newline and no other control character.
({int next, String? problem}) _readMultilineChar(
  String text,
  int pos,
  StringBuffer buffer,
) {
  final char = text[pos];
  if (char == '\r') {
    if (!text.startsWith('\r\n', pos)) {
      return (
        next: pos,
        problem: 'has a carriage return that is not a newline',
      );
    }
    buffer.write('\r\n');

    return (next: pos + 2, problem: null);
  }
  if (_isForbiddenControl(char)) {
    return (next: pos, problem: 'has a control character');
  }
  buffer.write(char);

  return (next: pos + 1, problem: null);
}

/// The end of the multiline string a run of [run] quotes closes.
///
/// The last three quotes of the run close the string and the ones before
/// them are the string's own — a multiline string may carry two quotes, so
/// a longer run is an error.
({String? value, int next, String? problem}) _closeMultiline(
  int pos,
  int run,
  String quote,
  StringBuffer buffer,
) {
  if (run > 5) {
    return (
      value: null,
      next: pos,
      problem: 'has too many `$quote` in a multiline string',
    );
  }
  for (var i = 0; i < run - 3; i++) {
    buffer.write(quote);
  }

  return (value: buffer.toString(), next: pos + run, problem: null);
}

/// The escape the backslash at [pos] in [text] starts, and where it ends.
///
/// A backslash at the end of a line is a continuation: it trims the line's
/// end and the whitespace that follows it, and spells nothing.
({String? value, int next, String? problem}) _readEscape(String text, int pos) {
  final continuation = _lineEnding(text, pos);
  if (continuation != null) {
    return (
      value: '',
      next: _skipLineWhitespace(text, continuation),
      problem: null,
    );
  }
  final escape = _tomlEscape(text, pos + 1);
  if (escape == null) {
    return (value: null, next: pos, problem: 'is not an escape');
  }

  return (value: escape.value, next: escape.next, problem: null);
}

/// The number of [quote]s in the run that starts at [pos] in [text].
int _quoteRun(String text, int pos, String quote) {
  var index = pos;
  while (index < text.length && text[index] == quote) {
    index++;
  }

  return index - pos;
}

/// The position after the newline a line-ending backslash at [pos] ends
/// with, or null when the backslash at [pos] does not end a line.
///
/// TOML's rule: a backslash that is the last non-whitespace character on a
/// line ends the line there.
///
/// The line the backslash ends may end with a CRLF: the `toml` crate's
/// decoder reads the carriage return as part of the newline (see
/// `toml_parser`'s `mlb_escaped_nl`, which refuses a carriage return that
/// is not followed by a newline), so it is one here too.
int? _lineEnding(String text, int pos) {
  var index = pos + 1;
  while (index < text.length && (text[index] == ' ' || text[index] == '\t')) {
    index++;
  }
  if (index >= text.length) return null;
  if (text.startsWith('\r\n', index)) return index + 2;
  if (text[index] == '\n') return index + 1;

  return null;
}

/// The position after the whitespace and the newlines at [pos] in [text].
///
/// A newline is a LF or a CRLF: a carriage return that is not followed by a
/// newline is not one, and it is an error in the text.
int _skipLineWhitespace(String text, int pos) {
  var index = pos;
  while (index < text.length) {
    final char = text[index];
    if (char == ' ' || char == '\t' || char == '\n') {
      index++;
      continue;
    }
    if (text.startsWith('\r\n', index)) {
      index += 2;
      continue;
    }
    break;
  }

  return index;
}

/// The list at [pos] in [text], and the position after it.
({Object? value, int next, String? problem}) _readArray(String text, int pos) {
  var index = pos + 1;
  final items = <Object?>[];
  while (true) {
    index = _skipBlank(text, index);
    if (index >= text.length) {
      return (value: null, next: index, problem: 'is not a closed list');
    }
    if (text[index] == ']') {
      return (value: items, next: index + 1, problem: null);
    }
    final item = _readValue(text, index);
    if (item.problem case final String reason) {
      return (value: null, next: item.next, problem: reason);
    }
    items.add(item.value);
    index = _skipBlank(text, item.next);
    if (index >= text.length) {
      return (value: null, next: index, problem: 'is not a closed list');
    }
    if (text[index] == ',') {
      index++;
      continue;
    }
    if (text[index] == ']') {
      return (value: items, next: index + 1, problem: null);
    }

    return (value: null, next: index, problem: 'is not a list');
  }
}

/// The inline table at [pos] in [text], and the position after it.
({Object? value, int next, String? problem}) _readInlineTable(
  String text,
  int pos,
) {
  var index = pos + 1;
  final table = <String, Object?>{};
  while (true) {
    index = _skipBlank(text, index);
    if (index >= text.length) {
      return (value: null, next: index, problem: 'is not a closed table');
    }
    if (text[index] == '}') {
      return (value: table, next: index + 1, problem: null);
    }
    final entry = _readTableEntry(text, index);
    if (entry.problem case final String reason) {
      return (value: null, next: entry.next, problem: reason);
    }
    if (table.containsKey(entry.key)) {
      return (
        value: null,
        next: entry.next,
        problem: '`${entry.key}` is set twice',
      );
    }
    table[entry.key] = entry.value;
    index = _skipBlank(text, entry.next);
    if (index >= text.length) {
      return (value: null, next: index, problem: 'is not a closed table');
    }
    if (text[index] == ',') {
      index++;
      continue;
    }
    if (text[index] == '}') {
      return (value: table, next: index + 1, problem: null);
    }

    return (value: null, next: index, problem: 'is not a table');
  }
}

/// The `key = value` pair at [pos] in [text], and the position after it.
///
/// An inline table's pairs are separated by whitespace that may span lines,
/// as the `toml` crate reads them: its inline-table reader takes a newline
/// in every state (see `toml_parser`'s `on_inline_table_open`, whose
/// `TokenKind::Newline` arm leaves the state it is in alone), so
/// `bench = { mount =` and the `true }` on the next line are one pair there
/// and here.
///
/// The TOML 1.1 grammar would have the key, the `=` and the value of a pair
/// on one line, but upstream reads the block with the crate — upstream
/// v1.2.0's `Cargo.lock` pins `toml` 1.1.6 and `toml_parser` 1.1.3, and
/// `monty_fixture::Header::parse` reads the block with `toml::from_str` —
/// so where the grammar and the crate disagree, the crate is what upstream
/// reads, and what is read here.
({String key, Object? value, int next, String? problem}) _readTableEntry(
  String text,
  int pos,
) {
  final key = _readKeyPath(text, pos);
  if (key == null) {
    return (key: '', value: null, next: pos, problem: 'is not a key');
  }
  var index = _skipBlank(text, key.next);
  if (index >= text.length || text[index] != '=') {
    return (
      key: '',
      value: null,
      next: index,
      problem: 'is not a `key = value` directive',
    );
  }
  index = _skipBlank(text, index + 1);
  final value = _readValue(text, index);
  if (value.problem case final String reason) {
    return (key: '', value: null, next: value.next, problem: reason);
  }

  return (
    key: [key.head, ...key.rest].join('.'),
    value: value.value,
    next: value.next,
    problem: null,
  );
}

/// The bare value at [pos] in [text] — a boolean, an integer, a float or a
/// date-time — and the position after it.
///
/// The value is trimmed of the spaces and tabs that pad it, and of nothing
/// else: TOML's whitespace is a space or a tab, so a value padded with
/// anything else (`gc-interval = <no-break space>200`) is not a value the
/// `toml` crate reads, where Dart's `trim()` would have taken the no-break
/// space for whitespace and read `200`.
///
/// The value ends at the line's end too, so a carriage return that ends the
/// line is not part of it: the `toml` crate reads a carriage return as part
/// of the newline that follows it (`toml_parser`'s `decode_newline`), and
/// the value `gc-interval = 200` of a CRLF line is the integer `200`.
({Object? value, int next, String? problem}) _readScalar(String text, int pos) {
  var index = pos;
  while (index < text.length && !',]}\n\r#'.contains(text[index])) {
    index++;
  }
  final word = _trimTomlSpace(text.substring(pos, index));
  final value = _tomlScalar(word);
  if (value != null) return (value: value, next: index, problem: null);

  return (value: null, next: index, problem: '`$word` is not a value');
}

/// The value [word] spells, or null when it does not spell one.
///
/// The value is one of the four scalar kinds the `toml` crate reads, as
/// upstream's `toml::from_str` reads them (`toml_parser`'s
/// `decode_unquoted_scalar`, which decides the kind by the value's shape):
/// a boolean, an integer, a float or a date-time.
///
/// Every one of them is a value, so a fixture that carries one where
/// upstream's `Header` has no field for it — an element past the four
/// fields of its `Bench`, say — is not malformed here either: upstream
/// never reads that value, so its kind is no one's business but the
/// parser's.
Object? _tomlScalar(String word) {
  if (word == 'true') return true;
  if (word == 'false') return false;

  return _tomlInteger(word) ?? _tomlFloat(word) ?? _tomlDateTime(word);
}

/// The float [word] spells, or null when it does not spell one.
///
/// TOML's floats, as the `toml` crate reads them (`toml_parser`'s
/// `ensure_float`, which the crate's `decode_unquoted_scalar` calls): a
/// sign, then a decimal number with a fraction and/or an exponent — or one
/// of the two special floats, `inf` and `nan`.
///
/// The special floats are spelled in lower case only (`Inf` is an error
/// there), the decimal number may not carry a leading zero (`01.5` is an
/// error), and an underscore may only stand between two digits (`1__0` is
/// an error).
_TomlFloat? _tomlFloat(String word) {
  var body = word;
  if (body.startsWith('+') || body.startsWith('-')) body = body.substring(1);
  if (body == 'inf' || body == 'nan') return _TomlFloat(word);
  if (_tomlDecimalFloat(body) == null) return null;

  return _TomlFloat(word);
}

/// The decimal float [body] spells, or null when it does not spell one.
///
/// A decimal float is a mantissa with a fraction and/or an exponent: the
/// mantissa may not carry a leading zero, and an underscore may only stand
/// between two digits.
int? _tomlDecimalFloat(String body) {
  final mantissa = _tomlDigitRun(body, 0, leadingZeroAllowed: false);
  if (mantissa == null) return null;

  return _tomlFloatRest(body, mantissa.next);
}

/// The position after the fraction and the exponent [body] spells from
/// [index], or null when they do not spell a float's.
///
/// A float has a fraction, an exponent or both; a mantissa alone is an
/// integer, and the integer reader reads that.
int? _tomlFloatRest(String body, int index) {
  var next = index;
  var isFloat = false;
  if (_tomlCharAt(body, next) == '.') {
    final fraction = _tomlDigitRun(body, next + 1);
    if (fraction == null) return null;
    next = fraction.next;
    isFloat = true;
  }
  if (_tomlCharAt(body, next) == 'e' || _tomlCharAt(body, next) == 'E') {
    final exponent = _tomlExponent(body, next);
    if (exponent == null) return null;
    next = exponent;
    isFloat = true;
  }
  if (!isFloat || next != body.length) return null;

  return next;
}

/// The position after the exponent at [index] in [body], or null when the
/// exponent there is not one.
///
/// The exponent is an `e`, an optional sign and the digits after it.
int? _tomlExponent(String body, int index) {
  var next = index + 1;
  final sign = _tomlCharAt(body, next);
  if (sign == '+' || sign == '-') next++;
  final exponent = _tomlDigitRun(body, next);
  if (exponent == null) return null;

  return exponent.next;
}

/// The run of digits at [pos] in [text], and the position after it, or null
/// when there is none there.
///
/// The digits may be separated by underscores, which may only stand between
/// two of them: `1__0` and `1_` are not runs of digits. A run that may not
/// carry a leading zero is the mantissa of a float, where `01.5` is an
/// error.
({int digits, int next})? _tomlDigitRun(
  String text,
  int pos, {
  bool leadingZeroAllowed = true,
}) {
  var index = pos;
  var digits = 0;
  var afterDigit = false;
  while (index < text.length) {
    final char = text[index];
    if (_isDigit(char)) {
      digits++;
      afterDigit = true;
      index++;
      continue;
    }
    if (char == '_') {
      if (!afterDigit || !_isDigit(_tomlCharAt(text, index + 1))) return null;
      index++;
      continue;
    }
    break;
  }
  if (digits == 0) return null;
  if (!leadingZeroAllowed && digits > 1 && text.startsWith('0', pos)) {
    return null;
  }

  return (digits: digits, next: index);
}

/// The date-time [word] spells, or null when it does not spell one.
///
/// TOML's four date-time shapes, as the `toml` crate reads them (its
/// `toml_datetime` crate parses them, in `Datetime::from_str`): a local
/// date, a local date-time, a local time, and an offset date-time — a
/// local date-time with a `Z` or a `±HH:MM` after it.
///
/// The date is a four-digit year, a two-digit month and a two-digit day,
/// the day within its month; the time is a two-digit hour, a two-digit
/// minute and an optional two-digit second with an optional fraction; and
/// the offset is a two-digit hour and a two-digit minute.
_TomlDateTime? _tomlDateTime(String word) {
  final date = _tomlDate(word);
  if (date == null) return _tomlLocalTime(word);
  if (date.next == word.length) return _TomlDateTime(word);
  final separator = word[date.next];
  if (separator != 'T' && separator != 't' && separator != ' ') return null;
  final time = _tomlTime(word, date.next + 1);
  if (time == null) return null;
  if (time.next == word.length) return _TomlDateTime(word);
  final offset = _tomlOffset(word, time.next);
  if (offset == null || offset != word.length) return null;

  return _TomlDateTime(word);
}

/// The local time [word] spells, or null when it does not spell one.
_TomlDateTime? _tomlLocalTime(String word) {
  final time = _tomlTime(word, 0);
  if (time == null || time.next != word.length) return null;

  return _TomlDateTime(word);
}

/// The local date at the start of [word], and the position after it, or null
/// when [word] does not start with one.
({int next})? _tomlDate(String word) {
  final year = _tomlDigitsAt(word, 0, 4);
  if (year == null || _tomlCharAt(word, 4) != '-') return null;
  final month = _tomlDigitsAt(word, 5, 2);
  if (month == null || _tomlCharAt(word, 7) != '-') return null;
  final day = _tomlDigitsAt(word, 8, 2);
  if (day == null || !_tomlDateRange(year, month, day)) return null;

  return (next: 10);
}

/// Whether the year, the month and the day are a date the crate reads.
///
/// The month is one of the twelve, and the day is one of the days its
/// month has.
bool _tomlDateRange(int year, int month, int day) {
  if (month < 1 || month > 12) return false;

  return day >= 1 && day <= _tomlDaysInMonth(year, month);
}

/// The number of days the month [month] of the year [year] has.
///
/// February has 29 days in a leap year and 28 in any other, and April,
/// June, September and November have 30.
int _tomlDaysInMonth(int year, int month) {
  if (month == 2) {
    final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

    return leap ? 29 : 28;
  }
  if (month == 4 || month == 6 || month == 9 || month == 11) return 30;

  return 31;
}

/// The time at [pos] in [word], and the position after it, or null when
/// there is none there.
({int next})? _tomlTime(String word, int pos) {
  final hour = _tomlDigitsAt(word, pos, 2);
  if (hour == null || _tomlCharAt(word, pos + 2) != ':') return null;
  final minute = _tomlDigitsAt(word, pos + 3, 2);
  if (minute == null || hour > 23 || minute > 59) return null;
  final seconds = _tomlSeconds(word, pos + 5);
  if (seconds == null) return null;

  return (next: seconds);
}

/// The position after the seconds and the fraction [word] spells from
/// [index], or null when they are not a time's.
///
/// The seconds are a colon, two digits and an optional fraction; a time
/// without them ends at [index].
int? _tomlSeconds(String word, int index) {
  if (_tomlCharAt(word, index) != ':') return index;
  final second = _tomlDigitsAt(word, index + 1, 2);
  if (second == null || second > 60) return null;
  var next = index + 3;
  if (_tomlCharAt(word, next) == '.') {
    final fraction = _tomlFraction(word, next + 1);
    if (fraction == null) return null;
    next = fraction;
  }

  return next;
}

/// The position after the digits at [pos] in [word], or null when there are
/// none there.
int? _tomlFraction(String word, int pos) {
  var index = pos;
  while (index < word.length && _isDigit(word[index])) {
    index++;
  }
  if (index == pos) return null;

  return index;
}

/// The position after the offset at [pos] in [word], or null when there is
/// none there.
///
/// The offset is a `Z`, or a sign and a two-digit hour and a two-digit
/// minute.
int? _tomlOffset(String word, int pos) {
  final char = _tomlCharAt(word, pos);
  if (char == 'Z' || char == 'z') return pos + 1;
  if (char != '+' && char != '-') return null;
  final hours = _tomlDigitsAt(word, pos + 1, 2);
  if (hours == null || _tomlCharAt(word, pos + 3) != ':') return null;
  final minutes = _tomlDigitsAt(word, pos + 4, 2);
  if (minutes == null || !_tomlOffsetRange(hours, minutes)) return null;

  return pos + 6;
}

/// Whether the hours and the minutes are an offset the crate reads.
bool _tomlOffsetRange(int hours, int minutes) => hours <= 23 && minutes <= 59;

/// The number the [count] digits at [pos] in [word] spell, or null when
/// there are not that many digits there.
int? _tomlDigitsAt(String word, int pos, int count) {
  if (pos + count > word.length) return null;
  var value = 0;
  for (var index = pos; index < pos + count; index++) {
    if (!_isDigit(word[index])) return null;
    value = value * 10 + (word[index].codeUnitAt(0) - 0x30);
  }

  return value;
}

/// The character at [pos] in [text], or the empty string past its end.
String _tomlCharAt(String text, int pos) => pos < text.length ? text[pos] : '';

/// Whether [char] is a decimal digit.
bool _isDigit(String char) {
  if (char.isEmpty) return false;
  final code = char.codeUnitAt(0);

  return code >= 0x30 && code <= 0x39;
}

/// The dotted key at [pos] in [text], and the position after it.
///
/// The parts of a key are separated by whitespace, which in an inline table
/// may span lines, as the `toml` crate reads them.
({String head, List<String> rest, int next})? _readKeyPath(
  String text,
  int pos,
) {
  var index = pos;
  final parts = <String>[];
  while (true) {
    final part = _readSimpleKey(text, index);
    if (part == null) return null;
    parts.add(part.value);
    index = _skipBlank(text, part.next);
    if (index >= text.length || text[index] != '.') break;
    index = _skipBlank(text, index + 1);
  }
  final head = parts.firstOrNull;
  if (head == null) return null;

  return (head: head, rest: parts.sublist(1), next: index);
}

/// The key at [pos] in [text], and the position after it.
({String value, int next})? _readSimpleKey(String text, int pos) {
  if (pos >= text.length) return null;
  final char = text[pos];
  if (char == '"' || char == "'") {
    if (_isMultilineDelimiter(text, pos)) return null;
    final read = _readString(text, pos);
    if (read.problem != null) return null;
    final value = read.value;

    return (value: value is String ? value : '', next: read.next);
  }
  final index = _skipBareKey(text, pos);
  if (index == pos) return null;

  return (value: text.substring(pos, index), next: index);
}

/// The escape at [pos] in [text], and the position after it.
///
/// TOML's escapes: the single-character ones, and the `x`, `u` and `U`
/// forms, which carry the code point in hex.
///
/// The `x` form carries exactly two hexadecimal digits, and the `u` and `U`
/// forms exactly four or eight. The code point they spell must be a
/// Unicode scalar value: the `toml` crate's decoder reads the digits as hex
/// (`hexescape`, which takes the digits while they are hexadecimal) and
/// turns the value into a `char` (`char::from_u32`, which refuses a
/// surrogate and a code point past the last one), so `\uD800` and `\u+041`
/// are both errors there and here.
///
/// TOML 1.1 added two escapes to the ones TOML 1.0 had: `e` (the escape
/// character, U+001B) and `x` (a hexadecimal byte, U+00HH). The `toml`
/// crate reads both (`toml_parser`'s `escape_seq_char`, which answers
/// `'e' => '\u{1b}'` and `'x' => hexescape(stream, 2, ...)`), so they are
/// read here too: `\x6donty` is `monty`, as it is there.
({String value, int next})? _tomlEscape(String text, int pos) {
  if (pos >= text.length) return null;
  final char = text[pos];
  final index = pos + 1;
  const simple = {
    'b': '\b',
    't': '\t',
    'n': '\n',
    'f': '\f',
    'r': '\r',
    'e': '\u001b',
    '"': '"',
    r'\': r'\',
  };
  final escaped = simple[char];
  if (escaped != null) return (value: escaped, next: index);
  final width = switch (char) {
    'x' => 2,
    'u' => 4,
    'U' => 8,
    _ => 0,
  };
  if (width == 0) return null;
  if (index + width > text.length) return null;
  final digits = text.substring(index, index + width);
  if (!_isHexDigits(digits)) return null;
  final code = int.parse(digits, radix: 16);
  if (!_isScalarValue(code)) return null;

  return (value: _scalarString(code), next: index + width);
}

/// Whether [digits] are all hexadecimal digits.
bool _isHexDigits(String digits) {
  for (final digit in digits.split('')) {
    if (!_isHexDigit(digit)) return false;
  }

  return true;
}

/// Whether [char] is a hexadecimal digit.
bool _isHexDigit(String char) {
  final code = char.codeUnitAt(0);

  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x46) ||
      (code >= 0x61 && code <= 0x66);
}

/// Whether the code point [code] is a Unicode scalar value.
///
/// A surrogate is not a character, and a code point past the last one is not
/// either, so TOML spells neither.
bool _isScalarValue(int code) =>
    code <= 0x10ffff && (code < 0xd800 || code > 0xdfff);

/// The character the code point [code] spells.
///
/// A code point past the basic plane is spelled by a surrogate pair, as
/// Dart's strings are UTF-16.
String _scalarString(int code) {
  if (code <= 0xffff) return String.fromCharCode(code);
  final offset = code - 0x10000;

  return String.fromCharCodes([
    (offset >> 10) | 0xd800,
    (offset & 0x3ff) | 0xdc00,
  ]);
}

/// The position after the bare key at [pos] in [text].
int _skipBareKey(String text, int pos) {
  var index = pos;
  while (index < text.length && _isBareKeyChar(text[index])) {
    index++;
  }

  return index;
}

/// Whether [char] may be in a bare TOML key.
bool _isBareKeyChar(String char) =>
    (char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39) ||
    (char.codeUnitAt(0) >= 0x41 && char.codeUnitAt(0) <= 0x5a) ||
    (char.codeUnitAt(0) >= 0x61 && char.codeUnitAt(0) <= 0x7a) ||
    char == '_' ||
    char == '-';

final _decimalInteger = RegExp(r'^(0|[1-9](_?[0-9])*)$');
final _hexInteger = RegExp(r'^0x[0-9a-fA-F](_?[0-9a-fA-F])*$');
final _octalInteger = RegExp(r'^0o[0-7](_?[0-7])*$');
final _binaryInteger = RegExp(r'^0b[01](_?[01])*$');

/// The integer [word] spells, or null when it does not spell one.
///
/// TOML's rules: a sign, then a decimal, hexadecimal, octal or binary
/// number, with underscores between the digits. A sign is only allowed on a
/// decimal number — a radix number may not carry one.
Object? _tomlInteger(String word) {
  var body = word;
  var sign = 1;
  var signed = false;
  if (body.startsWith('-')) {
    sign = -1;
    signed = true;
    body = body.substring(1);
  } else if (body.startsWith('+')) {
    signed = true;
    body = body.substring(1);
  }
  final value = _tomlUnsignedInteger(body, sign, signed);
  if (value == null) return null;
  if (value is BigInt && (value < _i128Min || value > _u128Max)) return null;

  return value;
}

/// The integer the unsigned [body] spells, with the sign [sign] before it,
/// or null when it does not spell one.
///
/// A radix number may not carry a sign, so [signed] says whether one was
/// there.
Object? _tomlUnsignedInteger(String body, int sign, bool signed) {
  if (_hexInteger.hasMatch(body)) {
    if (signed) return null;

    return _parseInteger(body.substring(2), 16);
  }
  if (_octalInteger.hasMatch(body)) {
    if (signed) return null;

    return _parseInteger(body.substring(2), 8);
  }
  if (_binaryInteger.hasMatch(body)) {
    if (signed) return null;

    return _parseInteger(body.substring(2), 2);
  }
  if (!_decimalInteger.hasMatch(body)) return null;

  return _signedInteger(_parseInteger(body, 10), sign);
}

/// The integer [body] spells in [radix], with its underscores removed.
///
/// The `toml` crate reads an integer as text and converts it when the field
/// it fills asks for one (`to_i64`, then `to_u64`, then `to_i128`, then
/// `to_u128`), so an integer too large for a 64-bit field is still a value:
/// it is the field that refuses it, not the parser. Dart's `int` is 64-bit
/// signed, so a value beyond it is kept as a [BigInt].
Object _parseInteger(String body, int radix) {
  final digits = body.replaceAll('_', '');
  final value = BigInt.parse(digits, radix: radix);

  return value.isValidInt ? value.toInt() : value;
}

/// The largest integer upstream's `gc-interval` takes: it is a `usize`.
final BigInt _u64Max = BigInt.parse('18446744073709551615');

/// The smallest integer the `toml` crate reads.
final BigInt _i128Min = BigInt.parse(
  '-170141183460469231731687303715884105728',
);

/// The largest integer the `toml` crate reads.
final BigInt _u128Max = BigInt.parse(
  '340282366920938463463374607431768211455',
);

/// The integer [value] with the sign [sign] before it.
Object _signedInteger(Object value, int sign) {
  if (sign > 0) return value;
  if (value is int) return -value;

  return -(value as BigInt);
}

/// Whether [line] looks like a PEP 723 block delimiter, as upstream's
/// `is_block_marker` sees one.
///
/// Upstream reads the line with Rust's `str::trim_start`, whose whitespace
/// is the Unicode `White_Space` property (see [_isRustWhitespace]): a byte
/// order mark is not whitespace there, so it is not trimmed away.
bool _isBlockMarker(String line) {
  if (!line.startsWith('#')) return false;

  return _rustTrimStart(line.replaceFirst(RegExp('^#+'), '')).startsWith('///');
}

/// The lines of [lines] that are not inside a `# /// monty` header block.
///
/// The block's lines are TOML, which upstream reads with
/// `monty_fixture::Header::parse`; they are never flat directives.
List<String> _flatLines(List<String> lines, Set<int> blockLines) => [
  for (var i = 0; i < lines.length; i++)
    if (!blockLines.contains(i)) lines[i],
];

/// The interpreters a fixture is expected to fail on: the `xfail` targets of
/// the `# /// monty` header when it carries them, the flat `# xfail=` targets
/// otherwise.
List<String> _xfailTargets(String source) {
  final lines = _lines(source);
  final header = _readHeader(lines);
  final block = header.values['xfail'];
  if (block is List<Object?>) return block.whereType<String>().toList();
  final flat = _commentLines(
    _flatLines(lines, header.blockLines),
  ).where((c) => c.startsWith('xfail=')).firstOrNull;
  if (flat == null) return const [];
  final value =
      flat.substring('xfail='.length).split(RegExp(r'\s')).firstOrNull ?? '';

  return value.split(',').map((target) => target.trim()).toList();
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
/// `xfail` marks the fixture as one that must FAIL: `# xfail=monty` (upstream
/// 1.1.0) and `xfail = ['monty']` (upstream 1.2.0's `# /// monty` header)
/// both yield [ExpectXfail], so the fixture RUNS, and must fail.
/// `xfail=cpython` changes nothing here — monty is expected to pass.
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

  if ((skipCallExternal && fixtureIsCallExternal(source)) ||
      (skipRunAsync && fixtureIsRunAsync(source)) ||
      (skipMountFs && fixtureMountsFs(source))) {
    return null;
  }

  final expectation = traceback ?? _parseLastLine(lines);
  if (_xfailTargets(source).contains('monty')) {
    return ExpectXfail(expectation);
  }

  return expectation;
}

FixtureExpectation _parseLastLine(List<String> lines) {
  final last = lines.lastOrNull ?? '';
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
  final finalLine = block.split('\n').lastOrNull ?? '';
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
    if (_s.startsWith('...', _i)) {
      // `...` is the cycle marker. The worker hands a cycle back as its
      // marker string, as upstream's Python host does (`arena_reader.dart`),
      // so the expectation holds the same string. The repr comparison, which
      // the worker runner makes whenever it renders one, tells the marker
      // from a real `'[...]'` string.
      if (!_consume('...')) return null;
      _skipSpace();
      if (!_consume(close)) return null;

      return MontyString(marker);
    }
    final list = <Object?>[];
    final map = <String, Object?>{};
    while (true) {
      _skipSpace();
      if (_peek() == close) {
        _i++;
        break;
      }
      if (!_readItem(list, map, isDict)) return null;
      _skipSpace();
      if (_s.startsWith(',', _i)) {
        _i++;
      }
    }

    return isDict ? map : list;
  }

  /// Reads one item of a collection: a `key: value` pair for a dict, a value
  /// for a list. Returns false when the item is not there.
  bool _readItem(List<Object?> list, Map<String, Object?> map, bool isDict) {
    final key = _value();
    if (_error) return false;
    if (!isDict) {
      list.add(key);

      return true;
    }
    _skipSpace();
    if (!_consume(':')) return false;
    final value = _value();
    if (_error) return false;
    map['$key'] = value;

    return true;
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
