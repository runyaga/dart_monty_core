// Unit tests for inputs_encoder: toPythonLiteral and inputsToCode.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyInternalError, MontyNone;
import 'package:dart_monty_core/src/platform/inputs_encoder.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  group('toPythonLiteral', () {
    test('null throws MontyInternalError', () {
      expect(
        () => toPythonLiteral(null),
        throwsA(isA<MontyInternalError>()),
      );
    });

    test('MontyNone() → None', () {
      expect(toPythonLiteral(const MontyNone()), 'None');
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
        toPythonLiteral([1, 'two', const MontyNone(), true]),
        "[1, 'two', None, True]",
      );
    });

    test('unsupported type throws ArgumentError', () {
      expect(() => toPythonLiteral(Object()), throwsA(isA<ArgumentError>()));
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

    test('MontyNone entry → None', () {
      expect(inputsToCode({'x': const MontyNone()}), 'x = None');
    });

    test('null entry throws MontyInternalError', () {
      expect(
        () => inputsToCode({'x': null}),
        throwsA(isA<MontyInternalError>()),
      );
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
      expect(
        () => inputsToCode({'bad': Object()}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // core#137 — the key was a code-injection primitive.
  //
  // `inputsToCode` interpolates each key into Python SOURCE. The doc said keys
  // must be identifiers and nothing checked, so any key that parsed as Python
  // simply executed. These are the payload shapes, not a paraphrase of the
  // rule: a rule test would pass against a regex that still lets a newline
  // through.
  group('inputsToCode rejects a key that is not an identifier', () {
    const payloads = {
      'statement separator': 'ignored = 0\nanswer = "INJECTED"\nz',
      'semicolon': "x = 1; import os; os.system('id')  #",
      'trailing comment opens the line': 'x  #',
      'call expression': 'print("pwned")',
      'attribute assignment': 'obj.attr',
      'subscript assignment': 'a[0]',
      'leading digit is not an identifier': '1x',
      'bare whitespace': 'a b',
      'empty key': '',
      'NUL truncates the program at the C boundary (FB-6)': 'x = 1\u0000',
    };

    for (final MapEntry(key: name, value: key) in payloads.entries) {
      test(name, () {
        expect(
          () => inputsToCode({key: 1}),
          throwsA(isA<ArgumentError>()),
          reason: 'a key that is not an identifier reaches Python as source',
        );
      });
    }

    test('a legitimate identifier still works', () {
      expect(
        inputsToCode({'answer_2': 1, '_private': 2}),
        'answer_2 = 1\n_private = 2',
      );
    });

    test('a non-ASCII identifier is accepted, because Python accepts it', () {
      // An ASCII-only rule would reject keys that work today, which would be a
      // regression dressed up as a security fix.
      expect(inputsToCode({'café': 1}), 'café = 1');
    });
  });

  // -------------------------------------------------------------------------
  // How a numeric input arrives in Python, per backend.
  //
  // Measured on dart2js: `4.0 is int` is TRUE, `4 is double` is TRUE, and
  // `double.infinity is int` is TRUE — the runtime check is effectively
  // `Math.floor(x) === x`. So `toPythonLiteral(Object?)` cannot recover what
  // the caller wrote. The rows below are split by whether that erasure is
  // recoverable.
  group('a numeric input renders as the right Python type', () {
    test('a fractional double is unchanged', () {
      expect(inputsToCode({'x': 1.5}), 'x = 1.5');
    });

    test('an integer input is still an int', () {
      expect(inputsToCode({'x': 4}), 'x = 4');
    });

    // Value-based, so ordering the guards ahead of the `int` arm fixes these
    // on every backend. Before that, dart2js emitted `f = Infinity` — a
    // NameError in Python — because an infinity satisfies `is int` there.
    test('infinity is valid Python on every backend', () {
      expect(inputsToCode({'f': double.infinity}), "f = float('inf')");
      expect(
        inputsToCode({'f': double.negativeInfinity}),
        "f = float('-inf')",
      );
    });

    test('nan is valid Python on every backend', () {
      expect(inputsToCode({'f': double.nan}), "f = float('nan')");
    });

    // NOT skipped on the VM, where the distinction survives and must hold.
    test(
      'an integral double keeps its point',
      () {
        expect(inputsToCode({'x': 4.0}), 'x = 4.0');
        expect(inputsToCode({'x': -0.0}), 'x = -0.0');
      },
      skip: _isJs ? _kJsErasure : null,
    );
  });
}

const _kJsErasure =
    'core#137 — dart2js erases 4.0 vs 4 before this function is entered; '
    'only a typed input (e.g. MontyFloat) can express the difference';

/// True on dart2js, where `int` and `double` are one runtime type.
///
/// dart2wasm has real doubles, so it is deliberately NOT covered by this: it
/// must pass the integral-double row like the VM.
// `identical(1, 1.0)` is the standard dart2js detector: there both literals
// are the same JS number. The VM and dart2wasm have real doubles and return
// false, which is what keeps this row live on those two backends.
// Deliberately a getter, not a `const`: const-evaluating this would resolve
// it in the shared front end rather than under the target's number model.
bool get _isJs => identical(1, 1.0);
