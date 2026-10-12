// The public testing entry, `package:dart_monty_core/dart_monty_core_testing.dart`,
// is the ONLY non-test import in this file, on purpose. It proves the entry is
// self-sufficient: a consumer can drive `MockMontyPlatform` — configure it,
// run it, read its history — without importing anything under `src/`.
//
// Expected values are the literals this file feeds in; the mock echoes inputs,
// so nothing here is derived from running the code under test.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

const _usage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

void main() {
  group('dart_monty_core_testing.dart', () {
    test('MockMontyPlatform is a MontyPlatform with future capability', () {
      final MontyPlatform platform = MockMontyPlatform();

      expect(platform, isA<MontyFutureCapable>());
    });

    test('run() returns the configured result and records the call', () async {
      final mock = MockMontyPlatform()
        ..runResult = const MontyResult(value: MontyInt(7), usage: _usage);
      const limits = MontyLimits(timeoutMs: 250);

      final result = await mock.run(
        '3 + 4',
        limits: limits,
        scriptName: 's.py',
      );

      expect(result.value, const MontyInt(7));
      final history = mock.history;
      expect(history, isA<MockCallHistory>());
      expect(history.runCodes, ['3 + 4']);
      expect(history.lastRunLimits, same(limits));
      expect(history.lastRunScriptName, 's.py');
    });

    test('run() without a configured result throws StateError', () async {
      final mock = MockMontyPlatform();

      await expectLater(mock.run('1'), throwsStateError);
      expect(mock.history.runCodes, isEmpty);
    });

    test('start/resume replay the enqueued progress in order', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(functionName: 'fetch', args: [MontyString('a')]),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyString('done'), usage: _usage),
          ),
        );

      final first = await mock.start(
        'fetch("a")',
        externalFunctions: ['fetch'],
      );
      expect(first, isA<MontyPending>());
      expect((first as MontyPending).functionName, 'fetch');

      final second = await mock.resume('payload');
      expect(second, isA<MontyComplete>());
      expect(
        (second as MontyComplete).result.value,
        const MontyString('done'),
      );

      expect(mock.history.lastStartCode, 'fetch("a")');
      expect(mock.history.lastStartExternalFunctions, ['fetch']);
      expect(mock.history.resumeReturnValues, ['payload']);
    });

    test('a MontyComplete returns the mock to idle', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await mock.start('a');
      // Idle again, so a second start() is accepted rather than refused.
      await mock.start('b');

      expect(mock.history.startCodes, ['a', 'b']);
    });

    test('dispose() makes later calls refuse', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );
      await mock.dispose();

      await expectLater(mock.start('x'), throwsStateError);
      expect(mock.history.startCodes, isEmpty);
    });
  });
}
