// MontyFileHandle as upstream's `pydantic_monty.MontyFileHandle(path, mode,
// *, position=0)` (convert.rs:430-490): the mode parsed and canonicalised at
// construction with FileMode's messages, the three flags, a u64 position,
// and the repr. Upstream's answers are recorded by
// tool/generate_value_oracle.py (_value_oracle.g.dart).
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal;
import 'package:test/test.dart';

import '_value_oracle.g.dart';

void main() {
  group('the mode, as upstream parses it', () {
    for (final MapEntry(key: mode, value: outcome) in fileModeOracle.entries) {
      test('${mode.isEmpty ? '(empty)' : mode.replaceAll('\n', r'\n')}: '
          '$outcome', () {
        if (outcome.startsWith('ValueError: ')) {
          expect(
            () => MontyFileHandle('/x', mode),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                outcome.substring('ValueError: '.length),
              ),
            ),
          );
        } else {
          final h = MontyFileHandle('/x', mode);
          expect(
            'mode=${h.mode} binary=${_py(h.binary)} '
            'readable=${_py(h.readable)} writable=${_py(h.writable)}',
            outcome,
          );
        }
      });
    }
  });

  group('the repr, as upstream renders it', () {
    for (final MapEntry(key: path, value: repr) in fileReprOracle.entries) {
      test(repr, () {
        final h = MontyFileHandle(
          path,
          'rb',
          position: BigInt.two.pow(64) - BigInt.one,
        );
        expect(h.toString(), repr);
      });
    }
  });

  group('the position, a u64', () {
    for (final MapEntry(key: text, value: outcome)
        in filePositionOracle.entries) {
      test('$text: $outcome', () {
        final n = BigInt.parse(text);
        if (outcome.startsWith('OverflowError')) {
          expect(
            () => MontyFileHandle('/x', 'r', position: n),
            throwsArgumentError,
          );
        } else {
          expect(
            MontyFileHandle('/x', 'r', position: n).position.toString(),
            outcome.substring('position='.length),
          );
        }
      });
    }

    test('defaults to zero', () {
      expect(MontyFileHandle('/x', 'r').position, BigInt.zero);
    });

    test('projects as a number up to 2^53 and as text beyond', () {
      final two53 = BigInt.two.pow(53);
      MontyFileHandle at(BigInt p) => MontyFileHandle('/x', 'r', position: p);
      expect(at(two53).dartValue['position'], 9007199254740992);
      expect(at(two53 + BigInt.one).dartValue['position'], '9007199254740993');
      expect(at(two53).toJson(), {
        '__type': 'filehandle',
        'path': '/x',
        'mode': 'r',
        'position': 9007199254740992,
      });
    });
  });

  test('a path Python cannot hold (a lone surrogate) is refused', () {
    // py_new extracts the path as a Rust String (Q51): no such handle
    // exists in Python, so it is a host programming error.
    expect(() => MontyFileHandle('/a\uD800', 'r'), throwsArgumentError);
  });

  test('two handles with equal fields are equal (a kept divergence)', () {
    final a = MontyFileHandle('/f', 'rt', position: BigInt.one);
    final b = MontyFileHandle('/f', 'r', position: BigInt.one);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(MontyFileHandle('/f', 'r', position: BigInt.two)));
    expect(a, isNot(MontyFileHandle('/g', 'r', position: BigInt.one)));
    expect(a, isNot(MontyFileHandle('/f', 'rb', position: BigInt.one)));
  });
}

/// A bool as Python prints it.
String _py(bool b) => b ? 'True' : 'False';
