import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:dart_monty_core/src/worker/telemetry.dart' show telemetryBridge;
import 'package:test/test.dart';

import 'recording_adapter.dart';

/// Each irreversible signal failure runs in its own suite/isolate.
void failureCase(String failure, {bool brokenDiagnostic = false}) {
  test(
    '$failure stays disabled across sessions; other signals survive',
    () async {
      final diagnostics = <String>[];
      final adapter = RecordingAdapter(failure: failure);
      runZoned(
        () => instrumentTelemetry(adapter),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            diagnostics.add(line);
            if (brokenDiagnostic) throw StateError('diagnostic sink');
          },
        ),
      );
      var calls = 0;
      for (var i = 0; i < 2; i++) {
        final fake = FakeMontySession()
          ..willCall('ext')
          ..willPrint('hi')
          ..willReturn(const MontyInt(42));
        final result = await fake.feedRun(
          'ext()',
          printCallback: (_, _) {},
          externalLookup: {
            'ext': MontyHostFunction('ext', (args, kwargs) {
              calls++;
              return const MontyInt(42);
            }),
          },
        );
        expect(result, const MontyInt(42));
        expect(
          fake.answers.single.answer,
          const ExternalReturnValue(MontyInt(42)),
        );
        telemetryBridge!.recordMetric(
          'test',
          'counter',
          '1',
          'test',
          1,
          const {},
        );
        await fake.close();
      }
      expect(calls, 2);
      expect(diagnostics, hasLength(1));
      final signal = failure == 'logs' || failure == 'metrics'
          ? failure
          : 'spans';
      expect(diagnostics.single, contains(signal));
      expect(diagnostics.single, contains('RecordingAdapter'));
      expect(diagnostics.single, contains('adapter-$failure'));
      expect(diagnostics.single, contains('RecordingAdapter._check'));
      expect(adapter.attempts[failure], 1);
      if (signal != 'logs') expect(adapter.logs, hasLength(2));
      if (signal != 'metrics') expect(adapter.metrics, [1, 1]);
      if (signal != 'spans') {
        expect(adapter.spans.where((s) => s.name == 'run code'), hasLength(2));
      } else {
        expect(adapter.logs.every((log) => log.span == null), isTrue);
      }
    },
  );
}
