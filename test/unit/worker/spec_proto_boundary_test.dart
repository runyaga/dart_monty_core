// Session refusals and snapshot lifetimes from the API spec, on all compilers.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

pb.ChildEvent _sleep(bool asynchronous) => pb.ChildEvent(
  osCall: pb.OsCall(
    callId: 7,
    systemSleep: asynchronous ? null : pb.OsCall_Sleep(seconds: 9),
    asyncSystemSleep: asynchronous ? pb.OsCall_AsyncSleep(delay: 9) : null,
  ),
);

void _autoSleep() {
  for (final asynchronous in [false, true]) {
    for (final handled in [false, true]) {
      test('resumeAuto sleep async=$asynchronous handled=$handled', () async {
        final (session, channel) = await protoSession([
          answer([_sleep(asynchronous)]),
          answer([protoInt(42)]),
        ]);
        final calls = <(String, List<MontyValue>, Map<String, MontyValue>)>[];
        final snapshot =
            await session.feedStart(
                  'sleep',
                  os: handled
                      ? (name, args, kwargs) {
                          calls.add((name, args, kwargs));

                          return const MontyInt(23);
                        }
                      : null,
                )
                as FunctionSnapshot;
        final waits = <Duration>[];
        final result = await runZoned(
          snapshot.resumeAuto,
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (duration > Duration.zero) waits.add(duration);

              return parent.createTimer(zone, Duration.zero, callback);
            },
          ),
        );
        expect((result as MontyComplete).output, const MontyInt(42));
        expect(waits, isEmpty);
        expect(calls, hasLength(handled ? 1 : 0));
        final resume = channel.requests.lastOrNull?.resumeCall;
        expect(resume?.callId, 7);
        expect(resume?.result.hasNotHandled(), !handled);
        expect(resume?.result.hasReturnValue(), handled);
        if (handled) {
          final (name, args, kwargs) =
              calls.singleOrNull ?? fail('no handler call');
          expect(name, asynchronous ? 'system.async_sleep' : 'system.sleep');
          expect(args, [const MontyFloat(9)]);
          expect(kwargs, isEmpty);
          final answer = resume ?? fail('no resume');
          expect(
            ArenaReader(answer.values)[answer.result.returnValue],
            const MontyInt(23),
          );
        }
      });
    }
  }
}

void main() {
  _autoSleep();

  for (final (component, value) in [
    ('real', pb.Complex(imag: Int64.ZERO)),
    ('imag', pb.Complex(real: Int64.ZERO)),
  ]) {
    test('missing $component invalidates the session', () async {
      final (session, channel) = await protoSession([
        answer([
          complete([pb.MontyNode(complex: value)]),
        ]),
      ]);
      await expectLater(
        session.feedRun('z'),
        throwsA(
          protoCrash(
            'invalid payload from worker: '
            'missing required field Complex.$component',
          ),
        ),
      );
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
    });
  }

  test(
    'refused path sends nothing '
    'and permits another feed',
    () async {
      final (session, channel) = await protoSession([
        answer([protoInt(42)]),
      ]);
      await expectLater(
        session.feedRun('p', inputs: {'p': MontyPath('/\uD800')}),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', 'ValueError')
              .having(
                (e) => e.toString(),
                'message',
                "UnicodeEncodeError: 'utf-8' codec can't encode character "
                    r"'\ud800' in position 1: surrogates not allowed",
              ),
        ),
      );
      expect(channel.requests, hasLength(1));
      expect(await session.feedRun('42'), const MontyInt(42));
      expect(channel.requests, hasLength(2));
    },
  );

  for (final operation in ['dump', 'decline', 'resume', 'auto']) {
    test('$operation after session close', () async {
      final (session, channel) = await protoSession([
        answer([_sleep(false)]),
        expecting(pb.ParentRequest_Kind.reset, [ok()]),
      ]);
      final snapshot = await session.feedStart('sleep') as FunctionSnapshot;
      await session.close();
      final sent = channel.requests.length;
      await expectLater(
        () => switch (operation) {
          'dump' => snapshot.dump(),
          'decline' => snapshot.resumeNotHandled(),
          'resume' => snapshot.resume(const ExternalReturnValue(MontyNone())),
          _ => snapshot.resumeAuto(),
        },
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'the session is finished',
          ),
        ),
      );
      expect(channel.requests, hasLength(sent));
    });
  }
}
