// Unit tests for inputs_encoder: toPythonLiteral and inputsToCode.
@Tags(['unit'])
library;

import 'package:dart_monty_core/src/platform/inputs_encoder.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  group('toPythonLiteral', () {
    test('null → None', () {
      expect(toPythonLiteral(null), 'None');
    });

    test('true → True', () {
      expect(toPythonLiteral(true), 'True');
    });

    test('false → False', () {
      expect(toPythonLiteral(false), 'False');
    });

    test('int', () {
      expect(toPythonLiteral(42), '42');
      expect(toPythonLiteral(-7), '-7');
      expect(toPythonLiteral(0), '0');
    });

    test('double', () {
      expect(toPythonLiteral(3.14), '3.14');
      expect(toPythonLiteral(-0.5), '-0.5');
    });

    test('double nan', () {
      expect(toPythonLiteral(double.nan), "float('nan')");
    });

    test('double infinity', () {
      expect(toPythonLiteral(double.infinity), "float('inf')");
    });

    test('double negative infinity', () {
      expect(toPythonLiteral(double.negativeInfinity), "float('-inf')");
    });

    test('plain string', () {
      expect(toPythonLiteral('hello'), "'hello'");
    });

    test('string with single quote escaped', () {
      expect(toPythonLiteral("it's"), r"'it\'s'");
    });

    test('string with backslash escaped', () {
      expect(toPythonLiteral(r'a\b'), r"'a\\b'");
    });

    test('string with newline escaped', () {
      expect(toPythonLiteral('line1\nline2'), r"'line1\nline2'");
    });

    test('string with carriage-return escaped', () {
      expect(toPythonLiteral('a\rb'), r"'a\rb'");
    });

    test('string with tab escaped', () {
      expect(toPythonLiteral('a\tb'), r"'a\tb'");
    });

    test('empty string', () {
      expect(toPythonLiteral(''), "''");
    });

    test('list of ints', () {
      expect(toPythonLiteral([1, 2, 3]), '[1, 2, 3]');
    });

    test('empty list', () {
      expect(toPythonLiteral(<dynamic>[]), '[]');
    });

    test('nested list', () {
      expect(
        toPythonLiteral([
          [1, 2],
          [3],
        ]),
        '[[1, 2], [3]]',
      );
    });

    test('dict', () {
      expect(
        toPythonLiteral({'a': 1, 'b': 2}),
        "{'a': 1, 'b': 2}",
      );
    });

    test('empty dict', () {
      expect(toPythonLiteral(<dynamic, dynamic>{}), '{}');
    });

    test('dict with string values', () {
      expect(
        toPythonLiteral({'key': 'val'}),
        "{'key': 'val'}",
      );
    });

    test('list with mixed types', () {
      expect(
        toPythonLiteral([1, 'two', null, true]),
        "[1, 'two', None, True]",
      );
    });

    test('unsupported type throws ArgumentError', () {
      expect(() => toPythonLiteral(Object()), throwsArgumentError);
    });
  });

  // -------------------------------------------------------------------------
  group('inputsToCode', () {
    test('empty map returns empty string', () {
      expect(inputsToCode({}), '');
    });

    test('single int entry', () {
      expect(inputsToCode({'x': 42}), 'x = 42');
    });

    test('single bool entry uses Python capitalisation', () {
      expect(inputsToCode({'flag': true}), 'flag = True');
    });

    test('single string entry', () {
      expect(inputsToCode({'name': 'Alice'}), "name = 'Alice'");
    });

    test('null entry → None', () {
      expect(inputsToCode({'x': null}), 'x = None');
    });

    test('nan entry', () {
      expect(inputsToCode({'f': double.nan}), "f = float('nan')");
    });

    test('infinity entry', () {
      expect(inputsToCode({'f': double.infinity}), "f = float('inf')");
    });

    test('list entry', () {
      expect(
        inputsToCode({
          'lst': [1, 2, 3],
        }),
        'lst = [1, 2, 3]',
      );
    });

    test('dict entry', () {
      expect(
        inputsToCode({
          'd': {'a': 1},
        }),
        "d = {'a': 1}",
      );
    });

    test('multiple entries separated by newline', () {
      final code = inputsToCode({'x': 1, 'y': 2});
      expect(code, 'x = 1\ny = 2');
    });

    test('unsupported value type propagates ArgumentError', () {
      expect(() => inputsToCode({'bad': Object()}), throwsArgumentError);
    });
  });
}
