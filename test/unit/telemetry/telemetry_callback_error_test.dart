import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  final adapter = RecordingAdapter();
  final diagnostics = <String>[];
  setUpAll(
    () => runZoned(
      () => instrumentTelemetry(adapter),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => diagnostics.add(line),
      ),
    ),
  );
  setUp(() {
    adapter.clear();
    diagnostics.clear();
  });

  test(
    'callback wrapper records one entry and preserves its error',
    () async {
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
      expect(adapter.contexts, hasLength(1));
      expect(
        adapter.spans.lastOrNull?.attributes['return_value'],
        'raise ValueError: callback',
      );
      fake.willReturn(const MontyInt(7));
      expect(await fake.feedRun('7'), const MontyInt(7));
      expect(adapter.spans.where((s) => s.name == 'run code'), hasLength(2));
    },
  );

  test('callback errors do not disable telemetry', () async {
    final fake = FakeMontySession();
    addTearDown(fake.close);
    var calls = 0;
    fake
      ..willCall('ext')
      ..willCatch()
      ..willReturn(const MontyInt(42));
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
    expect(
      fake.answers.singleOrNull?.answer,
      const ExternalException('ValueError', 'callback'),
    );
    fake
      ..willCall('ext')
      ..willReturn(const MontyInt(7));
    expect(
      await fake.feedRun(
        'ext()',
        externalLookup: {
          'ext': MontyHostFunction(
            'ext',
            (args, kwargs) {
              calls++;

              return const MontyInt(7);
            },
          ),
        },
      ),
      const MontyInt(7),
    );
    expect(calls, 2);
    expect(adapter.contexts, hasLength(2));
    expect(diagnostics, isEmpty);
  });
}
