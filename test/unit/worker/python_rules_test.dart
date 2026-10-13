// The Python rules the arena reader applies, against CPython 3.12's own
// answers: `repr` of a str, `str.isidentifier()`, `PurePosixPath`, and the
// open() mode and Rust `{:?}` renderings of upstream's messages. Pure Dart,
// so the unit and unit_web steps run it on the VM, dart2js and dart2wasm.
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:dart_monty_core/src/worker/python_rules.dart';
import 'package:test/test.dart';

void main() {
  test('repr() of a str, as CPython renders it', () {
    // Each expected value is CPython 3.12's repr() of the input.
    const cases = {
      "a'b":
          '"'
          "a'b"
          '"',
      "a'b"
              '"':
          r"""'a\'b"'""",
      '\\\t\n\r\x00\x7f': r"'\\\t\n\r\x00\x7f'",
      '\x85\xa0\u00e9\u2028': "'\\x85\\xa0\u00e9\\u2028'",
      '\u{E0001}\u{1F600}': "'\\U000e0001\u{1F600}'",
      '\uD800x': r"'\ud800x'",
      '\uFFFF': r"'\uffff'",
      'x\u200By': r"'x\u200by'",
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect(pythonRepr(key), value, reason: key);
    }
  });

  test('str.isidentifier(), as CPython answers it', () {
    const cases = {
      '\u00e7': true,
      'a\u00b7b': true,
      '\u2118x': true,
      '\u00b7a': false,
      '_': true,
      '1': false,
      'a-b': false,
      '': false,
      '\ufb01': true,
      'x\u0300': true,
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect(isIdentifier(key), value, reason: key);
    }
  });

  test('PurePosixPath text', () {
    const cases = {
      '': '.',
      'a//./b/': 'a/b',
      '//a': '//a',
      '///a': '/a',
      '/./a/..': '/a/..',
      './a': 'a',
      '.': '.',
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect(purePosixPath(key), value, reason: key);
    }
  });

  test('open() modes upstream accepts, in canonical form', () {
    const cases = {
      'r': 'r',
      'rt': 'r',
      'tr': 'r',
      'rb': 'rb',
      'br': 'rb',
      'w': 'w',
      'wb': 'wb',
      'a': 'a',
      'ab': 'ab',
      'at': 'a',
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect(canonicalFileMode(key), value, reason: key);
    }
    for (final bad in ['', 'b', 'rw', 'r+', 'x', 'rbt', 'bb', 'tt', 'rr']) {
      expect(canonicalFileMode(bad), isNull, reason: bad);
    }
  });

  test("Rust's {:?} of a string", () {
    // Each expected value is Rust's format!("{:?}", s).
    expect(
      rustDebug('a"b\\c\t\n\r\x00\x01\x85é\u200B\u0301\u00a0 \u3164x'),
      r'"a\"b\\c\t\n\r\0\u{1}\u{85}é\u{200b}\u{301}\u{a0} \u{3164}x"',
    );
  });

  test('days from 0001-01-01', () {
    expect(ordinalDay(1, 1, 1), 0);
    expect(ordinalDay(1, 3, 1), 59);
    expect(ordinalDay(2000, 3, 1) - ordinalDay(2000, 2, 28), 2);
    expect(ordinalDay(1900, 3, 1) - ordinalDay(1900, 2, 28), 1);
    expect(ordinalDay(9999, 12, 31), 3652058);
  });
}
