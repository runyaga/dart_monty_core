// Unit tests for MontyLimits.jsAligned factory.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontyLimits.jsAligned', () {
    test('maxMemory maps to memoryBytes', () {
      expect(
        MontyLimits.jsAligned(maxMemory: 1024).memoryBytes,
        1024,
      );
    });

    test('maxDurationSecs 5 maps to timeoutMs 5000', () {
      expect(
        MontyLimits.jsAligned(maxDurationSecs: 5).timeoutMs,
        5000,
      );
    });

    test('maxDurationSecs 0.5 maps to timeoutMs 500', () {
      expect(
        MontyLimits.jsAligned(maxDurationSecs: 0.5).timeoutMs,
        500,
      );
    });

    test('maxDurationSecs rounds fractional milliseconds', () {
      // 1.0005 * 1000 = 1000.5 → rounds to 1001
      expect(
        MontyLimits.jsAligned(maxDurationSecs: 1.0005).timeoutMs,
        1001,
      );
    });

    test('maxRecursionDepth maps to stackDepth', () {
      expect(
        MontyLimits.jsAligned(maxRecursionDepth: 200).stackDepth,
        200,
      );
    });

    test('all-null produces limits equal to MontyLimits()', () {
      expect(
        MontyLimits.jsAligned(),
        equals(const MontyLimits()),
      );
    });

    test('all fields set together', () {
      final limits = MontyLimits.jsAligned(
        maxMemory: 1000000,
        maxDurationSecs: 5,
        maxRecursionDepth: 200,
      );
      expect(limits.memoryBytes, 1000000);
      expect(limits.timeoutMs, 5000);
      expect(limits.stackDepth, 200);
    });
  });
}
