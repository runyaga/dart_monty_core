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
          printCallback: (stream, text) => expect(text, isNotEmpty),
          externalLookup: {
            'ext': MontyHostFunction('ext', (args, kwargs) {
              calls++;

              return const MontyInt(42);
            }),
          },
        );
        expect(result, const MontyInt(42));
        expect(
          fake.answers.singleOrNull?.answer,
          const ExternalReturnValue(MontyInt(42)),
        );
        requireRecord(telemetryBridge).recordMetric(
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
      final diagnostic = diagnostics.singleOrNull;
      expect(diagnostic, contains('Monty telemetry $signal disabled'));
      expect(diagnostic, contains('(${adapter.runtimeType})'));
      expect(diagnostic, contains('Bad state: adapter-$failure'));
      expect(adapter.attempts[failure], 1);
      final logs = adapter.logs;
      final twice = hasLength(2);
      if (signal != 'logs') expect(logs, twice);
      if (signal != 'metrics') expect(adapter.metrics, [1, 1]);
      if (signal != 'spans') {
        expect(adapter.spans.where((s) => s.name == 'run code'), twice);
      } else {
        expect(logs.every((log) => log.span == null), isTrue);
      }
    },
  );
}
