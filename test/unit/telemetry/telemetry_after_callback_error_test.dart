import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  test(
    'callback error survives context exit failure without retrying',
    () async {
      final adapter = RecordingAdapter(failure: 'afterCallback');
      instrumentTelemetry(adapter);
      final fake = FakeMontySession()
        ..willCall('ext')
        ..willCatch()
        ..willReturn(const MontyInt(42));
      addTearDown(fake.close);
      var calls = 0;
      expect(
        await fake.feedRun(
          'ext()',
          externalLookup: {
            'ext': MontyHostFunction('ext', (args, kwargs) {
              calls++;
              throw const ExternalException('ValueError', 'callback');
            }),
          },
        ),
        const MontyInt(42),
      );
      expect(calls, 1);
      expect(adapter.attempts['afterCallback'], 1);
      expect(
        fake.answers.singleOrNull?.answer,
        const ExternalException('ValueError', 'callback'),
      );
    },
  );
}
