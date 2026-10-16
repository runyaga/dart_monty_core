import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:dart_monty_core/src/worker/frame.dart'
    show FrameTooLargeException;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';

import '../worker/_scripted_channel.dart';
import 'recording_adapter.dart';

void main() {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  setUp(adapter.clear);

  test('installation is irreversible', () {
    expect(
      () => instrumentTelemetry(adapter),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Monty telemetry is already configured',
        ),
      ),
    );
  });

  test(
    'installed adapter records configure feed print close and parentage',
    () async {
      final channel = ScriptedChannel([
        answer([ok()]),
        answer([
          printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'hello\n')]),
          completeNone(),
        ]),
      ]);
      final session = await runZoned(
        () => ProtoSession.open(channel),
        zoneValues: {#telemetryContext: 'checkout'},
      );
      await session.feed('print("hello")');
      await session.close();
      final spans = adapter.spans;
      expect(spans.map((s) => s.name), ['session {script_name}', 'run code']);
      final root = spans.first;
      final run = spans.last;
      expect(root.parent, 'checkout');
      expect(root.attributes['monty_version'], '1.1.0');
      expect(channel.requests.first.configure.montyVersion, '1.1.0');
      expect(run.parent, ('checkout', root));
      expect(run.attributes['code.language'], 'python');
      expect(run.attributes['output'], 'null');
      final log = adapter.logs.single;
      expect(
        (log.body, log.severity, log.number),
        ('print stdout', 'INFO', 9),
      );
      expect(log.attributes, {'stream': 'stdout', 'text': 'hello\n'});
      expect(log.span, same(run));
      final epoch = BigInt.from(1700000000) * BigInt.from(1000000000);
      expect(root.start, greaterThan(epoch));
      expect(log.time, greaterThanOrEqualTo(run.start));
      expect(run.end, greaterThanOrEqualTo(log.time));
      expect(root.end, greaterThanOrEqualTo(run.end!));
    },
  );

  test('kindless event logs ERROR before protocol teardown', () async {
    final channel = ScriptedChannel([
      answer([ok()]),
      answer([pb.ChildEvent()]),
    ]);
    final session = await ProtoSession.open(channel);
    await expectLater(session.feed('1'), throwsA(isA<MontyCrashedError>()));
    final log = adapter.logs.single;
    expect(
      (log.body, log.severity, log.number),
      ('event with no kind', 'ERROR', 17),
    );
    expect(log.span, same(adapter.spans.last));
    expect(log.time, lessThanOrEqualTo(adapter.spans.last.end!));
  });

  test('checkout rejected before Configure creates no session span', () async {
    final channel = ScriptedChannel([], frameLimit: 1);
    await expectLater(
      ProtoSession.open(channel),
      throwsA(isA<FrameTooLargeException>()),
    );
    expect(channel.requests, isEmpty);
    expect(adapter.spans, isEmpty);
  });

  test('worker rejected Configure still records a session span', () async {
    final channel = ScriptedChannel([
      answer([raised('ValueError', 'bad config')]),
    ]);
    await expectLater(
      ProtoSession.open(channel),
      throwsA(isA<MontyRuntimeError>()),
    );
    expect(adapter.spans.single.name, 'session {script_name}');
    expect(adapter.spans.single.end, isNotNull);
    expect(adapter.logs.single.body, 'error ValueError');
  });

  test(
    'empty install sends nothing; nonempty install records its span',
    () async {
      final fake = FakeMontySession();
      addTearDown(fake.close);
      fake.willReturn(const MontyInt(7));
      expect(await fake.feedRun('7'), const MontyInt(7));
      adapter.clear();
      await fake.installDependencies([]);
      expect(adapter.spans, isEmpty);
      expect(adapter.logs, isEmpty);
      await expectLater(
        fake.installDependencies(['example']),
        throwsA(isA<MontyRuntimeError>()),
      );
      expect(adapter.spans.single.name, 'install dependencies');
      expect(adapter.spans.single.attributes['requirements'], '["example"]');
    },
  );

  test(
    'snapshot captures feed context across zones and rejects after resume',
    () async {
      final fake = FakeMontySession();
      addTearDown(fake.close);
      fake
        ..willCall('ext')
        ..willReturn(const MontyInt(42));
      final snapshot =
          await runZoned(
                () => fake.feedStart('ext()'),
                zoneValues: {#telemetryContext: 'feed'},
              )
              as FunctionSnapshot;
      final captured = runZoned(
        snapshot.traceContext,
        zoneValues: {#telemetryContext: 'reader'},
      );
      expect(captured, ('feed', adapter.spans.last));
      expect(adapter.spans.last.name, 'call {function_name}');
      await snapshot.resume(const ExternalReturnValue(MontyInt(42)));
      expect(snapshot.traceContext, throwsStateError);
    },
  );

  test('host and OS callbacks run under their suspension span', () async {
    final fake = FakeMontySession();
    addTearDown(fake.close);
    fake
      ..willCall('ext')
      ..willCallOs('os.getenv', args: const [MontyString('A'), MontyNone()])
      ..willReturn(const MontyInt(42));
    final seen = <Object?>[];
    await fake.feedRun(
      'ext()',
      externalLookup: {
        'ext': MontyHostFunction('ext', (args, kwargs) {
          seen.add(Zone.current[#telemetryContext]);
          return const MontyInt(42);
        }),
      },
      os: (name, args, kwargs) {
        seen.add(Zone.current[#telemetryContext]);
        return const MontyNone();
      },
    );
    expect(seen, hasLength(2));
    expect(
      seen.map((c) => ((c! as (Object?, Object)).$2 as RecordedSpan).name),
      ['call {function_name}', 'os call {function}'],
    );
  });
  test('logs-only adapter snapshots retain the feed entry context', () async {
    adapter.ignoreSpans = true;
    addTearDown(() => adapter.ignoreSpans = false);
    final fake = FakeMontySession()..willLookUp('missing');
    addTearDown(fake.close);
    fake.willReturn(const MontyInt(7));
    final snapshot =
        await runZoned(
              () => fake.feedStart('missing'),
              zoneValues: {#telemetryContext: 'entry'},
            )
            as NameLookupSnapshot;
    expect(
      runZoned(
        snapshot.traceContext,
        zoneValues: {#telemetryContext: 'reader'},
      ),
      'entry',
    );
    await snapshot.resume(value: const MontyInt(7));
    expect(adapter.spans, isEmpty);
    expect(snapshot.traceContext, throwsStateError);
    // Close while the no-span adapter still owns this session's handles.
    await fake.close();
  });
}
