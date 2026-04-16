// Unit tests for MontyComplete.output shorthand getter.
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
  group('MontyComplete.output', () {
    test('output equals result.value', () {
      const complete = MontyComplete(
        result: MontyResult(value: MontyInt(42), usage: _zeroUsage),
      );
      expect(complete.output, equals(complete.result.value));
    });

    test('output returns the MontyValue directly', () {
      const complete = MontyComplete(
        result: MontyResult(value: MontyString('hello'), usage: _zeroUsage),
      );
      expect(complete.output, const MontyString('hello'));
    });

    test('output works with MontyNone', () {
      const complete = MontyComplete(
        result: MontyResult(value: MontyNone(), usage: _zeroUsage),
      );
      expect(complete.output, const MontyNone());
    });
  });
}
