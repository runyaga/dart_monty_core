// Unit tests for code_capture.dart — pure expression/statement detection
// and assignment-target extraction. No platform or interpreter dependency.
@Tags(['unit'])
library;

import 'package:dart_monty_core/src/platform/code_capture.dart';
import 'package:test/test.dart';

void main() {
  group('isExpression', () {
    group('returns false', () {
      test('empty string', () {
        expect(isExpression(''), isFalse);
      });

      test('whitespace only', () {
        expect(isExpression('   '), isFalse);
      });

      test('comment line', () {
        expect(isExpression('# a comment'), isFalse);
      });

      test('comment with leading whitespace', () {
        expect(isExpression('  # indented comment'), isFalse);
      });

      test('if statement', () {
        expect(isExpression('if x > 0:'), isFalse);
      });

      test('for statement', () {
        expect(isExpression('for i in range(10):'), isFalse);
      });

      test('while statement', () {
        expect(isExpression('while True:'), isFalse);
      });

      test('with statement', () {
        expect(isExpression('with open("f") as f:'), isFalse);
      });

      test('try statement', () {
        expect(isExpression('try:'), isFalse);
      });

      test('def statement', () {
        expect(isExpression('def foo():'), isFalse);
      });

      test('class statement', () {
        expect(isExpression('class Foo:'), isFalse);
      });

      test('import statement', () {
        expect(isExpression('import os'), isFalse);
      });

      test('from import statement', () {
        expect(isExpression('from os import path'), isFalse);
      });

      test('raise statement', () {
        expect(isExpression('raise ValueError("bad")'), isFalse);
      });

      test('return statement', () {
        expect(isExpression('return x'), isFalse);
      });

      test('pass statement', () {
        expect(isExpression('pass'), isFalse);
      });

      test('break statement', () {
        expect(isExpression('break'), isFalse);
      });

      test('continue statement', () {
        expect(isExpression('continue'), isFalse);
      });

      test('assert statement', () {
        expect(isExpression('assert x == 1'), isFalse);
      });

      test('simple assignment', () {
        expect(isExpression('x = 1'), isFalse);
      });

      test('assignment with no spaces', () {
        expect(isExpression('x=1'), isFalse);
      });

      test('assignment with leading whitespace', () {
        expect(isExpression('  x = 1'), isFalse);
      });
    });

    group('returns true', () {
      test('simple expression', () {
        expect(isExpression('x + 1'), isTrue);
      });

      test('function call', () {
        expect(isExpression('len(items)'), isTrue);
      });

      test('ternary expression', () {
        // Starts with identifier, not keyword
        expect(isExpression('x if y else z'), isTrue);
      });

      test('augmented assignment is expression-like', () {
        // += does not match assignment pattern (requires [^=] after =)
        expect(isExpression('x += 1'), isTrue);
      });

      test('chained comparison', () {
        expect(isExpression('1 < x < 10'), isTrue);
      });

      test('equality check', () {
        expect(isExpression('x == 1'), isTrue);
      });

      test('dict literal', () {
        expect(isExpression('{"a": 1}'), isTrue);
      });

      test('list literal', () {
        expect(isExpression('[1, 2, 3]'), isTrue);
      });

      test('method call', () {
        expect(isExpression('obj.method()'), isTrue);
      });

      test('numeric literal', () {
        expect(isExpression('42'), isTrue);
      });

      test('string literal', () {
        expect(isExpression('"hello"'), isTrue);
      });
    });
  });

  // ---------------------------------------------------------------------------

  group('captureLastExpression', () {
    test('empty string returns unchanged with false', () {
      final (code, captured) = captureLastExpression('');
      expect(captured, isFalse);
      expect(code, '');
    });

    test('whitespace-only returns unchanged with false', () {
      final (code, captured) = captureLastExpression('   \n  \n');
      expect(captured, isFalse);
    });

    test('comment-only returns unchanged with false', () {
      final (code, captured) = captureLastExpression(
        '# just a comment\n# another',
      );
      expect(captured, isFalse);
    });

    test('single expression is captured', () {
      final (code, captured) = captureLastExpression('x + 1');
      expect(captured, isTrue);
      expect(code, '__r = (x + 1)');
    });

    test('single statement is not captured', () {
      final (code, captured) = captureLastExpression('x = 1');
      expect(captured, isFalse);
      expect(code, 'x = 1');
    });

    test('expression after statement is captured', () {
      final (code, captured) = captureLastExpression('x = 1\nx + 1');
      expect(captured, isTrue);
      expect(code, 'x = 1\n__r = (x + 1)');
    });

    test('statement after expression is not captured', () {
      final (code, captured) = captureLastExpression('x + 1\ny = 2');
      expect(captured, isFalse);
    });

    test('trailing blank lines are skipped', () {
      final (code, captured) = captureLastExpression('x + 1\n\n');
      expect(captured, isTrue);
      expect(code, '__r = (x + 1)\n\n');
    });

    test('trailing comment lines are skipped', () {
      final (code, captured) = captureLastExpression(
        'x + 1\n# trailing comment',
      );
      expect(captured, isTrue);
      expect(code, '__r = (x + 1)\n# trailing comment');
    });

    test('multi-line dict literal is captured as one expression', () {
      const src = '{\n  "a": 1,\n  "b": 2\n}';
      final (code, captured) = captureLastExpression(src);
      expect(captured, isTrue);
      expect(code, '__r = ($src)');
    });

    test('multi-line list literal is captured', () {
      const src = '[\n  1,\n  2,\n  3\n]';
      final (code, captured) = captureLastExpression(src);
      expect(captured, isTrue);
      expect(code, '__r = ($src)');
    });

    test('multi-line function call is captured', () {
      const src = 'foo(\n  a,\n  b\n)';
      final (code, captured) = captureLastExpression(src);
      expect(captured, isTrue);
      expect(code, '__r = ($src)');
    });

    test('statement before multi-line expression preserved', () {
      const src = 'x = 1\n{\n  "k": x\n}';
      final (code, captured) = captureLastExpression(src);
      expect(captured, isTrue);
      expect(code, 'x = 1\n__r = ({\n  "k": x\n})');
    });

    test('brackets inside string do not affect depth', () {
      // The string "{}" should not confuse bracket tracking
      final (code, captured) = captureLastExpression('"result: {}"');
      expect(captured, isTrue);
      expect(code, '__r = ("result: {}")');
    });
  });

  // ---------------------------------------------------------------------------

  group('extractAssignmentTargets', () {
    test('empty code returns empty set', () {
      expect(extractAssignmentTargets(''), isEmpty);
    });

    test('simple assignment', () {
      expect(extractAssignmentTargets('x = 1'), {'x'});
    });

    test('multiple assignments on separate lines', () {
      expect(
        extractAssignmentTargets('x = 1\ny = 2\nz = 3'),
        {'x', 'y', 'z'},
      );
    });

    test('multi-statement line with semicolons', () {
      expect(
        extractAssignmentTargets('x = 1; y = 2'),
        {'x', 'y'},
      );
    });

    test('indented lines are skipped', () {
      expect(extractAssignmentTargets('  x = 1'), isEmpty);
    });

    test('tab-indented lines are skipped', () {
      expect(extractAssignmentTargets('\tx = 1'), isEmpty);
    });

    test('underscore-prefixed names are excluded', () {
      expect(extractAssignmentTargets('_private = 1'), isEmpty);
    });

    test('dunder names are excluded', () {
      expect(extractAssignmentTargets('__r = 1'), isEmpty);
    });

    test('augmented assignment is not captured', () {
      expect(extractAssignmentTargets('x += 1'), isEmpty);
    });

    test('equality check is not captured', () {
      expect(extractAssignmentTargets('x == 1'), isEmpty);
    });

    test('assignment without spaces', () {
      expect(extractAssignmentTargets('x=1'), {'x'});
    });

    test('expression line without assignment', () {
      expect(extractAssignmentTargets('x + 1'), isEmpty);
    });

    test('mixed lines', () {
      const code = 'x = 1\nif True:\n  y = 2\nz = x + 1';
      // y is indented; z has no assignment target (expression)
      expect(extractAssignmentTargets(code), {'x', 'z'});
    });
  });
}
