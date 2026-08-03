// Unit tests for MontyEllipsis (core#129).
//
// `...` used to serialize as the bare string "...", so Python's Ellipsis and
// the string "..." both arrived as MontyString and could not be told apart.
// The end-to-end behaviour is covered by _ellipsis_test_body.dart on both
// backends; these cover the value type itself, which the integration suites
// exercise only indirectly.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontyEllipsis', () {
    test('serializes to a tagged envelope, not a bare string', () {
      // The whole point of core#129: an untagged "..." is indistinguishable
      // from the Python string "...".
      const value = MontyEllipsis();

      expect(value.toJson(), {'__type': 'ellipsis'});
    });

    test('decodes from its own envelope', () {
      final v = MontyValue.fromJson({'__type': 'ellipsis'});
      expect(v, isA<MontyEllipsis>());
    });

    test('round-trips through toJson/fromJson', () {
      const original = MontyEllipsis();
      expect(MontyValue.fromJson(original.toJson()), original);
    });

    test('is not equal to the string "..."', () {
      // Guards the exact collapse core#129 was about.
      const ellipsis = MontyEllipsis();
      const dots = MontyString('...');

      expect(ellipsis, isNot(equals(dots)));
      expect(dots, isNot(equals(ellipsis)));
    });

    test('all instances are equal and share a hashCode', () {
      // There is exactly one Ellipsis, so every instance must be
      // interchangeable — including as a Map key or Set member.
      //
      // Deliberately NON-const: two distinct runtime instances. Const instances
      // are canonicalised to the same object, so `identical(a, b)` would hold
      // and the test would prove nothing about `==`/`hashCode`. It also keeps
      // the analyzer from folding the literals below and rejecting them under
      // `equal_elements_in_set` — for precisely the reason this test asserts.
      // Const would canonicalise these into one object.
      // ignore: prefer_const_constructors
      final a = MontyEllipsis();
      // Const would canonicalise these into one object.
      // ignore: prefer_const_constructors
      final b = MontyEllipsis();

      expect(identical(a, b), isFalse, reason: 'must be distinct instances');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(<MontyValue>{a, b}, hasLength(1));
      expect(<MontyValue, int>{a: 1, b: 2}, {a: 2});
    });

    test('dartValue represents itself — there is no Dart equivalent', () {
      const value = MontyEllipsis();

      expect(value.dartValue, value);
    });

    test('toString names the type', () {
      const value = MontyEllipsis();

      expect(value.toString(), 'MontyEllipsis()');
    });
  });
}
