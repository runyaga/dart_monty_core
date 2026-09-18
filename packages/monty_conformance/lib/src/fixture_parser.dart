// Fixture directive parser for .py test case files.
//
// Directive placement:
//   - Skip/mode directives (xfail, call-external, run-async, mount-fs) appear at the TOP.
//   - Expectation directives (Return=, Raise=) appear at the END.
//
// Fallback: if no comment directive is found, scan for a TRACEBACK docstring
// of the form:
//   """
//   TRACEBACK:
//   Traceback (most recent call last):
//     ...
//   ExcType: message
//   """
// and derive ExpectRaise from the last non-empty line.
//
// Returns null when the fixture must be skipped.

import 'package:dart_monty_core/dart_monty_core.dart';

/// What a fixture's directives say must happen when it runs.
sealed class FixtureExpectation {
  /// Creates a [FixtureExpectation].
  const FixtureExpectation();
}

/// The fixture declared `# Return=<repr>`: it must complete with that value.
final class ExpectReturn extends FixtureExpectation {
  /// Creates an [ExpectReturn] expecting [value].
  const ExpectReturn(this.value);

  /// The parsed Python repr, as a plain Dart value. Compare against a real
  /// result with `MontyValue.fromDart(value)`.
  final Object? value;
}

/// The fixture declared `# Raise=<ExcType>: <message>`, or carried a
/// `TRACEBACK:` docstring, so running it must raise.
final class ExpectRaise extends FixtureExpectation {
  /// Creates an [ExpectRaise].
  const ExpectRaise({required this.excType, required this.message});

  /// The Python exception class name, e.g. `ValueError`.
  final String excType;

  /// The exception message. Not every harness asserts on this — the excType
  /// is the stable part.
  final String message;
}

/// The fixture declared no outcome directive: it must simply not raise.
final class ExpectNoException extends FixtureExpectation {
  /// Creates an [ExpectNoException].
  const ExpectNoException();
}

/// Returns `true` when [source] declares a `# call-external` directive,
/// meaning the fixture requires external function dispatch to run.
bool fixtureIsCallExternal(String source) {
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('#')) continue;
    final directive = line.substring(1).trim();
    if (directive == 'call-external' ||
        directive.startsWith('call-external ')) {
      return true;
    }
  }

  return false;
}

/// Returns `true` when [source] declares a `# run-async` directive,
/// meaning the fixture uses top-level `await` and requires async dispatch.
bool fixtureIsRunAsync(String source) {
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('#')) continue;
    final directive = line.substring(1).trim();
    if (directive == 'run-async' || directive.startsWith('run-async ')) {
      return true;
    }
  }

  return false;
}

/// Returns `true` when [source] declares a `# mount-fs` directive,
/// meaning the fixture expects a `root` Path variable pointing to a
/// pre-populated virtual filesystem.
bool fixtureMountsFs(String source) {
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('#')) continue;
    final directive = line.substring(1).trim();
    if (directive == 'mount-fs' || directive.startsWith('mount-fs ')) {
      return true;
    }
  }

  return false;
}

/// Parses a `.py` fixture and returns the expected outcome.
///
/// Returns `null` when the fixture should be skipped:
/// - `# xfail=monty` or `# xfail=monty,cpython` — not yet supported
/// - `# xfail=wasm` — expected failure on WASM backend only
/// - `# call-external` — requires external function dispatch (skip unless
///   [skipCallExternal] is false)
/// - `# run-async` — requires async execution mode (skip unless
///   [skipRunAsync] is false)
/// - `# mount-fs` — requires filesystem mount (skip unless
///   [skipMountFs] is false)
///
/// `# xfail=cpython` is NOT a skip — monty supports these cases.
FixtureExpectation? parseFixture(
  String source, {
  bool skipCallExternal = true,
  bool skipMountFs = true,
  bool skipRunAsync = true,
}) {
  final lines = source.split('\n');

  FixtureExpectation? result;

  for (final raw in lines) {
    final line = raw.trim();
    if (!line.startsWith('#')) continue;

    final directive = line.substring(1).trim();

    if (directive.startsWith('xfail=')) {
      final targets = directive.substring('xfail='.length).trim().toLowerCase();
      // `xfail=monty` means upstream expects MONTY to fail, so there is
      // nothing here for us to assert.
      //
      // There was also a `skipWasm` flag gating `targets.contains('wasm')`.
      // The 0.19 corpus contains ZERO `xfail=wasm` fixtures (9 are
      // `xfail=cpython`, 1 is `xfail=monty`), so that branch could never fire
      // — while the flag was threaded through 13 call sites looking as though
      // it meant "skip what does not work on wasm". A parameter that cannot
      // change any outcome is worse than absent: it invites callers to believe
      // they have opted into something.
      if (targets.contains('monty')) return null;
      continue;
    }

    if ((skipCallExternal &&
            (directive == 'call-external' ||
                directive.startsWith('call-external '))) ||
        (skipRunAsync &&
            (directive == 'run-async' || directive.startsWith('run-async '))) ||
        (skipMountFs &&
            (directive == 'mount-fs' || directive.startsWith('mount-fs ')))) {
      return null;
    }

    if (directive.startsWith('Return=')) {
      final raw2 = directive.substring('Return='.length).trim();
      result = ExpectReturn(_parseReturnValue(raw2));
      continue;
    }

    if (directive.startsWith('Raise=')) {
      final raw2 = directive.substring('Raise='.length).trim();
      result = _parseRaise(raw2);
      continue;
    }
  }

  // If no explicit directive, look for a TRACEBACK docstring.
  // Pattern: """\nTRACEBACK:\n...\nExcType: message\n"""
  result ??= _parseTracebackDocstring(source);

  return result ?? const ExpectNoException();
}

/// Scans `source` for a docstring block of the form:
/// ```python
/// """
/// TRACEBACK:
/// ...
/// ExcType: message
/// """
/// ```
/// Returns [ExpectRaise] if found, otherwise null.
ExpectRaise? _parseTracebackDocstring(String source) {
  // Find opening """ followed by newline + TRACEBACK:
  const marker = '"""\nTRACEBACK:';
  final start = source.indexOf(marker);
  if (start < 0) return null;

  // Find the closing """
  final afterMarker = start + 3; // skip opening """
  final end = source.indexOf('\n"""', afterMarker);
  if (end < 0) return null;

  final block = source.substring(afterMarker, end);
  final blockLines = block.split('\n');

  // Walk from the end, find the last non-empty line
  for (final rawLine in blockLines.reversed) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    // Expected format: "ExcType: message" or bare "ExcType" (no message)
    final colonIdx = line.indexOf(':');
    final excType = colonIdx < 0
        ? line.trim()
        : line.substring(0, colonIdx).trim();

    // Basic sanity: exception types are PascalCase identifiers (letters only)
    if (excType.isEmpty || !RegExp(r'^[A-Z][A-Za-z]+$').hasMatch(excType)) {
      break;
    }

    final message = colonIdx < 0 ? '' : line.substring(colonIdx + 1).trim();

    return ExpectRaise(excType: excType, message: message);
  }

  return null;
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

FixtureExpectation _parseRaise(String raw) {
  final parenIdx = raw.indexOf('(');
  if (parenIdx < 0) {
    return ExpectRaise(excType: raw.trim(), message: '');
  }
  final excType = raw.substring(0, parenIdx).trim();
  final msgRaw = raw.substring(parenIdx + 1, raw.length - 1).trim();

  final message =
      ((msgRaw.startsWith("'") && msgRaw.endsWith("'")) ||
          (msgRaw.startsWith('"') && msgRaw.endsWith('"')))
      ? msgRaw.substring(1, msgRaw.length - 1)
      : msgRaw;

  return ExpectRaise(excType: excType, message: message);
}
