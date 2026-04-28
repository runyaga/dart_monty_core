// Unit tests for MontyResult convenience getters: ok, excType.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

void main() {
  group('MontyResult.ok', () {
    test('returns true when error is null', () {
      const r = MontyResult(value: MontyInt(42), usage: _zeroUsage);
      expect(r.ok, isTrue);
      expect(r.isError, isFalse);
    });

    test('returns false when error is set', () {
      const r = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'boom'),
        usage: _zeroUsage,
      );
      expect(r.ok, isFalse);
      expect(r.isError, isTrue);
    });

    test('is the inverse of isError', () {
      const ok = MontyResult(value: MontyInt(1), usage: _zeroUsage);
      const err = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'x'),
        usage: _zeroUsage,
      );
      expect(ok.ok, equals(!ok.isError));
      expect(err.ok, equals(!err.isError));
    });
  });

  group('MontyResult.excType', () {
    test('returns null when error is null', () {
      const r = MontyResult(value: MontyInt(42), usage: _zeroUsage);
      expect(r.excType, isNull);
    });

    test('returns null when error is set without excType', () {
      const r = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'unknown'),
        usage: _zeroUsage,
      );
      expect(r.excType, isNull);
    });

    test('forwards error.excType when set', () {
      const r = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'bad value', excType: 'ValueError'),
        usage: _zeroUsage,
      );
      expect(r.excType, 'ValueError');
    });
  });
}
