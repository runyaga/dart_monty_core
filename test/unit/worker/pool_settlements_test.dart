// ExternalSettledResult: validate/convert before consuming; frame checks after.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:test/test.dart';

import '_pool_protocol_support.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

MontyList _cycle() {
  final values = <MontyValue>[];
  final cycle = MontyList(values);
  values.add(cycle);

  return cycle;
}

Future<void> _refused(
  MontyValue value,
  Matcher error, {
  bool spent = false,
}) async {
  final (session, channel) = await poolB2Session([
    answer([poolB2Futures()]),
    answer([completeNone()]),
  ]);
  final snapshot = await session.feedStart('await f()') as FutureSnapshot;
  if (spent) await snapshot.resume({1: poolB2Answer});
  expect(() => snapshot.resume({1: ExternalReturnValue(value)}), error);
  expect(snapshot.isSpent, spent);
  expect(channel.requests, hasLength(spent ? 3 : 2));
  if (!spent) {
    final done = await snapshot.resume({1: poolB2Answer}) as MontyComplete;
    expect(done.output, const MontyNone());
  }
}

Future<void> _repeated() async {
  final (session, channel) = await poolB2Session([
    answer([poolB2Futures()]),
    answer([completeNone()]),
  ]);
  final snapshot = await session.feedStart('await f()') as FutureSnapshot;
  final done = await snapshot.resume({1: poolB2Answer}) as MontyComplete;
  expect(done.output, const MontyNone());
  expect(() => snapshot.resume({1: poolB2Answer}), spentPool);
  expect(channel.requests, hasLength(3));
}

void main() {
  for (final wasSpent in [false, true]) {
    for (final callId in [-1, 4294967296]) {
      test(
        'call ID $callId is refused '
        '${wasSpent ? 'after settlement' : 'before consumption'}',
        () async {
          final (session, channel) = await poolB2Session([
            answer([poolB2Futures()]),
            answer([completeNone()]),
          ]);
          final snapshot =
              await session.feedStart('await f()') as FutureSnapshot;
          if (wasSpent) {
            await snapshot.resume({1: poolB2Answer});
          }
          expect(
            () => snapshot.resume({callId: poolB2Answer}),
            throwsArgumentError,
          );
          expect(
            channel.requests,
            hasLength(wasSpent ? 3 : 2),
          );
          if (!wasSpent) {
            expect(snapshot.isSpent, isFalse);
            final done =
                await snapshot.resume({1: poolB2Answer}) as MontyComplete;
            expect(done.output, const MontyNone());
          }
        },
      );
    }
  }

  for (final (label, value, error) in [
    (
      'cycle',
      _cycle(),
      throwsA(runtimePool('ValueError', 'Circular reference detected')),
    ),
    (
      'surrogate',
      const MontyString('\ud800'),
      throwsA(
        runtimePool(
          'ValueError',
          r"'utf-8' codec can't encode character '\ud800' in position 0: "
              'surrogates not allowed',
        ),
      ),
    ),
  ]) {
    test(
      '$label leaves the future pending',
      () => _refused(value, error),
    );
    test(
      '$label precedes consumed state',
      () => _refused(value, error, spent: true),
    );
  }
  for (final (label, value) in [
    ('bytes', const MontyBytes([256])),
    ('date', const MontyDate(year: 0, month: 1, day: 1)),
    ('time', const MontyTime(hour: 24, minute: 0, second: 0, microsecond: 0)),
  ]) {
    test(
      'invalid $label permits corrected '
      'settlement',
      () => _refused(value, throwsArgumentError),
    );
    test(
      'invalid $label precedes consumed state',
      () => _refused(value, throwsArgumentError, spent: true),
    );
  }
  test('a repeated valid settlement throws StateError', _repeated);
  test(
    'unknown exception precedes consumed state',
    () async {
      final (session, channel) = await poolB2Session([
        answer([poolB2Futures()]),
        answer([completeNone()]),
      ]);
      final snapshot = await session.feedStart('await f()') as FutureSnapshot;
      await snapshot.resume({1: poolB2Answer});
      expect(
        () => snapshot.resume({1: const ExternalException('Unknown')}),
        throwsArgumentError,
      );
      expect(channel.requests, hasLength(3));
    },
  );
  test(
    'oversized settlement spends without sending',
    () async {
      final (session, channel) = await poolB2Session([
        answer([poolB2Futures()]),
      ], frameLimit: 64);
      final snapshot = await session.feedStart('await f()') as FutureSnapshot;
      await expectLater(
        snapshot.resume({1: ExternalReturnValue(MontyString('x' * 100))}),
        poolB2Oversized,
      );
      expect(snapshot.isSpent, isTrue);
      expect(channel.requests, hasLength(2));
      expect(() => snapshot.resume({1: poolB2Answer}), spentPool);
      await expectLater(session.feedRun('1'), poolB2Pending);
    },
  );
}
