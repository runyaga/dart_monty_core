// Consumption precedes automatic preparation, including caller-owned lookups.
import 'dart:async';
import 'dart:collection';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_pool_protocol_support.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

final class _Lookup extends MapBase<String, MontyValue> {
  const _Lookup(this.read);

  final MontyValue Function() read;

  @override
  MontyValue? operator [](Object? key) => read();
  @override
  void operator []=(String key, MontyValue value) =>
      throw UnsupportedError('read only');
  @override
  Iterable<String> get keys => const ['x'];
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  MontyValue? remove(Object? key) => throw UnsupportedError('read only');
}

final Matcher _oversizedAnswer = isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'exception type', 'RuntimeError')
    .having(
      (e) => e.exception.message,
      'message',
      matches(
        RegExp(
          r'^request frame of \d+ bytes exceeds the maximum of 64 bytes$',
        ),
      ),
    );

Future<void> _lookupOrder() async {
  final (session, _) = await poolB2Session([
    answer([pb.ChildEvent(nameLookup: pb.NameLookup(name: 'x'))]),
    answer([completeNone()]),
  ]);
  late final NameLookupSnapshot snapshot;
  bool? spent;
  snapshot =
      await session.feedStart(
            'x',
            externalLookup: _Lookup(() {
              spent = snapshot.isSpent;

              return const MontyInt(3);
            }),
          )
          as NameLookupSnapshot;
  final done = await snapshot.resumeAuto() as MontyComplete;
  expect(spent, isTrue);
  expect(done.output, const MontyNone());
}

Future<void> _futureOrder() async {
  final (session, channel) = await poolB2Session([
    answer([poolCall()]),
    answer([poolB2Futures()]),
    answer([completeNone()]),
  ]);
  final release = Completer<MontyValue>();
  final call =
      await session.feedStart(
            'await f()',
            externalLookup: {
              'f': MontyHostFunction('f', coroutine((_, _) => release.future)),
            },
          )
          as FunctionSnapshot;
  final pending = await call.resumeAuto() as FutureSnapshot;
  final running = pending.resumeAuto();
  await pumpEventQueue();
  expect(pending.isSpent, isTrue);
  await expectLater(pending.resumeAuto(), spentPool);
  expect(channel.requests, hasLength(3));
  release.complete(const MontyInt(3));
  final done = await running as MontyComplete;
  expect(done.output, const MontyNone());
}

Future<void> _oversizedCallAnswer() async {
  final channel = ScriptedChannel([
    configurePool,
    answer([poolCall()]),
  ], frameLimit: 64);
  final pool = await poolWith([channel]);
  final session = await pool.checkout();
  addTearDown(session.close);
  final call =
      await session.feedStart(
            'f()',
            externalLookup: {
              'f': MontyHostFunction(
                'f',
                (_, _) => MontyString('x' * 100),
              ),
            },
          )
          as FunctionSnapshot;

  await expectLater(call.resumeAuto(), throwsA(_oversizedAnswer));
  expect(call.isSpent, isTrue);
  expect(channel.requests, hasLength(2));
  await expectLater(session.feedRun('1'), poolB2Pending);
}

Future<void> _oversizedFutureAnswer() async {
  final channel = ScriptedChannel([
    configurePool,
    answer([poolCall()]),
    answer([poolB2Futures()]),
  ], frameLimit: 64);
  final pool = await poolWith([channel]);
  final session = await pool.checkout();
  addTearDown(session.close);
  final release = Completer<MontyValue>();
  final call =
      await session.feedStart(
            'await f()',
            externalLookup: {
              'f': MontyHostFunction('f', coroutine((_, _) => release.future)),
            },
          )
          as FunctionSnapshot;
  final waiting = await call.resumeAuto() as FutureSnapshot;
  release.complete(MontyString('x' * 100));

  await expectLater(waiting.resumeAuto(), throwsA(_oversizedAnswer));
  expect(waiting.isSpent, isTrue);
  expect(channel.requests, hasLength(3));
  await expectLater(session.feedRun('1'), poolB2Pending);
}

void main() {
  group('automatic host answers', () {
    test(
      'a lookup consumes before map access',
      _lookupOrder,
    );
    test(
      'a future consumes before host settles',
      _futureOrder,
    );
    test(
      'an oversized call answer leaves its suspension pending',
      _oversizedCallAnswer,
    );
    test(
      'an oversized future answer leaves its suspension pending',
      _oversizedFutureAnswer,
    );
  });
}
