// Restore byte preservation and system sleep dispatch on all Dart compilers.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

void main() {
  for (final suspended in [false, true]) {
    test(
      'restore bytes (suspended=$suspended)',
      () async {
        final state = Uint8List.fromList([0, 1, 127, 128, 255]);
        final (session, channel) = await protoConfiguredSession(
          [
            expecting(pb.ParentRequest_Kind.load, [
              if (suspended) protoCall() else ok(),
            ]),
            answer([protoInt(42)]),
          ],
          config: const SessionConfig(
            limits: ResourceLimits(
              maxSuspensions: 2,
              maxTotalSleep: Duration(seconds: 1),
            ),
          ),
        );
        if (suspended) {
          final call = await session.loadSnapshot(state) as FunctionSnapshot;
          expect(
            (await call.resume(const ExternalReturnValue(MontyInt(42)))
                    as MontyComplete)
                .output,
            const MontyInt(42),
          );
        } else {
          await session.loadSession(state);
          expect(await session.feedRun('42'), const MontyInt(42));
        }
        final request =
            channel.requests.elementAtOrNull(1) ?? fail('missing Load');
        expect(request.load.state, [0, 1, 127, 128, 255]);
        expect(state, [0, 1, 127, 128, 255]);
      },
    );
  }

  test(
    'system sleeps wait without consulting os',
    () async {
      final (session, channel) = await protoConfiguredSession([
        answer([
          pb.ChildEvent(
            osCall: pb.OsCall(
              callId: 1,
              systemSleep: pb.OsCall_Sleep(seconds: 0.02),
            ),
          ),
        ]),
        answer([protoInt(42)]),
      ]);
      var handlerCalls = 0;
      final waits = <Duration>[];
      final result = await runZoned(
        () => session.feedRun(
          'time.sleep(0.02)',
          os: (_, _, _) {
            handlerCalls++;

            return const MontyInt(99);
          },
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration == const Duration(milliseconds: 20)) {
              waits.add(duration);

              return parent.createTimer(zone, Duration.zero, callback);
            }

            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
      expect(result, const MontyInt(42));
      expect(handlerCalls, 0);
      expect(waits, [const Duration(milliseconds: 20)]);
      final resumed =
          channel.requests.elementAtOrNull(2) ?? fail('missing resume');
      expect(resumed.resumeCall.result.hasReturnValue(), isTrue);
      expect(resumed.resumeCall.values.nodes.singleOrNull?.none, pb.Unit());
    },
  );
}
