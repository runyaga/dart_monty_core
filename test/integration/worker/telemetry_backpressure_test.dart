@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';

import '../../unit/telemetry/recording_adapter.dart';
import '_worker_harness.dart';
import 'fake_worker.dart' show floodPrints;

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'installed adapter preserves simultaneous stdout drain and stdin flush',
    () async {
      final adapter = RecordingAdapter();
      instrumentTelemetry(adapter);
      final channel = await ProcessChannel.spawn(fakeWorker('flood'));
      addTearDown(() async {
        channel.kill();
        await channel.close();
      });
      final session = await ProtoSession.open(channel);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!channel.readAhead.paused) {
        if (DateTime.now().isAfter(deadline)) fail('stdout did not fill');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final result = await session
          .feed('#' * (2 << 20))
          .timeout(const Duration(seconds: 3));
      expect(result.value, const MontyNone());
      expect(adapter.logs, hasLength(floodPrints));
      expect(
        adapter.spans.lastOrNull?.attributes['length_limit_exceeded'],
        true,
      );
      await session.close();
      expect(adapter.spans.every((span) => span.end != null), isTrue);
    },
  );
}
