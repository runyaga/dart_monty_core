// MontyLimits on the wire: `toJson`, `fromJson`, and value semantics.
//
// monty_limits.dart sat at 34.6% (9/26). What was uncovered is the whole wire
// surface: `fromJson`, `toJson`, `hashCode` and `toString`. The existing
// monty_limits_test.dart covers only the `jsAligned` factory.
//
// Neither `toJson` nor `fromJson` has a single caller in lib/, test/,
// example/ or packages/: they are public API used only from outside.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontyLimits.toJson', () {
    test('omits every null field, so empty limits serialise to {}', () {
      expect(const MontyLimits().toJson(), isEmpty);
    });

    test('emits only the fields that are set', () {
      expect(
        const MontyLimits(memoryBytes: 1024).toJson(),
        {'memory_bytes': 1024},
      );
      expect(
        const MontyLimits(timeoutMs: 50, stackDepth: 8).toJson(),
        {'timeout_ms': 50, 'stack_depth': 8},
      );
    });

    test('emits all three when all three are set', () {
      expect(
        const MontyLimits(memoryBytes: 1, timeoutMs: 2, stackDepth: 3).toJson(),
        {'memory_bytes': 1, 'timeout_ms': 2, 'stack_depth': 3},
      );
    });
  });

  group('MontyLimits.fromJson', () {
    test('absent keys decode to null, meaning unlimited', () {
      final l = MontyLimits.fromJson(const {});

      expect(l.memoryBytes, isNull);
      expect(l.timeoutMs, isNull);
      expect(l.stackDepth, isNull);
      expect(l, const MontyLimits());
    });

    test('present keys decode to their values', () {
      final l = MontyLimits.fromJson(const {
        'memory_bytes': 1024,
        'timeout_ms': 50,
        'stack_depth': 8,
      });

      expect(l.memoryBytes, 1024);
      expect(l.timeoutMs, 50);
      expect(l.stackDepth, 8);
    });

    test('a partial map leaves the rest unlimited', () {
      final l = MontyLimits.fromJson(const {'timeout_ms': 7});

      expect(l.timeoutMs, 7);
      expect(l.memoryBytes, isNull);
      expect(l.stackDepth, isNull);
    });

    test('round-trips through toJson, preserving which fields are null', () {
      const cases = [
        MontyLimits(),
        MontyLimits(memoryBytes: 1024),
        MontyLimits(timeoutMs: 50),
        MontyLimits(stackDepth: 8),
        MontyLimits(memoryBytes: 1, timeoutMs: 2, stackDepth: 3),
      ];

      for (final original in cases) {
        expect(
          MontyLimits.fromJson(original.toJson()),
          original,
          reason: 'round-trip must not invent or drop a limit',
        );
      }
    });
  });

  group('MontyLimits value semantics', () {
    test('equality and hashCode follow all three fields', () {
      const a = MontyLimits(memoryBytes: 1, timeoutMs: 2, stackDepth: 3);
      const b = MontyLimits(memoryBytes: 1, timeoutMs: 2, stackDepth: 3);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));

      expect(
        a,
        isNot(
          equals(
            const MontyLimits(memoryBytes: 9, timeoutMs: 2, stackDepth: 3),
          ),
        ),
      );
      expect(
        a,
        isNot(
          equals(
            const MontyLimits(memoryBytes: 1, timeoutMs: 9, stackDepth: 3),
          ),
        ),
      );
      expect(
        a,
        isNot(
          equals(
            const MontyLimits(memoryBytes: 1, timeoutMs: 2, stackDepth: 9),
          ),
        ),
      );
    });

    test('a set field never equals an unset one', () {
      expect(const MontyLimits(memoryBytes: 0), isNot(const MontyLimits()));
    });

    test('toString names every field', () {
      const l = MontyLimits(memoryBytes: 11, timeoutMs: 22, stackDepth: 33);
      final text = l.toString();

      expect(text, startsWith('MontyLimits('));
      expect(text, contains('11'));
      expect(text, contains('22'));
      expect(text, contains('33'));
    });
  });
}
