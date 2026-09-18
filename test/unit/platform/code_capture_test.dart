// Unit tests for captureLastExpression / isExpression / extractAssignmentTargets.
//
// Pure string processing — no platform, no native dylib.
//
// captureLastExpression's "last non-empty, non-comment line" search is a
// `lastIndexWhere`, whose -1 on no match is the same sentinel the earlier
// hand-written backward loop initialised. The no-code cases below pin that.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('captureLastExpression — no code to capture', () {
    // Every one of these must leave the search at -1 and return the input
    // untouched with `false`.
    for (final (label, code) in [
      ('empty string', ''),
      ('single newline', '\n'),
      ('whitespace only', '  \n\t\n   '),
      ('comment only', '# just a comment'),
      ('comments and blanks', '\n# a\n\n   # b\n\n'),
    ]) {
      test(label, () {
        expect(captureLastExpression(code), (code, false));
      });
    }
  });

  group('captureLastExpression — single-line expression', () {
    test('wraps the only line', () {
      expect(captureLastExpression('x + 1'), ('__r = (x + 1)', true));
    });

    test('wraps the last line and keeps earlier lines', () {
      expect(
        captureLastExpression('x = 1\nx + 1'),
        ('x = 1\n__r = (x + 1)', true),
      );
    });

    test('skips trailing blank and comment lines, preserving them', () {
      expect(
        captureLastExpression('x = 1\nx + 1\n\n# done\n'),
        ('x = 1\n__r = (x + 1)\n\n# done\n', true),
      );
    });

    test('preserves indentation of the wrapped line', () {
      // Trim is only used to decide emptiness; the line itself is kept.
      expect(captureLastExpression('  x'), ('__r = (  x)', true));
    });
  });

  group('captureLastExpression — multi-line expression', () {
    test('dict literal spanning lines is captured as one expression', () {
      const code = 'y = 2\n{\n  "a": 1,\n  "b": y,\n}';
      expect(
        captureLastExpression(code),
        ('y = 2\n__r = ({\n  "a": 1,\n  "b": y,\n})', true),
      );
    });

    test('multi-line call is captured from its opening line', () {
      const code = 'f(\n  1,\n  2,\n)';
      expect(captureLastExpression(code), ('__r = (f(\n  1,\n  2,\n))', true));
    });

    test('brackets inside string literals do not affect depth', () {
      const code = 'x = 1\nprint(")")';
      expect(captureLastExpression(code), ('x = 1\n__r = (print(")"))', true));
    });

    test('escaped quote inside a string does not end the string', () {
      const code = r'"a\"("';
      expect(captureLastExpression(code), ('__r = ($code)', true));
    });

    test('unbalanced closer scans back to line 0', () {
      // Depth never returns to <= 0, so the start falls through to 0 and
      // the first line decides. `x = 1` is an assignment -> not captured.
      const code = 'x = 1\n)';
      expect(captureLastExpression(code), (code, false));
    });

    test('unbalanced closer with an expression at line 0 wraps everything', () {
      const code = 'x\n)';
      expect(captureLastExpression(code), ('__r = (x\n))', true));
    });
  });

  group('captureLastExpression — last line is a statement', () {
    for (final (label, code) in [
      ('assignment', 'x = 1'),
      ('return', 'return x'),
      ('bare pass', 'pass'),
      ('def header', 'def f():'),
      ('import', 'import os'),
      ('multi-line assignment target', 'd = {\n  "a": 1,\n}'),
    ]) {
      test(label, () {
        expect(captureLastExpression(code), (code, false));
      });
    }
  });

  group('isExpression', () {
    test('rejects blank and comment lines', () {
      expect(isExpression(''), isFalse);
      expect(isExpression('   '), isFalse);
      expect(isExpression('# c'), isFalse);
    });

    test('rejects every statement prefix, with and without trailing space', () {
      for (final prefix in statementPrefixes) {
        expect(isExpression('$prefix x'), isFalse, reason: prefix);
        expect(isExpression(prefix.trim()), isFalse, reason: prefix);
      }
    });

    test('rejects simple assignment but accepts comparison and augmented', () {
      expect(isExpression('x = 1'), isFalse);
      expect(isExpression('x == 1'), isTrue);
      expect(isExpression('x += 1'), isTrue);
    });

    test('accepts calls, names and literals', () {
      expect(isExpression('f(1)'), isTrue);
      expect(isExpression('x'), isTrue);
      expect(isExpression('[1, 2]'), isTrue);
      // A leading keyword-like identifier that is not a prefix is fine.
      expect(isExpression('iffy'), isTrue);
    });
  });

  group('extractAssignmentTargets', () {
    test('collects top-level targets only', () {
      expect(
        extractAssignmentTargets('a = 1\n  b = 2\n\tc = 3\nd=4'),
        {'a', 'd'},
      );
    });

    test('splits on semicolons', () {
      expect(extractAssignmentTargets('a = 1; b = 2'), {'a', 'b'});
    });

    test('ignores underscore-prefixed names, comparisons and blanks', () {
      expect(extractAssignmentTargets('_p = 1\n__r = 2\nx == 3\n\n'), isEmpty);
    });
  });
}
