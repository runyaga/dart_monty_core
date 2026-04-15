/// Shared utilities for capturing the last expression in user code.
///
/// Used by both `MontySession` and `AgentSession` to wrap the trailing
/// expression as `__r = (expr)` so it becomes the execution's return value.
library;

/// Matches simple assignment targets: `identifier = ...`
///
/// Only captures a single identifier before `=`.
/// Excludes `==` (comparison) and augmented assignments (`+=`, etc.).
final assignmentPattern = RegExp(r'^([a-zA-Z]\w*)\s*=[^=]', multiLine: true);

/// Python keyword prefixes that indicate a line is a statement (not an
/// expression). Used to detect the user code's last expression so it can
/// be captured before the persist postamble runs.
const statementPrefixes = [
  'if ',
  'for ',
  'while ',
  'with ',
  'try:',
  'def ',
  'class ',
  'import ',
  'from ',
  'raise ',
  'return ',
  'pass',
  'break',
  'continue',
  'assert ',
];

/// Checks whether [line] looks like a Python expression (not a statement).
///
/// Returns `false` for lines starting with known statement keywords,
/// assignments (`name = ...`), or empty/comment lines.
bool isExpression(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.startsWith('#')) return false;

  for (final prefix in statementPrefixes) {
    if (trimmed.startsWith(prefix) || trimmed == prefix.trim()) return false;
  }

  if (assignmentPattern.hasMatch(trimmed)) return false;

  return true;
}

/// Processes [userCode] to capture the last expression's value.
///
/// If the trailing non-empty lines form an expression (single-line or
/// multi-line via brackets), replaces the expression with
/// `__r = (expression)` and returns `(modifiedCode, true)`.
///
/// Multi-line expressions are detected by scanning backwards from the
/// last non-empty line, tracking `()`, `[]`, and `{}` depth. A dict
/// literal, list literal, or function call spanning multiple lines is
/// captured as a single expression.
///
/// If the last line is a statement (or there is no code), returns
/// `(userCode, false)`.
(String, bool) captureLastExpression(String userCode) {
  final lines = userCode.split('\n');

  // Find last non-empty, non-comment line index.
  var lastIdx = -1;
  for (var i = lines.length - 1; i >= 0; i--) {
    final trimmed = lines[i].trim();
    if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
      lastIdx = i;
      break;
    }
  }

  if (lastIdx < 0) return (userCode, false);

  // Find where the expression actually starts. For multi-line
  // expressions (dict/list/tuple literals, multi-line calls), scan
  // backwards tracking bracket depth to find the opening line.
  final startIdx = _findExpressionStart(lines, lastIdx);

  // Check whether the first line of the expression is a statement.
  if (!isExpression(lines[startIdx])) return (userCode, false);

  // Join the (possibly multi-line) expression and wrap it.
  final exprLines = lines.sublist(startIdx, lastIdx + 1);
  final expr = exprLines.join('\n');

  final result = [
    ...lines.sublist(0, startIdx),
    '__r = ($expr)',
    ...lines.sublist(lastIdx + 1),
  ];

  return (result.join('\n'), true);
}

String? _assignmentName(String segment) {
  final match = assignmentPattern.firstMatch(segment.trimLeft());
  if (match == null) return null;
  final name = match.group(1)!;
  return name.startsWith('_') ? null : name;
}

/// Extracts top-level assignment target names from [code].
///
/// Only considers lines with no leading whitespace (top-level).
/// Handles semicolons for multi-statement lines.
/// Excludes names starting with `_` (internal/dunder).
Set<String> extractAssignmentTargets(String code) {
  final names = <String>{};
  for (final line in code.split('\n')) {
    if (line.isEmpty || line[0] == ' ' || line[0] == '\t') continue;
    for (final segment in line.split(';')) {
      final name = _assignmentName(segment);
      if (name != null) names.add(name);
    }
  }
  return names;
}

/// Returns the net depth change (positive = more closers) for a bracket char.
/// Returns 0 for non-bracket characters.
int _bracketDepthDelta(String ch) {
  if (ch == ')' || ch == ']' || ch == '}') return 1;
  if (ch == '(' || ch == '[' || ch == '{') return -1;
  return 0;
}

/// Scans [line] and returns the bracket depth after processing it,
/// starting from [initialDepth]. Ignores characters inside string literals.
int _depthAfterLine(String line, int initialDepth) {
  var depth = initialDepth;
  var inString = false;
  var stringChar = '';
  var escaped = false;
  for (var c = 0; c < line.length; c++) {
    final ch = line[c];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch == r'\') {
      escaped = true;
      continue;
    }
    if (inString) {
      if (ch == stringChar) inString = false;
      continue;
    }
    if (ch == "'" || ch == '"') {
      inString = true;
      stringChar = ch;
      continue;
    }
    depth += _bracketDepthDelta(ch);
  }
  return depth;
}

/// Scans backwards from [lastIdx] tracking bracket depth to find where
/// a multi-line expression begins (e.g. `{\n  "a": 1,\n}`).
///
/// Returns [lastIdx] when the last line is a complete single-line
/// expression. Returns an earlier index when unclosed brackets indicate
/// the expression spans multiple lines.
int _findExpressionStart(List<String> lines, int lastIdx) {
  var depth = 0;
  for (var i = lastIdx; i >= 0; i--) {
    depth = _depthAfterLine(lines[i], depth);
    if (depth <= 0) return i;
  }
  return 0;
}
