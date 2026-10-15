// The value family at the cutover: the subtypes it gains (MontyComplex,
// MontyClassTypeProxy, ClassInstance, ClassType, MontyHostFunction, all
// declared in the value library) and the projections it changes
// (MontyDateTime.dartValue, SPEC2 Q48; fromDart(DateTime) with its offset;
// MontyTimeDelta.dartValue's refusal).
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show HostClass, MontyValueInternal, montyClassTypeProxy;
import 'package:test/test.dart';

/// An exhaustive switch over the family: it compiles only while every
/// subtype has an arm, so a subtype added or lost breaks it.
String kindOf(MontyValue v) => switch (v) {
  MontyNone() => 'none',
  MontyBool() => 'bool',
  MontyInt() => 'int',
  MontyBigInt() => 'bigint',
  MontyFloat() => 'float',
  MontyComplex() => 'complex',
  MontyString() => 'str',
  MontyBytes() => 'bytes',
  MontyList() => 'list',
  MontyTuple() => 'tuple',
  MontyDict() => 'dict',
  MontySet() => 'set',
  MontyFrozenSet() => 'frozenset',
  MontyDate() => 'date',
  MontyDateTime() => 'datetime',
  MontyTimeDelta() => 'timedelta',
  MontyTimeZone() => 'timezone',
  MontyTime() => 'time',
  MontyEllipsis() => 'ellipsis',
  MontyPath() => 'path',
  MontyFileHandle() => 'filehandle',
  MontyNamedTuple() => 'namedtuple',
  MontyNotImplemented() => 'notimplemented',
  MontyExceptionValue() => 'exception',
  MontyStdTypeProxy() => 'std_type_proxy',
  MontyClassProxy() => 'class_proxy',
  MontyClassTypeProxy() => 'class_type_proxy',
  ClassInstance() => 'class_instance',
  ClassType() => 'class_type',
  MontyHostFunction() => throw StateError(
    'unreachable: MontyHostFunction is input-only',
  ),
};

class _Point {
  const _Point(this.x);

  final int x;
}

void main() {
  group('the five subtypes the cutover adds', () {
    const pointClass = HostClass<_Point>('Point');
    final type = ClassType(pointClass);
    final instance = ClassInstance(const _Point(1), classType: type);
    final proxy = montyClassTypeProxy(
      name: 'K',
      id: '00000000-0000-4000-8000-000000000001',
      hostDefined: false,
      isDataclass: false,
      attrs: const {},
    );

    test('each is a MontyValue', () {
      expect(kindOf(const MontyComplex(0, 1)), 'complex');
      expect(kindOf(proxy), 'class_type_proxy');
      expect(kindOf(instance), 'class_instance');
      expect(kindOf(type), 'class_type');
      expect(
        () => kindOf(MontyHostFunction('f', (a, k) => const MontyNone())),
        throwsStateError,
      );
    });

    test('a wrapper projects to what it wraps and compares by identity', () {
      expect(instance.dartValue, isA<_Point>());
      expect(type.dartValue, same(pointClass));
      // HOST1 (b): identity, as upstream's dataclasses cannot be hashed.
      expect(instance, isNot(ClassInstance(instance.value, classType: type)));
      expect(type, isNot(ClassType(pointClass)));
      expect(MontyValue.fromDart(instance), same(instance));
      expect(instance.toJson(), {
        '__type': 'host_instance',
        'class': 'Point',
        'id': instance.id,
      });
      expect(type.toJson(), {
        '__type': 'host_class',
        'name': 'Point',
        'id': type.id,
      });
      expect(instance.toString(), 'ClassInstance(Point, id: ${instance.id})');
      expect(type.toString(), 'ClassType(Point, id: ${type.id})');
    });

    test('a host function is its name, its function and its docstring', () {
      MontyValue fn(List<MontyValue> args, Map<String, MontyValue> kwargs) =>
          args.firstOrNull ?? kwargs['x'] ?? const MontyNone();
      final f = MontyHostFunction('double_it', fn, docstring: 'Doubles.');
      expect(f.name, 'double_it');
      expect(f.docstring, 'Doubles.');
      expect(f.fn([const MontyInt(2)], const {}), const MontyInt(2));
      expect(f.dartValue, same(f.fn));
      expect(f, isNot(MontyHostFunction('double_it', fn)));
      expect(f.toString(), 'MontyHostFunction(double_it)');
      expect(f.toJson(), {
        '__type': 'function',
        'name': 'double_it',
        'docstring': 'Doubles.',
      });
    });
  });

  group('MontyDateTime.dartValue (SPEC2 Q48)', () {
    test('aware: a UTC DateTime at the same instant', () {
      const d = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 30,
        second: 0,
        microsecond: 7,
        offsetSeconds: 3600,
        timezoneName: 'CET',
      );
      final v = d.dartValue;
      expect(v.isUtc, isTrue);
      expect(v, DateTime.utc(2023, 12, 31, 23, 30, 0, 0, 7));
    });

    test('naive: a local DateTime from the fields', () {
      const d = MontyDateTime(
        year: 2024,
        month: 6,
        day: 1,
        hour: 12,
        minute: 0,
        second: 0,
        microsecond: 5,
      );
      expect(d.dartValue.isUtc, isFalse);
      expect(d.dartValue, DateTime(2024, 6, 1, 12, 0, 0, 0, 5));
    });
  });

  group('fromDart(DateTime) keeps the instant and the offset', () {
    test('a UTC DateTime is aware with offset zero', () {
      final v =
          MontyValue.fromDart(DateTime.utc(2024, 3, 4, 5, 6, 7, 8, 9))
              as MontyDateTime;
      expect(v.offsetSeconds, 0);
      expect(v.microsecond, 8009);
      expect(v.hour, 5);
      expect(v.dartValue, DateTime.utc(2024, 3, 4, 5, 6, 7, 8, 9));
    });

    test('a local DateTime carries its offset and round-trips', () {
      final local = DateTime(2024, 3, 4, 5, 6, 7, 8, 9);
      final v = MontyValue.fromDart(local) as MontyDateTime;
      expect(v.offsetSeconds, local.timeZoneOffset.inSeconds);
      expect(v.hour, 5);
      expect(v.dartValue.isAtSameMomentAs(local), isTrue);
    });
  });

  group('MontyTimeDelta.dartValue refuses what a Duration cannot hold', () {
    test('within range: the exact Duration', () {
      expect(
        const MontyTimeDelta(
          days: -1,
          seconds: 86399,
          microseconds: 1,
        ).dartValue,
        const Duration(microseconds: -999999),
      );
    });

    test('beyond: StateError, the value itself still usable', () {
      const max = MontyTimeDelta(
        days: 999999999,
        seconds: 86399,
        microseconds: 999999,
      );
      expect(() => max.dartValue, throwsStateError);
      expect(max.days, 999999999);
      // 2^53 microseconds, exactly representable everywhere; 2^53 + 1 is
      // not a double, so dart2js refuses it.
      const two53 = MontyTimeDelta(
        days: 104249,
        seconds: 85654,
        microseconds: 740992,
      );
      expect(two53.dartValue.inMicroseconds, 9007199254740992);
      const past = MontyTimeDelta(
        days: 104249,
        seconds: 85654,
        microseconds: 740993,
      );
      if (identical(1, 1.0)) {
        expect(() => past.dartValue, throwsStateError);
      } else {
        expect(
          BigInt.from(past.dartValue.inMicroseconds),
          BigInt.parse('9007199254740993'),
        );
      }
    });
  });
}
