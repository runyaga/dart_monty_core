import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  test(
    'telemetry begins only after adapter installation',
    () async {
      final adapter = RecordingAdapter();
      final beforeInstallation = FakeMontySession()
        ..willCall('ext')
        ..willReturn(const MontyInt(42));
      final snapshot =
          await beforeInstallation.feedStart('ext()') as FunctionSnapshot;
      expect(snapshot.traceContext(), isNull);
      final result = await snapshot.resume(
        const ExternalReturnValue(MontyInt(42)),
      );
      expect((result as MontyComplete).output, const MontyInt(42));
      expect(snapshot.traceContext, throwsStateError);
      await beforeInstallation.close();
      expect(adapter.spans, isEmpty);
      expect(adapter.logs, isEmpty);
      expect(adapter.metrics, isEmpty);

      instrumentTelemetry(adapter);
      final afterInstallation = FakeMontySession()
        ..willReturn(const MontyInt(7));
      addTearDown(afterInstallation.close);
      expect(
        await afterInstallation.feedRun('7'),
        const MontyInt(7),
      );
      expect(adapter.spans.map((span) => span.name), [
        'session {script_name}',
        'run code',
      ]);
    },
  );
}
