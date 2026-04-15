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

sealed class FixtureExpectation {
  const FixtureExpectation();
}

final class ExpectReturn extends FixtureExpectation {
  const ExpectReturn(this.value);
  final Object? value;
}

final class ExpectRaise extends FixtureExpectation {
  const ExpectRaise({required this.excType, required this.message});
  final String excType;
  final String message;
}

final class ExpectNoException extends FixtureExpectation {
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
  bool skipWasm = false,
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
      if (targets.contains('monty')) return null;
      if (skipWasm && targets.contains('wasm')) return null;
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
  if (raw == 'None') return null;
  if (raw == 'True') return true;
  if (raw == 'False') return false;

  final asInt = int.tryParse(raw);
  if (asInt != null) return asInt;

  final asDouble = double.tryParse(raw);
  if (asDouble != null) return asDouble;

  if ((raw.startsWith("'") && raw.endsWith("'")) ||
      (raw.startsWith('"') && raw.endsWith('"'))) {
    return raw.substring(1, raw.length - 1);
  }

  return raw;
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
