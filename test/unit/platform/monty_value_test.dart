// Unit tests for the MontyValue subtypes — equality, hashCode, the internal
// tagged projection (toJson) and the dartValue projection.
//
// Pure value-level tests: no interpreter, no FFI, no WASM. Catches
// regressions in deep-equality and projection shape drift without needing
// the integration harness to fire.
@Tags(['unit'])
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal, montyClassProxy, montyClassTypeProxy;
import 'package:dart_monty_core/src/worker/python_rules.dart'
    show isIdentifier, isValidIdentifier, moduleNameError, sandboxModuleNames;
import 'package:meta/meta.dart';
import 'package:test/test.dart';

/// Upstream's `add`, one of the TOOLS functions.
int _add(int a, int b) => a + b;

/// Upstream's `concat`, the other TOOLS function.
String _concat(String a, String b) => a + b;

/// The protected member of TOOLS, never exposed to the sandbox.
String _probe() => 'hidden';

/// Upstream's `ADD_STUB`, the `.pyi` source of `add`.
const _addStub = 'def add(a: int, b: int) -> int: ...\n';

/// A canonical uuid4: lowercase hex, version digit 4, variant digit 8-b.
final RegExp _uuid4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Upstream's `TOOLS`, fresh on each call so edits to one copy cannot leak
/// into another.
Map<String, Object?> _tools() => {
  'add': _add,
  'concat': _concat,
  'VERSION': 3,
  '_secret': _probe,
};

/// Each row is refused at construction, eagerly: a non-string key, a key
/// that is not an identifier (a keyword included) and a nested module under
/// a key naming a module the sandbox provides itself.
void _rejectsInvalidModules() {
  final argError = isA<ArgumentError>();
  for (final (key, value, parts) in <(Object?, Object?, List<String>)>[
    (1, _add, ['str keys', 'int']),
    ('a.b', _add, ['identifier keys', "'a.b'"]),
    ('1sub', _add, ['identifier keys', "'1sub'"]),
    ('for', _add, ['identifier keys', "'for'"]),
    (
      'json',
      ExternalModule({'VERSION': 9}),
      [
        "attrs['json']",
        'provided by the sandbox',
      ],
    ),
  ]) {
    expect(
      () => ExternalModule({key: value}),
      throwsA(
        argError.having(
          (e) => e.message,
          'message',
          allOf([for (final part in parts) contains(part)]),
        ),
      ),
    );
  }
}

void main() {
  // ------------------------------------------------------------------
  // Scalars
  // ------------------------------------------------------------------

  group('MontyNone', () {
    test('all instances compare equal and share a hashCode', () {
      const a = MontyNone();
      const b = MontyNone();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('toJson is null', () {
      const a = MontyNone();
      expect(a.toJson(), isNull);
    });

    test('dartValue is null', () {
      expect(const MontyNone().dartValue, isNull);
    });

    test('toString contains type name', () {
      expect(const MontyNone().toString(), 'MontyNone()');
    });
  });

  group('MontyBool', () {
    test('equality + hashCode agree on value', () {
      const a = MontyBool(true);
      const b = MontyBool(true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyBool(false)));
    });

    test("is a number, as Python's bool is an int", () {
      expect(const MontyBool(true), const MontyInt(1));
      expect(const MontyBool(true).hashCode, const MontyInt(1).hashCode);
      expect(const MontyBool(false), const MontyFloat(0));
      expect(const MontyBool(true), isNot(const MontyInt(2)));
      expect(const MontyBool(true), isNot(const MontyString('True')));
    });

    test('toJson + dartValue', () {
      expect(const MontyBool(true).toJson(), true);
      expect(const MontyBool(false).dartValue, false);
    });
  });

  group('MontyInt', () {
    test('equality + hashCode', () {
      const a = MontyInt(42);
      const b = MontyInt(42);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyInt(43)));
      expect(const MontyInt(0), const MontyBool(false));
      expect(const MontyInt(0), isNot(const MontyString('0')));
    });

    test('toJson + dartValue within the exact range', () {
      expect(const MontyInt(42).toJson(), 42);
      expect(const MontyInt(-7).dartValue, -7);
      // 2^53 exactly is the last value every backend holds in a Dart `int`.
    });

    // The past-2^53 cases live in monty_value_int64_vm_test.dart. They cannot
    // be here: an `int` beyond 2^53 is unrepresentable on dart2js, and
    // `0x7FFFFFFFFFFFFFFF` is a dart2js COMPILE error — which would take this
    // whole file down with it, and a `skip:` cannot help because the failure
    // happens before any test runs.
  });

  group('MontyFloat', () {
    test('regular value equality + hashCode', () {
      const a = MontyFloat(3.14);
      const b = MontyFloat(3.14);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyFloat(2.71)));
    });

    test('NaN equals NaN (Python semantics, divergent from Dart double)', () {
      const a = MontyFloat(double.nan);
      const b = MontyFloat(double.nan);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('infinities and their negatives compare correctly', () {
      expect(
        const MontyFloat(double.infinity),
        const MontyFloat(double.infinity),
      );
      expect(
        const MontyFloat(double.negativeInfinity),
        const MontyFloat(double.negativeInfinity),
      );
      expect(
        const MontyFloat(double.infinity),
        isNot(const MontyFloat(double.negativeInfinity)),
      );
    });

    test('toJson encodes the non-finite forms as tagged envelopes', () {
      expect(const MontyFloat(double.nan).toJson(), {
        '__type': 'float',
        'value': 'NaN',
      });
      expect(const MontyFloat(double.infinity).toJson(), {
        '__type': 'float',
        'value': 'Infinity',
      });
      // Wire v3: the non-finite forms are TAGGED. They used to be bare strings,
      // which is why the str "NaN" decoded as a float.
      expect(const MontyFloat(double.negativeInfinity).toJson(), {
        '__type': 'float',
        'value': '-Infinity',
      });
      // A finite float is still a plain JSON number.
      expect(const MontyFloat(3.14).toJson(), 3.14);
    });
  });

  group('MontyString', () {
    test('equality + hashCode', () {
      const a = MontyString('hi');
      const b = MontyString('hi');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyString('bye')));
    });

    test('toJson + dartValue', () {
      expect(const MontyString('hello').toJson(), 'hello');
      expect(const MontyString('').dartValue, '');
    });

    test('the string "NaN" projects as a bare STRING', () {
      // Was: 'special-float strings are NOT mistaken for strings on
      // round-trip', asserting isA<MontyFloat>() and calling the collision "the
      // intended escape encoding" while documenting it as a limit. It was a
      // defect: `float('nan')` and the str `"NaN"` had one wire representation,
      // so the decoder had to guess and guessed wrong half the time. Non-finite
      // floats now carry a `float` envelope, and a bare string is a `str`.
      for (final text in ['NaN', 'Infinity', '-Infinity']) {
        expect(
          MontyString(text).toJson(),
          text,
          reason: 'the STRING "$text" must project as a string',
        );
      }
    });
  });

  // ------------------------------------------------------------------
  // Collections
  // ------------------------------------------------------------------

  group('MontyBytes', () {
    test('deep equality on byte list', () {
      const a = MontyBytes([1, 2, 3]);
      const b = MontyBytes([1, 2, 3]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyBytes([1, 2, 4])));
    });

    test('dartValue exposes the byte list', () {
      expect(const MontyBytes([1, 2, 3]).dartValue, [1, 2, 3]);
    });
  });

  group('MontyList', () {
    test('deep equality across nested values', () {
      const a = MontyList([MontyInt(1), MontyString('x'), MontyBool(true)]);
      const b = MontyList([MontyInt(1), MontyString('x'), MontyBool(true)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different element order is not equal', () {
      expect(
        const MontyList([MontyInt(1), MontyInt(2)]),
        isNot(const MontyList([MontyInt(2), MontyInt(1)])),
      );
    });

    test('toJson recursively serialises elements', () {
      expect(
        const MontyList([MontyInt(1), MontyString('x')]).toJson(),
        [1, 'x'],
      );
    });

    test('dartValue recursively projects', () {
      expect(
        const MontyList([MontyInt(1), MontyString('x')]).dartValue,
        [1, 'x'],
      );
    });
  });

  group('MontyTuple', () {
    test('equality + hashCode', () {
      const a = MontyTuple([MontyInt(1), MontyString('x')]);
      const b = MontyTuple([MontyInt(1), MontyString('x')]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('not equal to a MontyList with the same elements', () {
      const t = MontyTuple([MontyInt(1)]);
      const l = MontyList([MontyInt(1)]);
      expect(t, isNot(l));
    });

    test('toJson includes __type discriminator', () {
      expect(
        const MontyTuple([MontyInt(1)]).toJson(),
        {
          '__type': 'tuple',
          'value': [1],
        },
      );
    });
  });

  group('MontyDict', () {
    test('equality + hashCode (deep)', () {
      const a = MontyDict([(MontyString('k'), MontyInt(1))]);
      const b = MontyDict([(MontyString('k'), MontyInt(1))]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('order-independent equality, any key type', () {
      // Order-insensitive, matching the sandbox, which answers True for both
      // shapes. This used to hold ONLY for string keys: a non-string-keyed
      // dict was a separate class comparing as a List, so the same Python dict
      // compared UNEQUAL purely because its keys were not strings.
      const a = MontyDict([
        (MontyString('a'), MontyInt(1)),
        (MontyString('b'), MontyInt(2)),
      ]);
      const b = MontyDict([
        (MontyString('b'), MontyInt(2)),
        (MontyString('a'), MontyInt(1)),
      ]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      const c = MontyDict([
        (MontyInt(1), MontyString('a')),
        (MontyInt(2), MontyString('b')),
      ]);
      const d = MontyDict([
        (MontyInt(2), MontyString('b')),
        (MontyInt(1), MontyString('a')),
      ]);
      expect(c, d);
      expect(c.hashCode, d.hashCode);
    });

    test('unequal when a value differs', () {
      const a = MontyDict([(MontyString('k'), MontyInt(1))]);
      const b = MontyDict([(MontyString('k'), MontyInt(2))]);
      expect(a, isNot(b));
    });

    test('toJson: compact shape for all-string keys', () {
      // Was: 'preserves the entry shape (no __type)', asserting {'k': 1}.
      // That shape IS core#136 — a bare object was byte-identical to a type
      // envelope, so a dict could name a host type.
      expect(
        const MontyDict([
          (MontyString('k'), MontyInt(1)),
          (MontyString('s'), MontyString('x')),
        ]).toJson(),
        {
          '__type': 'dict',
          'value': {'k': 1, 's': 'x'},
        },
      );
    });

    test('toJson: entries shape for non-string keys', () {
      expect(const MontyDict([(MontyInt(1), MontyString('a'))]).toJson(), {
        '__type': 'dict',
        'entries': [
          [1, 'a'],
        ],
      });
    });

    test('dartValue is a Map for string keys, pairs otherwise', () {
      // Conditional on key type by design -- see the dartValue doc comment.
      expect(
        const MontyDict([
          (MontyString('a'), MontyInt(1)),
          (MontyString('b'), MontyString('x')),
        ]).dartValue,
        {'a': 1, 'b': 'x'},
      );
      expect(
        const MontyDict([(MontyInt(1), MontyString('x'))]).dartValue,
        [
          [1, 'x'],
        ],
      );
    });
  });

  group('MontySet', () {
    test(
      // TITLE CORRECTED. It read 'treated as ordered list under deep equality',
      // which 17b175f made the OPPOSITE of the truth: MontySet compares
      // order-INSENSITIVELY now, matching the sandbox. The body never
      // exercised order either way -- both operands are in the same order --
      // so nothing failed when the implementation was inverted underneath it.
      // The order property itself lives in monty_set_order_equality_test.dart.
      'equal sets with identical contents compare and hash equally',
      () {
        const a = MontySet([MontyInt(1), MontyInt(2)]);
        const b = MontySet([MontyInt(1), MontyInt(2)]);
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      },
    );

    test('toJson includes __type', () {
      expect(
        const MontySet([MontyInt(1)]).toJson(),
        {
          '__type': 'set',
          'value': [1],
        },
      );
    });

    test('equal to a MontyFrozenSet with the same items', () {
      const s = MontySet([MontyInt(1)]);
      const fs = MontyFrozenSet([MontyInt(1)]);
      expect(s, fs);
      expect(fs, s);
      expect(s.hashCode, fs.hashCode);
      expect(s, isNot(const MontyFrozenSet([MontyInt(2)])));
    });
  });

  group('MontyFrozenSet', () {
    test('equality + hashCode', () {
      const a = MontyFrozenSet([MontyInt(1), MontyInt(2)]);
      const b = MontyFrozenSet([MontyInt(1), MontyInt(2)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  // ------------------------------------------------------------------
  // DateTime types
  // ------------------------------------------------------------------

  group('MontyDate', () {
    test('equality + hashCode', () {
      const a = MontyDate(year: 2026, month: 4, day: 28);
      const b = MontyDate(year: 2026, month: 4, day: 28);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different field is not equal', () {
      expect(
        const MontyDate(year: 2026, month: 4, day: 28),
        isNot(const MontyDate(year: 2026, month: 4, day: 27)),
      );
    });

    test('dartValue is a Dart DateTime at midnight', () {
      const d = MontyDate(year: 2026, month: 4, day: 28);
      expect(d.dartValue, DateTime(2026, 4, 28));
    });

    test('toString pads month and day', () {
      expect(
        const MontyDate(year: 2026, month: 1, day: 5).toString(),
        'MontyDate(2026-01-05)',
      );
    });
  });

  group('MontyDateTime', () {
    test('equality + hashCode (naive)', () {
      const a = MontyDateTime(
        year: 2026,
        month: 4,
        day: 28,
        hour: 15,
        minute: 30,
        second: 45,
      );
      const b = MontyDateTime(
        year: 2026,
        month: 4,
        day: 28,
        hour: 15,
        minute: 30,
        second: 45,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('tz-aware: offsetSeconds + name participate in equality', () {
      const naive = MontyDateTime(
        year: 2026,
        month: 4,
        day: 28,
        hour: 15,
        minute: 30,
        second: 45,
      );
      const aware = MontyDateTime(
        year: 2026,
        month: 4,
        day: 28,
        hour: 15,
        minute: 30,
        second: 45,
        offsetSeconds: 0,
        timezoneName: 'UTC',
      );
      expect(naive, isNot(aware));
    });
  });

  group('MontyTimeDelta', () {
    test('equality + hashCode', () {
      const a = MontyTimeDelta(days: 1, seconds: 3600, microseconds: 500);
      const b = MontyTimeDelta(days: 1, seconds: 3600, microseconds: 500);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('dartValue is a Duration', () {
      expect(
        const MontyTimeDelta(days: 1, seconds: 3600).dartValue,
        const Duration(days: 1, seconds: 3600),
      );
    });
  });

  group('MontyTimeZone', () {
    test('equality + hashCode (named)', () {
      const a = MontyTimeZone(offsetSeconds: -28800, name: 'PST');
      const b = MontyTimeZone(offsetSeconds: -28800, name: 'PST');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different offsets are not equal', () {
      expect(
        const MontyTimeZone(offsetSeconds: 0, name: 'UTC'),
        isNot(const MontyTimeZone(offsetSeconds: 3600, name: 'UTC')),
      );
    });
  });

  // ------------------------------------------------------------------
  // Structured types
  // ------------------------------------------------------------------

  group('MontyPath', () {
    test('equality + hashCode', () {
      final a = MontyPath('/data/hello.txt');
      final b = MontyPath('/data/hello.txt');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('dartValue is the path string', () {
      expect(MontyPath('/etc').dartValue, '/etc');
    });

    test('different paths are not equal', () {
      expect(MontyPath('/a'), isNot(MontyPath('/b')));
    });
  });

  group('MontyNamedTuple', () {
    test('equality + hashCode (typeName + fields + values)', () {
      const a = MontyNamedTuple(
        typeName: 'sys.version_info',
        fieldNames: ['major', 'minor', 'micro'],
        values: [MontyInt(3), MontyInt(14), MontyInt(0)],
      );
      const b = MontyNamedTuple(
        typeName: 'sys.version_info',
        fieldNames: ['major', 'minor', 'micro'],
        values: [MontyInt(3), MontyInt(14), MontyInt(0)],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different names are equal, as Python compares a tuple', () {
      const a = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      );
      const b = MontyNamedTuple(
        typeName: 'Vec',
        fieldNames: ['u', 'v'],
        values: [MontyInt(1), MontyInt(2)],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, const MontyTuple([MontyInt(1), MontyInt(2)]));
      expect(a.hashCode, const MontyTuple([MontyInt(1), MontyInt(2)]).hashCode);
    });

    test('different field values are not equal', () {
      const a = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      );
      const b = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(3)],
      );
      expect(a, isNot(b));
    });

    test('dartValue exposes the toJson map', () {
      const nt = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      expect(nt.dartValue, nt.toJson());
    });
  });

  // ------------------------------------------------------------------
  // MontyValue.fromDart
  // ------------------------------------------------------------------

  group('MontyValue.fromDart', () {
    test('passes MontyValue instances through', () {
      const v = MontyInt(42);
      expect(MontyValue.fromDart(v), same(v));
    });

    test('null / bool / int / double / String → matching scalar', () {
      expect(MontyValue.fromDart(null), const MontyNone());
      expect(MontyValue.fromDart(true), const MontyBool(true));
      expect(MontyValue.fromDart(42), const MontyInt(42));
      expect(MontyValue.fromDart(3.14), const MontyFloat(3.14));
      expect(MontyValue.fromDart('hi'), const MontyString('hi'));
    });

    test('Dart DateTime → MontyDateTime in UTC', () {
      final dt = DateTime.utc(2026, 4, 28, 15, 30, 45, 0, 123);
      final got = MontyValue.fromDart(dt);
      expect(got, isA<MontyDateTime>());
      final mdt = got as MontyDateTime;
      expect(mdt.year, 2026);
      expect(mdt.month, 4);
      expect(mdt.day, 28);
      expect(mdt.hour, 15);
      expect(mdt.minute, 30);
      expect(mdt.second, 45);
      expect(mdt.microsecond, 123);
    });

    test('a Uint8List becomes MontyBytes, not a list of ints', () {
      final got = MontyValue.fromDart(Uint8List.fromList([0, 1, 255]));
      expect(got, isA<MontyBytes>());
      expect((got as MontyBytes).value, [0, 1, 255]);
    });

    test('a Uint8List inside a list or dict becomes MontyBytes', () {
      final got = MontyValue.fromDart({
        'a': [
          Uint8List.fromList([1]),
        ],
      });
      expect(
        got,
        MontyDict([
          (
            const MontyString('a'),
            MontyList([
              MontyBytes(Uint8List.fromList([1])),
            ]),
          ),
        ]),
      );
    });

    test('the converted bytes do not alias the Uint8List', () {
      final src = Uint8List.fromList([1, 2]);
      final got = MontyValue.fromDart(src) as MontyBytes;
      src[0] = 9;
      expect(got.value, [1, 2]);
    });

    // The tagged map a wrapper's dartValue returns is transport shape. Fed
    // back it would reach the sandbox as a plain dict carrying the tag keys,
    // so it is refused and the typed value is passed instead.
    final classType = montyClassTypeProxy(
      name: 'Remote',
      id: '0123abcd-0000-4000-8000-00000000cafe',
      hostDefined: true,
      isDataclass: false,
      attrs: const {'source': MontyString('host')},
    );
    final classInstance = montyClassProxy(
      classType: classType,
      instanceId: 'fedcba98-7654-4000-8000-00000000face',
      attrs: const {'value': MontyInt(7)},
    );
    for (final (name, MontyValue value, tag) in [
      (
        'MontyNamedTuple',
        const MontyNamedTuple(
          typeName: 'N',
          fieldNames: ['a'],
          values: [MontyInt(1)],
        ),
        'namedtuple',
      ),
      (
        'MontyTimeZone',
        const MontyTimeZone(offsetSeconds: 7200, name: 'X'),
        'timezone',
      ),
      ('MontyComplex', const MontyComplex(1, 2), 'complex'),
      ('MontyFileHandle', MontyFileHandle('/f', 'r'), 'filehandle'),
      (
        'MontyExceptionValue',
        MontyExceptionValue('ValueError', 'bad'),
        'exception',
      ),
      ('MontyClassTypeProxy', classType, 'class_type'),
      ('MontyClassProxy', classInstance, 'class_instance'),
    ]) {
      test('the dartValue map of $name is refused', () {
        final map = value.dartValue;
        expect(map, isA<Map<String, Object?>>());
        expect(
          () => MontyValue.fromDart(map),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(contains('pass the MontyValue'), contains(tag)),
            ),
          ),
        );
        expect(MontyValue.fromDart(value), same(value));
      });

      test('the toJson map of $name is unmarked and converts to a dict', () {
        expect(MontyValue.fromDart(value.toJson()), isA<MontyDict>());
      });

      test('a copy of the dartValue map of $name is a plain dict', () {
        final copy = switch (value.dartValue) {
          final Map<String, Object?> m => Map<String, Object?>.of(m),
          final other => throw StateError('not a map: $other'),
        };
        if (value is MontyClassProxy) {
          // The caller-built outer map must also contain a caller-built copy
          // of the nested class type map.
          copy['class_type'] = Map<String, Object?>.of(
            copy['class_type']! as Map<String, Object?>,
          );
        }
        expect(MontyValue.fromDart(copy), isA<MontyDict>());
      });
    }

    test('a class instance map is refused by its own mark', () {
      final map = classInstance.dartValue;
      map['class_type'] = Map<String, Object?>.of(
        map['class_type']! as Map<String, Object?>,
      );
      expect(
        () => MontyValue.fromDart(map),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('class_instance'),
          ),
        ),
      );
    });

    test('a dartValue map nested in a list is refused', () {
      expect(
        () => MontyValue.fromDart([const MontyComplex(1, 2).dartValue]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('complex'),
          ),
        ),
      );
    });

    test('a typed value nested in a collection dartValue is refused', () {
      for (final v in const <MontyValue>[
        MontyList([MontyComplex(1, 2)]),
        MontyDict([
          (MontyString('k'), MontyTimeZone(offsetSeconds: 60, name: 'x')),
        ]),
      ]) {
        expect(
          () => MontyValue.fromDart(v.dartValue),
          throwsA(isA<ArgumentError>()),
        );
      }
    });

    test('a copy nested in a list is a dict', () {
      final copy = Map<String, Object?>.of(
        const MontyComplex(1, 2).dartValue,
      );
      final converted = MontyValue.fromDart([copy]);
      expect(converted, isA<MontyList>());
      expect((converted as MontyList).items, [isA<MontyDict>()]);
    });

    test('caller-built maps with wrapper keys are still dicts', () {
      final mine = MontyValue.fromDart({'__type': 'mine', 'x': 1});
      final complex = MontyValue.fromDart({
        '__type': 'complex',
        'real': 1.0,
        'imag': 2.0,
      });
      final namedTuple = MontyValue.fromDart({
        '__type': 'namedtuple',
        'type_name': 'N',
        'field_names': ['a'],
        'values': [1],
      });
      expect([mine, complex, namedTuple], everyElement(isA<MontyDict>()));
    });

    test('Dart List → MontyList with recursive conversion', () {
      final got = MontyValue.fromDart([1, 'x', true]);
      expect(
        got,
        const MontyList([MontyInt(1), MontyString('x'), MontyBool(true)]),
      );
    });

    test('Dart Map → MontyDict, keys and values both converted', () {
      final got = MontyValue.fromDart({'k': 1, 'n': null});
      expect(
        got,
        const MontyDict([
          (MontyString('k'), MontyInt(1)),
          (MontyString('n'), MontyNone()),
        ]),
      );
    });

    test('Map with non-String keys keeps the key TYPE', () {
      // INVERTED. This used to assert the keys came back as the STRINGS '1'
      // and '2', because fromDart forced every key through `k.toString()`.
      // That silently turned the Dart map {1: 'one'} into the Python dict
      // {'1': 'one'} — a different dict, with no error. Only string keys were
      // expressible then; pairs carry any key monty accepts.
      final got = MontyValue.fromDart({1: 'one', 2: 'two'});
      expect(
        got,
        const MontyDict([
          (MontyInt(1), MontyString('one')),
          (MontyInt(2), MontyString('two')),
        ]),
      );
    });

    test('throws for unsupported runtime types', () {
      expect(
        () => MontyValue.fromDart(Object()),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ------------------------------------------------------------------
  // Cross-type checks
  // ------------------------------------------------------------------

  group('cross-type', () {
    test('distinct subtypes compare equal only where Python says so', () {
      // Smoke check on a representative sample. Python's equal pairs across
      // classes are the numeric tower (`0 == 0.0`), set == frozenset and
      // tuple == named tuple; the others, here, never compare equal.
      final samples = <MontyValue>[
        const MontyNone(),
        const MontyBool(true),
        const MontyInt(0),
        const MontyFloat(0.5),
        const MontyString(''),
        const MontyBytes([]),
        const MontyList([]),
        const MontyTuple([]),
        const MontyDict([]),
        const MontySet([]),
        const MontyDate(year: 1, month: 1, day: 1),
        const MontyTimeDelta(days: 0, seconds: 0),
        const MontyTimeZone(offsetSeconds: 0),
        MontyPath(''),
      ];
      for (var i = 0; i < samples.length; i++) {
        for (var j = 0; j < samples.length; j++) {
          if (i == j) continue;
          expect(
            samples[i] == samples[j],
            isFalse,
            reason:
                '${samples[i].runtimeType} should not equal '
                '${samples[j].runtimeType}',
          );
        }
      }
    });
  });

  test(
    'ExternalModule copies attributes and validates names identity and stubs',
    () {
      // Upstream: monty-python tests/test_external_modules.py
      // (test_invalid_modules_are_rejected_at_construction,
      // test_the_module_object_is_frozen and test_attrs_are_copied_at_
      // construction) and monty-proto src/python/external_module.rs
      // (PyExternalModule::new).

      // attrs are copied once, at construction, shallowly: the values are
      // the very objects given, and neither side's later edits cross.
      final given = _tools();
      final expected = _tools();
      final module = ExternalModule(given, stubs: _addStub);
      given['VERSION'] = 99;
      given['extra'] = 'later';
      expect(module.attrs, expected);
      expect(module.attrs['add'], same(_add));
      module.attrs['VERSION'] = 1;
      expect(module.attrs['VERSION'], 3);
      final nested = <String, Object?>{'inner': 1};
      final holder = ExternalModule({'nested': nested});
      expect(holder.attrs['nested'], same(nested));

      // a name starting with '_' is protected: the sandbox never sees it.
      expect(
        module.publicAttrs,
        {'add': _add, 'concat': _concat, 'VERSION': 3},
      );
      expect(module.publicAttrs.keys, ['add', 'concat', 'VERSION']);

      // stubs are optional.
      final bare = ExternalModule({'add': _add});
      expect(bare.stubs, isNull);
      expect(module.stubs, _addStub);

      // a fresh id is a uuid4 (version digit 4, variant 8-b) and each
      // module gets its own; a given one is used, canonical whatever its
      // case, and a non-uuid is refused.
      final looksLikeUuid4 = matches(_uuid4);
      final fresh = ExternalModule({'VERSION': 1});
      final otherFresh = ExternalModule({'VERSION': 2});
      expect(fresh.id, looksLikeUuid4);
      expect(otherFresh.id, looksLikeUuid4);
      expect(fresh.id, isNot(otherFresh.id));
      const suppliedId = '0A1B2C3D-4E5F-4A6B-8C9D-0E1F2A3B4C5D';
      final supplied = ExternalModule({'VERSION': 3}, id: suppliedId);
      expect(supplied.id, suppliedId.toLowerCase());
      final argError = isA<ArgumentError>();
      expect(
        () => ExternalModule({'VERSION': 4}, id: 'not-a-uuid'),
        throwsA(
          argError.having((e) => e.message, 'message', contains('uuid')),
        ),
      );

      // equal when id, attrs and stubs all match, and only then.
      const uid = '9e107669-c31b-4d0f-8b76-2f0e2a4b5a03';
      final baseTools = _tools();
      final twinTools = _tools();
      final base = ExternalModule(baseTools, stubs: _addStub, id: uid);
      final twin = ExternalModule(twinTools, stubs: _addStub, id: uid);
      expect(base, twin);
      expect(base.hashCode, twin.hashCode);
      // a fresh id differs.
      final differentIdTools = _tools();
      final differentId = ExternalModule(differentIdTools, stubs: _addStub);
      expect(base, isNot(differentId));
      // stubs null differs from stubs given.
      final noStubsTools = _tools();
      final noStubs = ExternalModule(noStubsTools, id: uid);
      expect(base, isNot(noStubs));
      // the same keys, id and stubs, one VALUE changed.
      final changedTools = _tools();
      final changedValue = ExternalModule(
        {...changedTools, 'VERSION': 4},
        stubs: _addStub,
        id: uid,
      );
      expect(base, isNot(changedValue));
      // one key dropped.
      final dropped = ExternalModule(
        {'add': _add, 'concat': _concat, 'VERSION': 3},
        stubs: _addStub,
        id: uid,
      );
      expect(base, isNot(dropped));

      // keys are checked eagerly, at construction (see
      // _rejectsInvalidModules): strings only, identifiers, keywords
      // included, and no nested module under a sandbox name.
      _rejectsInvalidModules();
      final subTools = _tools();
      final sub = ExternalModule(subTools);
      expect(() => ExternalModule({'sub': sub}), returnsNormally);

      // ordinary values are converted when read, not at construction.
      expect(module.attrValue('VERSION'), const MontyInt(3));
      expect(module.attrValue('_secret'), isNull);
      expect(module.attrValue('missing'), isNull);
      expect(ExternalModule({'pkg': sub}).attrValue('pkg'), same(sub));
      final odd = Object();
      final unconvertible = ExternalModule({'odd': odd});
      expect(unconvertible.attrs['odd'], same(odd));
      expect(
        () => unconvertible.attrValue('odd'),
        throwsA(
          argError.having(
            (e) => e.message,
            'message',
            contains('Cannot convert'),
          ),
        ),
      );

      // the module's own rules, pinned here.
      _moduleIdRules();
      _moduleNameRules();
      _moduleAttributeRules();
      _moduleEqualityRules();
      _moduleHashRules();
      _moduleTextRules();
    },
  );
}

// ---------------------------------------------------------------------------
// ExternalModule: the rules the module model pins
// ---------------------------------------------------------------------------

/// A map that holds one key twice, as a Python `str` subclass can: the
/// duplicate check must see the second spelling of the name.
class _RepeatedKeyMap extends MapBase<String, Object?> {
  const _RepeatedKeyMap(this._entries);

  final List<MapEntry<String, Object?>> _entries;

  @override
  Iterable<MapEntry<String, Object?>> get entries => _entries;

  @override
  Iterable<String> get keys => _entries.map((entry) => entry.key);

  @override
  Object? operator [](Object? key) {
    for (final entry in _entries) {
      if (entry.key == key) return entry.value;
    }

    return null;
  }

  @override
  void operator []=(String key, Object? value) {
    throw UnimplementedError('the fixture is read only');
  }

  @override
  Object? remove(Object? key) {
    throw UnimplementedError('the fixture is read only');
  }

  @override
  void clear() {
    throw UnimplementedError('the fixture is read only');
  }
}

/// A value with an equality of its own: a module compares it as that value
/// says, never as a structure.
@immutable
class _EqualValue {
  const _EqualValue(this.tag);

  /// What the two instances a test compares share.
  final int tag;

  @override
  bool operator ==(Object other) => other is _EqualValue && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;

  @override
  String toString() => '_EqualValue($tag)';
}

/// An iterable that is equal to any other one, and that must not be walked
/// to be compared: asking for its iterator fails.
@immutable
class _EqualIterable extends Iterable<Object?> {
  const _EqualIterable(this.tag);

  /// What the two instances a test compares share.
  final int tag;

  @override
  Iterator<Object?> get iterator =>
      throw StateError('the iterator must not be requested');

  @override
  bool operator ==(Object other) => other is _EqualIterable && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;

  @override
  String toString() => '_EqualIterable($tag)';
}

/// A value whose hash fails: a module never hashes its values.
@immutable
class _ThrowingHash {
  const _ThrowingHash();

  @override
  int get hashCode => throw StateError('the hash must not be read');

  @override
  bool operator ==(Object other) => identical(this, other);
}

/// A value whose equality fails: a module is still equal to itself.
@immutable
class _ThrowingEquality {
  const _ThrowingEquality();

  @override
  bool operator ==(Object other) =>
      throw StateError('the equality must not be read');

  @override
  int get hashCode => 1;
}

/// A value whose text fails: a module never formats its values.
@immutable
class _ThrowingText {
  const _ThrowingText();

  @override
  String toString() => throw StateError('the text must not be read');

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => 1;
}

/// The two characters Python's `repr` writes for a newline.
const _newline = r'\n';

/// A tag the two instances of a fixture share.
///
/// A call, not a literal: the two instances must be distinct objects, and a
/// literal would make them one.
int _runtimeTag() => 1;

/// A module's identity: an omitted id is a fresh uuid4, a given one is
/// canonical whatever its case, and an invalid one is refused before the
/// attributes are looked at.
void _moduleIdRules() {
  final looksLikeUuid4 = matches(_uuid4);
  final fresh = ExternalModule({'VERSION': 1});
  final other = ExternalModule({'VERSION': 1});
  expect(fresh.id, looksLikeUuid4);
  expect(other.id, looksLikeUuid4);
  expect(fresh.id, isNot(other.id));

  const supplied = '0A1B2C3D-4E5F-4A6B-8C9D-0E1F2A3B4C5D';
  expect(
    ExternalModule({'VERSION': 1}, id: supplied).id,
    supplied.toLowerCase(),
  );

  final notAUuid = throwsA(
    isA<ArgumentError>().having(
      (e) => e.message,
      'message',
      contains('not a uuid'),
    ),
  );
  expect(() => ExternalModule({'VERSION': 1}, id: 'not-a-uuid'), notAUuid);

  // The id is checked before the attributes, so an invalid id is reported
  // even when the attributes are invalid too.
  expect(() => ExternalModule({1: 1}, id: 'not-a-uuid'), notAUuid);

  // The stubs are none, empty and arbitrary text: three different modules,
  // each keeping its own text.
  final none = ExternalModule({'VERSION': 1});
  final empty = ExternalModule({'VERSION': 1}, stubs: '');
  final text = ExternalModule({'VERSION': 1}, stubs: 'def f() -> int: ...\n');
  expect(none.stubs, isNull);
  expect(empty.stubs, '');
  expect(text.stubs, 'def f() -> int: ...\n');
  expect(none == empty, isFalse);
  expect(empty == none, isFalse);
  expect(empty == text, isFalse);
  expect(text == empty, isFalse);
}

/// The names a host module may not take: an invalid one first, then one the
/// sandbox provides itself.
void _moduleNameRules() {
  // A keyword is an identifier, but not a valid one.
  expect(isIdentifier('class'), isTrue);
  expect(isValidIdentifier('class'), isFalse);
  expect(isValidIdentifier('tools'), isTrue);

  // The sandbox's own module names, listed here apart from the rule's own
  // list.
  const reserved = {
    'asyncio',
    'base64',
    'binascii',
    'bisect',
    'collections',
    'copy',
    'csv',
    'dataclasses',
    'datetime',
    'functools',
    'gc',
    'hashlib',
    'itertools',
    'json',
    'math',
    'os',
    'pathlib',
    'posixpath',
    'random',
    're',
    'sys',
    'time',
    'tomllib',
    'typing',
    'unicodedata',
  };
  expect(reserved, hasLength(25));
  expect(sandboxModuleNames, reserved);
  for (final name in reserved) {
    final error = moduleNameError(name);
    expect(error, isNotNull, reason: name);
    expect(error, contains('cannot be replaced'), reason: name);
  }

  // An invalid name is reported before a reserved one.
  expect(
    moduleNameError('a.b'),
    'module name "a.b" is not a valid identifier',
  );
  expect(
    moduleNameError('for'),
    'module name "for" is not a valid identifier',
  );
  expect(
    moduleNameError('os.path'),
    'module name "os.path" is not a valid identifier',
  );

  // The name is escaped as Rust escapes it.
  expect(
    moduleNameError('a"b'),
    r'module name "a\"b" is not a valid identifier',
  );
  expect(
    moduleNameError('a\nb'),
    r'module name "a\nb" is not a valid identifier',
  );

  // A name only the type checker uses may still name a host module.
  expect(moduleNameError('abc'), isNull);
  expect(moduleNameError('__future__'), isNull);
  expect(moduleNameError('tools'), isNull);
}

/// The attributes a module holds: the checks at construction, the copies the
/// getters hand out and the conversion when one is read.
void _moduleAttributeRules() {
  final argError = isA<ArgumentError>();

  // A key that is not a string.
  expect(
    () => ExternalModule({1: _add}),
    throwsA(
      argError.having(
        (e) => e.message,
        'message',
        'ExternalModule attrs must have str keys, not int',
      ),
    ),
  );

  // A key that is not an identifier: empty, dotted, digit-leading and a
  // hard keyword.
  const invalidKeys = {
    '': "''",
    'a.b': "'a.b'",
    '1sub': "'1sub'",
    'for': "'for'",
  };
  for (final invalid in invalidKeys.entries) {
    expect(
      () => ExternalModule({invalid.key: _add}),
      throwsA(
        argError.having(
          (e) => e.message,
          'message',
          'ExternalModule attrs must have identifier keys, '
              'not ${invalid.value}',
        ),
      ),
      reason: invalid.key,
    );
  }

  // A key seen twice: the map holds two spellings of one name.
  const twice = _RepeatedKeyMap([
    MapEntry('add', 1),
    MapEntry('add', 2),
  ]);
  expect(twice.entries.length, 2);
  expect(
    () => ExternalModule(twice),
    throwsA(
      argError.having(
        (e) => e.message,
        'message',
        "ExternalModule attrs has the key 'add' twice",
      ),
    ),
  );

  // The duplicate wins over the reserved name: the second 'os' entry holds
  // a module, which would be refused under that name on its own.
  final reservedTwice = _RepeatedKeyMap([
    const MapEntry('os', 1),
    MapEntry('os', ExternalModule({'VERSION': 1})),
  ]);
  expect(reservedTwice.entries.length, 2);
  expect(
    () => ExternalModule(reservedTwice),
    throwsA(
      argError.having(
        (e) => e.message,
        'message',
        "ExternalModule attrs has the key 'os' twice",
      ),
    ),
  );

  // A nested module under a name the sandbox provides itself.
  expect(
    () => ExternalModule({
      'os': ExternalModule({'VERSION': 1}),
    }),
    throwsA(
      argError.having(
        (e) => e.message,
        'message',
        'ExternalModule attrs[\'os\']: module "os" is provided by the '
            'sandbox or its type checker and cannot be replaced',
      ),
    ),
  );

  // Names that are accepted: a Unicode identifier, a protected one, the
  // soft keywords, and a name only the type checker uses.
  expect(
    () => ExternalModule({
      'café': 1,
      '_secret': 2,
      'match': 3,
      'type': 4,
    }),
    returnsNormally,
  );

  // An ordinary value under a reserved name is fine: only a nested module
  // is imported by its name.
  expect(() => ExternalModule({'os': 1, 'json': 'text'}), returnsNormally);

  // A nested module under a name only the type checker uses.
  expect(
    () => ExternalModule({
      'abc': ExternalModule({'VERSION': 1}),
    }),
    returnsNormally,
  );

  // The copies the getters hand out are fresh and mutable, and the module
  // itself does not change.
  final given = <String, Object?>{'a': 1, '_b': 2};
  final module = ExternalModule(given);
  given['a'] = 99;
  given['c'] = 3;
  expect(module.attrs, {'a': 1, '_b': 2});

  final firstAttrs = module.attrs;
  final secondAttrs = module.attrs;
  expect(identical(firstAttrs, secondAttrs), isFalse);
  firstAttrs['a'] = 100;
  expect(module.attrs['a'], 1);
  expect(secondAttrs['a'], 1);

  final firstPublic = module.publicAttrs;
  final secondPublic = module.publicAttrs;
  expect(identical(firstPublic, secondPublic), isFalse);
  firstPublic['a'] = 100;
  expect(module.publicAttrs['a'], 1);
  expect(secondPublic['a'], 1);
  expect(module.publicAttrs, {'a': 1});

  // The public attributes keep the insertion order and drop the protected
  // ones.
  final ordered = ExternalModule({'z': 1, 'a': 2, '_m': 3});
  expect(ordered.publicAttrs.keys, ['z', 'a']);
  expect(ordered.attrs.keys, ['z', 'a', '_m']);

  // The copies are shallow: the values are the very objects given.
  final nested = <String, Object?>{'inner': 1};
  final holder = ExternalModule({'nested': nested});
  expect(holder.attrs['nested'], same(nested));
  nested['inner'] = 2;
  expect(holder.attrs['nested'], same(nested));
  expect(
    (holder.attrs['nested']! as Map<String, Object?>)['inner'],
    2,
  );

  // A value is read as the sandbox sees it.
  expect(module.attrValue('missing'), isNull);
  expect(module.attrValue('_b'), isNull);
  expect(ExternalModule({'x': null}).attrValue('x'), const MontyNone());
  expect(ExternalModule({'n': 3}).attrValue('n'), const MontyInt(3));

  // A nested module is the module itself.
  final sub = ExternalModule({'VERSION': 1});
  expect(ExternalModule({'pkg': sub}).attrValue('pkg'), same(sub));

  // A value the sandbox cannot hold is accepted at construction and fails
  // only when it is read.
  final odd = Object();
  final unconvertible = ExternalModule({'odd': odd});
  expect(unconvertible.attrs['odd'], same(odd));
  expect(
    () => unconvertible.attrValue('odd'),
    throwsA(
      argError.having(
        (e) => e.message,
        'message',
        contains('Cannot convert'),
      ),
    ),
  );
}

/// Two modules are equal when their ids, stubs and attributes match; every
/// attribute value is compared as Python compares the values of two dicts.
void _moduleEqualityRules() {
  const uid = '9e107669-c31b-4d0f-8b76-2f0e2a4b5a03';

  // The same attributes, the same id and the same stubs.
  final base = ExternalModule(
    {
      'add': _add,
      'VERSION': 3,
    },
    stubs: _addStub,
    id: uid,
  );
  final twin = ExternalModule(
    {
      'add': _add,
      'VERSION': 3,
    },
    stubs: _addStub,
    id: uid,
  );
  expect(base == twin, isTrue);
  expect(twin == base, isTrue);

  // The attributes in another order are the same attributes.
  final reordered = ExternalModule(
    {
      'VERSION': 3,
      'add': _add,
    },
    stubs: _addStub,
    id: uid,
  );
  expect(base == reordered, isTrue);
  expect(reordered == base, isTrue);

  // Another id, another stub.
  final otherId = ExternalModule({
    'add': _add,
    'VERSION': 3,
  }, stubs: _addStub);
  expect(base == otherId, isFalse);
  expect(otherId == base, isFalse);
  final otherStubs = ExternalModule(
    {
      'add': _add,
      'VERSION': 3,
    },
    stubs: '',
    id: uid,
  );
  expect(base == otherStubs, isFalse);
  expect(otherStubs == base, isFalse);

  // A changed value, a missing key, an added key.
  final changed = ExternalModule(
    {
      'add': _add,
      'VERSION': 4,
    },
    stubs: _addStub,
    id: uid,
  );
  expect(base == changed, isFalse);
  expect(changed == base, isFalse);
  final dropped = ExternalModule({'add': _add}, stubs: _addStub, id: uid);
  expect(base == dropped, isFalse);
  expect(dropped == base, isFalse);
  final added = ExternalModule(
    {
      'add': _add,
      'VERSION': 3,
      'x': 1,
    },
    stubs: _addStub,
    id: uid,
  );
  expect(base == added, isFalse);
  expect(added == base, isFalse);

  // A protected key counts as well.
  final protectedBase = ExternalModule({'_p': 1}, id: uid);
  final protectedChanged = ExternalModule({'_p': 2}, id: uid);
  final protectedDropped = ExternalModule({}, id: uid);
  expect(protectedBase == protectedChanged, isFalse);
  expect(protectedChanged == protectedBase, isFalse);
  expect(protectedBase == protectedDropped, isFalse);
  expect(protectedDropped == protectedBase, isFalse);

  // A null value is compared like any other: a matching null does not end
  // the comparison.
  final nulls = ExternalModule({'a': null, 'b': 1}, id: uid);
  final nullsOther = ExternalModule({'a': null, 'b': 2}, id: uid);
  final nullsRenamed = ExternalModule({'a': null, 'c': 1}, id: uid);
  final nullsSame = ExternalModule({'b': 1, 'a': null}, id: uid);
  expect(nulls == nullsOther, isFalse);
  expect(nullsOther == nulls, isFalse);
  expect(nulls == nullsRenamed, isFalse);
  expect(nullsRenamed == nulls, isFalse);
  expect(nulls == nullsSame, isTrue);
  expect(nullsSame == nulls, isTrue);

  // A list or a map attribute is compared structurally: an attribute with
  // the same contents matches another one, not only the very same object.
  final list = <Object?>[1, 2];
  final map = <String, Object?>{'a': 1};
  final holdsList = ExternalModule({'x': list}, id: uid);
  final holdsSameList = ExternalModule({'x': list}, id: uid);
  final holdsOtherList = ExternalModule({
    'x': <Object?>[1, 2],
  }, id: uid);
  expect(identical(list, <Object?>[1, 2]), isFalse);
  expect(holdsList == holdsSameList, isTrue);
  expect(holdsSameList == holdsList, isTrue);
  expect(holdsList == holdsOtherList, isTrue);
  expect(holdsOtherList == holdsList, isTrue);

  final holdsMap = ExternalModule({'x': map}, id: uid);
  final holdsSameMap = ExternalModule({'x': map}, id: uid);
  final holdsOtherMap = ExternalModule({
    'x': <String, Object?>{'a': 1},
  }, id: uid);
  expect(identical(map, <String, Object?>{'a': 1}), isFalse);
  expect(holdsMap == holdsSameMap, isTrue);
  expect(holdsSameMap == holdsMap, isTrue);
  expect(holdsMap == holdsOtherMap, isTrue);
  expect(holdsOtherMap == holdsMap, isTrue);

  // A list attribute with other contents does not match.
  final holdsChangedList = ExternalModule({
    'x': <Object?>[2, 1],
  }, id: uid);
  expect(holdsList == holdsChangedList, isFalse);
  expect(holdsChangedList == holdsList, isFalse);

  // A value with an equality of its own decides, as that value says. The
  // two instances are distinct, and their own equality says they match.
  final tag = _runtimeTag();
  final one = _EqualValue(tag);
  final two = _EqualValue(tag);
  expect(identical(one, two), isFalse);
  final holdsOne = ExternalModule({'x': one}, id: uid);
  final holdsTwo = ExternalModule({'x': two}, id: uid);
  expect(holdsOne == holdsTwo, isTrue);
  expect(holdsTwo == holdsOne, isTrue);

  // An iterable is not walked to be compared: its own equality says so.
  final holdsIterable = ExternalModule({'x': _EqualIterable(tag)}, id: uid);
  final holdsOtherIterable = ExternalModule({
    'x': _EqualIterable(tag),
  }, id: uid);
  expect(holdsIterable == holdsOtherIterable, isTrue);
  expect(holdsOtherIterable == holdsIterable, isTrue);

  // A nested module is compared by its own equality.
  final subOne = ExternalModule({'VERSION': 1}, id: uid);
  final subTwo = ExternalModule({'VERSION': 1}, id: uid);
  final subOther = ExternalModule({'VERSION': 2}, id: uid);
  final holdsSub = ExternalModule({'pkg': subOne}, id: uid);
  final holdsSameSub = ExternalModule({'pkg': subTwo}, id: uid);
  final holdsOtherSub = ExternalModule({'pkg': subOther}, id: uid);
  expect(holdsSub == holdsSameSub, isTrue);
  expect(holdsSameSub == holdsSub, isTrue);
  expect(holdsSub == holdsOtherSub, isFalse);
  expect(holdsOtherSub == holdsSub, isFalse);

  // A module is not another object.
  expect(base == Object(), isFalse);
  expect(Object() == base, isFalse);

  // A module is equal to itself whatever its attributes hold: the
  // comparison never reaches the values.
  final nan = ExternalModule({'x': double.nan}, id: uid);
  expect(nan == nan, isTrue);
  final failing = ExternalModule({'x': const _ThrowingEquality()}, id: uid);
  expect(failing == failing, isTrue);
}

/// The hash of a module: the id, the stubs and the attribute names, never
/// the values.
void _moduleHashRules() {
  const uid = '9e107669-c31b-4d0f-8b76-2f0e2a4b5a03';

  final base = ExternalModule(
    {
      'a': 1,
      'b': 2,
    },
    stubs: _addStub,
    id: uid,
  );
  final reordered = ExternalModule(
    {
      'b': 2,
      'a': 1,
    },
    stubs: _addStub,
    id: uid,
  );
  expect(base == reordered, isTrue);
  expect(base.hashCode, reordered.hashCode);
  expect(
    base.hashCode,
    Object.hash(uid, _addStub, Object.hashAllUnordered(['a', 'b'])),
  );

  // Equal modules work as set members and as map keys.
  expect({base, reordered}.length, 1);
  expect({base, reordered}.contains(reordered), isTrue);
  expect({base: 'value'}[reordered], 'value');

  // The hash never reads a value, so a value whose hash fails is no
  // trouble.
  final failing = ExternalModule({'x': const _ThrowingHash()}, id: uid);
  expect(() => failing.hashCode, returnsNormally);
  expect(
    failing.hashCode,
    Object.hash(uid, null, Object.hashAllUnordered(['x'])),
  );

  // The values do not count: two modules that differ only in a value share
  // the hash.
  final changed = ExternalModule(
    {
      'a': 1,
      'b': 3,
    },
    stubs: _addStub,
    id: uid,
  );
  expect(changed.hashCode, base.hashCode);
}

/// The text of a module: the number of attributes, the stubs and the id.
void _moduleTextRules() {
  const uid = '9e107669-c31b-4d0f-8b76-2f0e2a4b5a03';

  expect(
    ExternalModule({'a': 1}, id: uid).toString(),
    "ExternalModule(1 attrs, stubs=None, id=UUID('$uid'))",
  );
  expect(
    ExternalModule({'a': 1, 'b': 2}, id: uid).toString(),
    "ExternalModule(2 attrs, stubs=None, id=UUID('$uid'))",
  );
  expect(
    ExternalModule({'a': 1}, stubs: '', id: uid).toString(),
    "ExternalModule(1 attrs, stubs='', id=UUID('$uid'))",
  );
  expect(
    ExternalModule(
      {
        'a': 1,
      },
      stubs: 'def add(a: int, b: int) -> int: ...\n',
      id: uid,
    ).toString(),
    "ExternalModule(1 attrs, stubs='def add(a: int, b: int) -> int: ..."
    "$_newline', id=UUID('$uid'))",
  );
  expect(
    ExternalModule({'a': 1}, stubs: "it's\n", id: uid).toString(),
    'ExternalModule(1 attrs, stubs="it\'s$_newline", id=UUID(\'$uid\'))',
  );

  // The text never reads a value, so a value whose text fails is no
  // trouble.
  final failing = ExternalModule({'x': const _ThrowingText()}, id: uid);
  expect(failing.toString, returnsNormally);
}
