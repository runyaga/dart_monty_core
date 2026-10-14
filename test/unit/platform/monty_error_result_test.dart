// Unit tests for MontyResult, the old engine's result type. The error types
// that used to share this file are in monty_exception_test.dart.
//
// Existing coverage skipped to avoid duplication:
//   - MontyResult.ok / .excType   → monty_result_getters_test.dart
//
// Pure value-level tests: no interpreter, no FFI, no WASM.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

const _someUsage = MontyResourceUsage(
  memoryBytesUsed: 1024,
  timeElapsedMs: 42,
  stackDepthUsed: 7,
);

void main() {
  // ------------------------------------------------------------------
  // MontyResult
  // ------------------------------------------------------------------

  group('MontyResult equality + hashCode', () {
    test('two identical success results compare equal', () {
      const a = MontyResult(value: MontyInt(42), usage: _zeroUsage);
      const b = MontyResult(value: MontyInt(42), usage: _zeroUsage);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('two identical error results compare equal', () {
      const a = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'boom', excType: 'ValueError'),
        usage: _zeroUsage,
      );
      const b = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'boom', excType: 'ValueError'),
        usage: _zeroUsage,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different value field is not equal', () {
      expect(
        const MontyResult(value: MontyInt(1), usage: _zeroUsage),
        isNot(const MontyResult(value: MontyInt(2), usage: _zeroUsage)),
      );
    });

    test('different error message is not equal', () {
      const a = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'a'),
        usage: _zeroUsage,
      );
      const b = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'b'),
        usage: _zeroUsage,
      );
      expect(a, isNot(b));
    });

    test('different usage stats is not equal', () {
      expect(
        const MontyResult(value: MontyInt(1), usage: _zeroUsage),
        isNot(const MontyResult(value: MontyInt(1), usage: _someUsage)),
      );
    });

    test('different printOutput is not equal', () {
      expect(
        const MontyResult(
          value: MontyInt(1),
          usage: _zeroUsage,
          printOutput: 'hi',
        ),
        isNot(
          const MontyResult(
            value: MontyInt(1),
            usage: _zeroUsage,
            printOutput: 'bye',
          ),
        ),
      );
    });
  });

  group('MontyResult JSON round-trip', () {
    test('success result with value', () {
      const r = MontyResult(value: MontyInt(42), usage: _someUsage);
      expect(MontyResult.fromJson(r.toJson()), r);
    });

    test('error result preserves all exception fields', () {
      const r = MontyResult(
        value: MontyNone(),
        error: MontyException(
          message: 'division by zero',
          filename: 'main.py',
          lineNumber: 5,
          columnNumber: 12,
          sourceCode: '1 / 0',
          excType: 'ZeroDivisionError',
        ),
        usage: _zeroUsage,
      );
      expect(MontyResult.fromJson(r.toJson()), r);
    });

    test('result with printOutput round-trips', () {
      const r = MontyResult(
        value: MontyNone(),
        usage: _zeroUsage,
        printOutput: 'hello\nworld',
      );
      expect(MontyResult.fromJson(r.toJson()), r);
    });

    test('toJson omits null printOutput entirely', () {
      const r = MontyResult(value: MontyInt(1), usage: _zeroUsage);
      expect(r.toJson().containsKey('print_output'), isFalse);
    });

    test('toJson omits null error entirely', () {
      const r = MontyResult(value: MontyInt(1), usage: _zeroUsage);
      expect(r.toJson().containsKey('error'), isFalse);
    });

    test('toJson includes error key when error is set', () {
      const r = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'x'),
        usage: _zeroUsage,
      );
      expect(r.toJson().containsKey('error'), isTrue);
    });
  });

  group('MontyResult.toString', () {
    test('value variant', () {
      expect(
        const MontyResult(
          value: MontyInt(42),
          usage: _zeroUsage,
        ).toString(),
        contains('MontyInt(42)'),
      );
    });

    test('error variant uses error.message', () {
      const r = MontyResult(
        value: MontyNone(),
        error: MontyException(message: 'boom'),
        usage: _zeroUsage,
      );
      final s = r.toString();
      expect(s, contains('boom'));
      expect(s, contains('error'));
    });
  });
}
