// NameLookupSnapshot validation must precede consumption and transmission.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_pool_protocol_support.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

pb.ChildEvent _lookup() => pb.ChildEvent(nameLookup: pb.NameLookup(name: 'x'));

Future<void> _lifecycle(bool closed) async {
  final (session, channel) = await poolB2Session([
    answer([_lookup()]),
    if (!closed) answer([completeNone()]),
  ]);
  final snapshot = await session.feedStart('x') as NameLookupSnapshot;
  if (closed) {
    await session.close();
    await expectLater(snapshot.dump, finishedPool);
  } else {
    final done =
        await snapshot.resume(value: const MontyNone()) as MontyComplete;
    expect(done.output, const MontyNone());
  }
  await expectLater(
    () => snapshot.resume(value: const MontyNone()),
    closed ? finishedPool : spentPool,
  );
  await expectLater(snapshot.dump, throwsStateError);
  await expectLater(snapshot.resumeAuto, throwsStateError);
  expect(channel.requests, hasLength(3));
}

Future<void> _refusal(
  MontyValue value,
  Matcher error, {
  bool spent = false,
}) async {
  final completed = answer([completeNone()]);
  final (session, channel) = await poolB2Session([
    answer([_lookup()]),
    completed,
    completed,
  ]);
  final snapshot = await session.feedStart('x') as NameLookupSnapshot;
  final resume = snapshot.resume;
  if (spent) await resume(value: const MontyNone());
  expect(() => snapshot.resume(value: value), error);
  expect(channel.requests, hasLength(spent ? 3 : 2));
  if (!spent) {
    final done = await resume(value: const MontyNone()) as MontyComplete;
    expect(done.output, const MontyNone());
  }
  expect(await session.feedRun('None'), const MontyNone());
}

MontyList _cycle() {
  final items = <MontyValue>[];
  final value = MontyList(items);
  items.add(value);

  return value;
}

Future<void> _bareLookupRefusalEndsCheckout() async {
  final discarded = ScriptedChannel([
    configurePool,
    answer([_lookup()]),
  ]);
  final replacement = ScriptedChannel([
    configurePool,
    answer([completeNone()]),
    resetPool,
  ]);
  final pool = await poolWith([discarded, replacement]);
  final checkout = pool.checkout;
  final session = await checkout();

  await expectLater(
    session.feedRun(
      'try:\n  x\nexcept ValueError:\n  result = "caught"\nresult',
      externalLookup: {'x': _cycle()},
    ),
    throwsA(runtimePool('ValueError', 'Circular reference detected')),
  );
  expect(discarded.kills, 1);
  expect(pool.liveWorkers, 0);
  await expectLater(session.feedRun('later'), finishedPool);

  final retry = await checkout();
  expect(await retry.feedRun('None'), const MontyNone());
  await retry.close();
}

void main() {
  for (final closed in [false, true]) {
    test(
      'lifecycle rejects operations ($closed)',
      () => _lifecycle(closed),
    );
  }
  test(
    'bad value precedes spent state',
    () => _refusal(const MontyBytes([256]), throwsArgumentError, spent: true),
  );
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
      '$label refusal permits retry',
      () => _refusal(value, error),
    );
  }
  for (final (label, value) in [
    ('bytes', const MontyBytes([256])),
    ('date', const MontyDate(year: 0, month: 1, day: 1)),
    ('time', const MontyTime(hour: 24, minute: 0, second: 0, microsecond: 0)),
  ]) {
    test(
      'invalid $label permits retry',
      () => _refusal(value, throwsArgumentError),
    );
  }
  test(
    'caller value and state errors differ',
    () async {
      await _refusal(const MontyBytes([-1]), throwsArgumentError);
      await _lifecycle(false);
      await _lifecycle(true);
    },
  );
  test(
    'oversized answer consumes snapshot',
    () async {
      final (session, channel) = await poolB2Session([
        answer([_lookup()]),
      ], frameLimit: 64);
      final snapshot = await session.feedStart('x') as NameLookupSnapshot;
      await expectLater(
        snapshot.resume(value: MontyString('x' * 100)),
        poolB2Oversized,
      );
      expect(() => snapshot.resume(value: const MontyNone()), spentPool);
      await expectLater(snapshot.dump, throwsStateError);
      expect(channel.requests, hasLength(2));
      await expectLater(session.feedRun('1'), poolB2Pending);
    },
  );
  test(
    'a refused bare lookup ends its checkout outside the sandbox',
    _bareLookupRefusalEndsCheckout,
  );
}
