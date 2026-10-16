// Real-worker coverage of the host-facing telemetry contract on every backend.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/telemetry/recording_adapter.dart';

/// Exercises the adapter API while Python calls real host objects.
void telemetryAdapterTests(Future<Monty> Function() start) {
  test(
    'host telemetry API preserves context through lazy reads and methods',
    () async {
      final records = RecordingAdapter();
      final MontyTelemetry adapter = records;
      instrumentTelemetry(adapter);
      final pool = await start();
      addTearDown(pool.close);
      final now =
          BigInt.from(DateTime.now().microsecondsSinceEpoch) *
          BigInt.from(1000);
      final outer = adapter.startSpan(
        'host request',
        adapter.currentContext(),
        const {},
        startTimeUnixNanos: now,
      );
      final context = adapter.contextWithSpan('host', outer);
      final seen = <Object?>[];
      final host = HostClass<int>(
        'Counter',
        instance: (
          fields: const {},
          properties: {
            'value': (value) {
              seen.add(adapter.currentContext());

              return MontyInt(value);
            },
          },
          methods: {
            'add': (value, args, kwargs) async {
              await Future<void>.delayed(Duration.zero);
              final current = adapter.currentContext();
              seen.add(current);
              final span = recordedContext(current).$2;
              adapter
                ..emitLog(
                  span,
                  'INFO',
                  'host addition',
                  const {'source': 'host'},
                  timestampUnixNanos: now,
                  severityNumber: 9,
                )
                ..recordMetric(
                  'host.calls',
                  'counter',
                  '1',
                  'Host additions',
                  1,
                  const {},
                  context: null,
                );

              return MontyInt(value + 1);
            },
          },
        ),
      );
      final object = ClassInstance(
        20,
        classType: ClassType(host),
        policies: (
          eagerAttrs: null,
          lazyAttrs: ['value'],
          allowedMethods: ['add'],
        ),
      );
      await adapter.runInContext(
        context,
        () => pool.withSession((session) async {
          expect(
            await session.feedRun(
              'counter.value + await counter.add()',
              inputs: {'counter': object},
            ),
            const MontyInt(41),
          );
          final snapshot = await session.feedStart('ext()') as FunctionSnapshot;
          final captured = recordedContext(snapshot.traceContext());
          expect(captured.$1, context);
          expect(
            (captured.$2 as RecordedSpan).name,
            'call {function_name}',
          );
          expect(
            (await snapshot.resume(const ExternalReturnValue(MontyInt(42)))
                    as MontyComplete)
                .output,
            const MontyInt(42),
          );
          expect(snapshot.traceContext, throwsStateError);
        }),
      );
      adapter.endSpan(outer, const {
        'success': true,
      }, endTimeUnixNanos: now + BigInt.one);
      expect(seen, hasLength(2));
      final callbacks = seen
          .map((value) => recordedContext(value).$2 as RecordedSpan)
          .toList();
      expect(callbacks.map((span) => span.name), [
        'name lookup {name}',
        'call {function_name}',
      ]);
      expect(
        callbacks.map(
          (span) => span.attributes['value'] ?? span.attributes['return_value'],
        ),
        [20, 21],
      );
      expect(records.metrics, [1]);
      final log = requireRecord(records.logs.singleOrNull);
      expect(log.body, 'host addition');
      expect(log.span, same(callbacks.lastOrNull));
      expect(log.attributes, {'source': 'host'});
      expect(records.spans.every((span) => span.end != null), isTrue);
      expect(
        requireRecord(records.spans.firstOrNull).attributes['success'],
        true,
      );
    },
  );
}
