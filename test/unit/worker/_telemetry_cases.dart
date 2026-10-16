// Expectations: upstream 1.1.0 tracing.rs and the recorded telemetry probe.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../telemetry/recording_adapter.dart';

/// Same installed-adapter probes for native and both browser compilers.
void telemetryWorkerTests(
  Future<Monty> Function() start, {
  required bool native,
}) {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  setUp(adapter.clear);
  _lifecycle(start, adapter, native: native);
  _snapshots(start, adapter);
  _callbacks(start, adapter);
}

void _lifecycle(
  Future<Monty> Function() start,
  RecordingAdapter adapter, {
  required bool native,
}) {
  test(
    'telemetry real worker records run print error dump and reset',
    () async {
      final pool = await start();
      addTearDown(pool.close);
      await runZoned(
        () => pool.withSession((session) async {
          expect(
            await session.feedRun(
              'print("hello")\n42',
              printCallback: (stream, text) => expect(text, isNotEmpty),
            ),
            const MontyInt(42),
          );
          await expectLater(
            session.feedRun('1/0'),
            throwsA(isA<MontyRuntimeError>()),
          );
          final state = await session.dump();
          expect(
            adapter.spans.lastOrNull?.attributes['state_bytes'],
            state.length,
          );
        }),
        zoneValues: {#telemetryContext: 'host'},
      );
      final root = requireRecord(adapter.spans.firstOrNull);
      expect(root.parent, 'host');
      expect(root.attributes['monty_version'], '1.1.0');
      expect(root.attributes.containsKey('worker_pid'), native);
      expect(adapter.spans.every((s) => s.end != null), isTrue);
      final run = requireRecord(adapter.spans.elementAtOrNull(1));
      expect(run.attributes['output'], 42);
      expect(run.attributes['total_execution_micros'], isA<int>());
      expect(adapter.logs.map((l) => l.body), [
        'print stdout',
        'error ZeroDivisionError',
      ]);
      final error = requireRecord(adapter.logs.lastOrNull);
      expect(
        error.attributes['exc_type'],
        'ZeroDivisionError',
      );
      expect(error.number, 17);
    },
  );

  test('telemetry worker death closes suspended spans', () async {
    final pool = await start();
    addTearDown(pool.close);
    final session = await pool.checkout();
    await session.feedStart('ext()');
    await pool.close();
    await session.close();
    expect(adapter.spans.map((s) => s.name), [
      'session {script_name}',
      'run code',
      'call {function_name}',
    ]);
    expect(adapter.spans.every((s) => s.end != null), isTrue);
  });
}

void _snapshots(Future<Monty> Function() start, RecordingAdapter adapter) {
  test(
    'telemetry dump/load keeps load parent and logs restored completion',
    () async {
      final pool = await start();
      addTearDown(pool.close);
      final state = await pool.withSession((session) async {
        final call = await session.feedStart('ext(21)') as FunctionSnapshot;
        final state = await call.dump();
        final dump = requireRecord(adapter.spans.lastOrNull);
        expect(dump.name, 'dump');
        expect(
          recordedContext(dump.parent).$2,
          same(adapter.spans.elementAtOrNull(2)),
        );
        expect(dump.attributes['state_bytes'], state.length);

        return state;
      });
      final restored = await pool.checkout();
      addTearDown(restored.close);
      final snapshot =
          await runZoned(
                () => restored.loadSnapshot(state),
                zoneValues: {#telemetryContext: 'load'},
              )
              as FunctionSnapshot;
      final pending = requireRecord(adapter.spans.lastOrNull);
      final spans = adapter.spans;
      final load = requireRecord(spans.elementAtOrNull(spans.length - 2));
      expect(load.name, 'load');
      // tracing.rs context_span checks the retained Load turn before pending.
      expect(snapshot.traceContext(), ('load', load));
      expect(load.attributes['state_bytes'], '${state.length}');
      expect(recordedContext(pending.parent).$2, same(load));
      expect(
        (await snapshot.resume(const ExternalReturnValue(MontyInt(42)))
                as MontyComplete)
            .output,
        const MontyInt(42),
      );
      expect(snapshot.traceContext, throwsStateError);
      final log = requireRecord(adapter.logs.lastOrNull);
      expect(log.body, 'complete');
      expect(log.attributes['output'], 42);
      expect(load.end, isNotNull);
    },
  );

  test(
    'telemetry name lookup and future snapshots carry context until resumed',
    () async {
      final pool = await start();
      addTearDown(pool.close);
      await pool.withSession((session) async {
        final lookup = await session.feedStart('missing') as NameLookupSnapshot;
        expect(
          recordedContext(lookup.traceContext()).$2,
          same(adapter.spans.lastOrNull),
        );
        await lookup.resume(value: const MontyInt(1));
        expect(lookup.traceContext, throwsStateError);
        final call = await session.feedStart('await ext()') as FunctionSnapshot;
        final futures =
            await call.resume(const ExternalFuture()) as FutureSnapshot;
        expect(
          recordedContext(futures.traceContext()).$2,
          same(adapter.spans.lastOrNull),
        );
        await futures.resume({
          call.callId: const ExternalReturnValue(MontyInt(42)),
        });
        expect(futures.traceContext, throwsStateError);
        final log = requireRecord(adapter.logs.lastOrNull);
        expect(log.body, 'future results');
        expect(
          log.attributes['results'],
          '${call.callId}: 42',
        );
      });
    },
  );
}

void _callbacks(Future<Monty> Function() start, RecordingAdapter adapter) {
  test('telemetry callback context survives async continuation', () async {
    final pool = await start();
    addTearDown(pool.close);
    Object? seen;
    await pool.withSession((session) async {
      expect(
        await session.feedRun(
          'ext()',
          externalLookup: {
            'ext': MontyHostFunction('ext', (args, kwargs) async {
              await Future<void>.delayed(Duration.zero);
              seen = Zone.current[#telemetryContext];

              return const MontyInt(42);
            }),
          },
        ),
        const MontyInt(42),
      );
    });
    final span = recordedContext(seen).$2 as RecordedSpan;
    expect(span.name, 'call {function_name}');
    expect(span.attributes['return_value'], 42);
    expect(span.attributes['call_id'], isA<String>());
    expect(span.attributes['sandbox.code.offset.start'], isA<int>());
  });

  test(
    'telemetry OS call uses wire function and argument attributes',
    () async {
      final pool = await start();
      addTearDown(pool.close);
      await pool.withSession((session) async {
        expect(
          await session.feedRun(
            'import os\nos.getenv("A", "fallback")',
            os: (name, args, kwargs) {
              final context = recordedContext(Zone.current[#telemetryContext]);
              expect((context.$2 as RecordedSpan).name, 'os call {function}');

              return const MontyString('answer');
            },
          ),
          const MontyString('answer'),
        );
      });
      final os = requireRecord(adapter.spans.lastOrNull);
      expect(os.attributes['function'], 'getenv');
      expect(os.attributes['args.key'], 'A');
      expect(os.attributes['args.default'], 'fallback');
      expect(os.attributes['return_value'], 'answer');
    },
  );
}
