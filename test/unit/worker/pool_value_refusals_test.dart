// Input and manual-answer refusals are local and leave a corrected retry.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:test/test.dart';

import '_pool_protocol_support.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

MontyFrozenSet _cycle() {
  final items = <MontyValue>[];
  final value = MontyFrozenSet(items);
  items.add(value);

  return value;
}

Future<void> _refused(
  MontyValue value,
  Matcher error, {
  bool expectUnspent = false,
}) async {
  final completed = answer([completeNone()]);
  final (session, channel) = await poolB2Session([
    answer([poolCall()]),
    completed,
    completed,
  ]);
  await expectLater(session.feedRun('x', inputs: {'x': value}), error);
  await expectLater(session.feedStart('x', inputs: {'x': value}), error);
  expect(channel.requests, hasLength(1));
  final snapshot = await session.feedStart('f()') as FunctionSnapshot;
  expect(() => snapshot.resume(ExternalReturnValue(value)), error);
  expect(channel.requests, hasLength(2));
  if (expectUnspent) expect(snapshot.isSpent, isFalse);
  final done = await snapshot.resume(poolB2Answer) as MontyComplete;
  expect(done.output, const MontyNone());
  expect(await session.feedRun('None'), const MontyNone());
}

void main() {
  test(
    'surrogate path sends nothing and permits retry',
    () => _refused(
      MontyPath('\ud800'),
      throwsA(
        isA<MontyRuntimeError>()
            .having((e) => e.exception.excType, 'type', 'ValueError')
            .having(
              (e) => e.toString(),
              'text',
              "UnicodeEncodeError: 'utf-8' codec can't encode character "
                  r"'\ud800' in position 0: surrogates not allowed",
            ),
      ),
      expectUnspent: true,
    ),
  );
  test(
    'set with an unhashable member sends nothing and permits retry',
    () => _refused(
      const MontySet([MontyList([])]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "TypeError: unhashable type: 'list'",
        ),
      ),
      expectUnspent: true,
    ),
  );
  for (final offset in [-86400, 86400]) {
    test(
      'offset $offset sends nothing and permits retry',
      () => _refused(
        MontyTimeZone(offsetSeconds: offset),
        throwsArgumentError,
        expectUnspent: true,
      ),
    );
  }
  test(
    'unhashable member sends nothing and permits retry',
    () => _refused(
      const MontyFrozenSet([MontyList([])]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "TypeError: unhashable type: 'list'",
        ),
      ),
    ),
  );
  test(
    'cyclic frozenset sends nothing and permits retry',
    () => _refused(
      _cycle(),
      throwsA(runtimePool('ValueError', 'Circular reference detected')),
    ),
  );
  for (final (label, value) in [
    ('days', const MontyTimeDelta(days: 1000000000, seconds: 0)),
    ('seconds', const MontyTimeDelta(days: 0, seconds: -1)),
    (
      'microseconds',
      const MontyTimeDelta(days: 0, seconds: 0, microseconds: 1000000),
    ),
  ]) {
    test(
      'invalid $label sends nothing and permits retry',
      () => _refused(value, throwsArgumentError),
    );
  }
}
