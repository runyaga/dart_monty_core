import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  test(
    'callback error is preserved exactly once and leaves spans enabled',
    () async {
      final adapter = RecordingAdapter();
      instrumentTelemetry(adapter);
      final fake = FakeMontySession();
      addTearDown(fake.close);
      var calls = 0;
      fake
        ..willCall('ext')
        ..willCatch()
        ..willReturn(const MontyInt(42));
      await fake.feedRun(
        'ext()',
        externalLookup: {
          'ext': MontyHostFunction('ext', (args, kwargs) {
            calls++;
            throw const ExternalException('ValueError', 'callback');
          }),
        },
      );
      expect(calls, 1);
      expect(
        adapter.spans.lastOrNull?.attributes['return_value'],
        'raise ValueError: callback',
      );
      fake.willReturn(const MontyInt(7));
      expect(await fake.feedRun('7'), const MontyInt(7));
      expect(adapter.spans.where((s) => s.name == 'run code'), hasLength(2));
    },
  );
}
