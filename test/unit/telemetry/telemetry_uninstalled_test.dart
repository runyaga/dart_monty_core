import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  test(
    'without installation feed is unchanged and snapshot context is null',
    () async {
      final unused = RecordingAdapter();
      final fake = FakeMontySession();
      addTearDown(fake.close);
      fake
        ..willCall('ext')
        ..willReturn(const MontyInt(42));
      final snapshot = await fake.feedStart('ext()') as FunctionSnapshot;
      expect(snapshot.traceContext(), isNull);
      final result = await snapshot.resume(
        const ExternalReturnValue(MontyInt(42)),
      );
      expect((result as MontyComplete).output, const MontyInt(42));
      expect(snapshot.traceContext, throwsStateError);
      expect(unused.spans, isEmpty);
      expect(unused.logs, isEmpty);
      expect(unused.metrics, isEmpty);
    },
  );
}
