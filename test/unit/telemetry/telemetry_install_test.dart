import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart' show CrashCause;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/telemetry.dart' show telemetryBridge;
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

  test('span starts retain supplied host details', () {
    final parent = Object();
    final bridge = requireRecord(telemetryBridge);
    final span = requireRecord(
      bridge.start('host request', parent, const {'request.id': 7}),
    );
    final record = span as RecordedSpan;
    expect(record.name, 'host request');
    expect(record.parent, same(parent));
    expect(record.attributes, {'request.id': 7});
  });

  test('span-ignoring adapters receive their opaque token', () {
    adapter.ignoreSpans = true;
    addTearDown(() => adapter.ignoreSpans = false);
    final bridge = requireRecord(telemetryBridge);
    final parent = Object();
    final token = requireRecord(bridge.start('ignored', parent, const {}));
    final context = bridge.contextWithSpan(parent, token);
    bridge
      ..end(token, const {})
      ..log(token, 'INFO', 'ignored span log', const {});
    final contextSpan = requireRecord(adapter.contextSpans.singleOrNull);
    final endedSpan = requireRecord(adapter.endedSpans.singleOrNull);
    final log = requireRecord(adapter.logs.singleOrNull);
    expect(context, same(parent));
    expect((contextSpan, endedSpan, log.span), (token, token, token));
  });

  test('logs retain a supplied span and supported severities', () {
    final bridge = requireRecord(telemetryBridge);
    final span = requireRecord(bridge.start('host request', null, const {}));
    bridge
      ..log(span, 'INFO', 'ready', const {})
      ..log(span, 'ERROR', 'failed', const {});
    expect(
      adapter.logs.map((log) => (log.span, log.severity, log.number)),
      [(span, 'INFO', 9), (span, 'ERROR', 17)],
    );
  });

  test('adapter delivery is synchronous and keeps scalar attributes', () {
    final bridge = requireRecord(telemetryBridge);
    final parent = bridge.currentContext();
    final span = requireRecord(
      bridge.start('host request', parent, const {'request.id': 7}),
    );
    final context = bridge.contextWithSpan(parent, span);
    bridge
      ..end(span, const {'response.ready': true})
      ..log(
        span,
        'ERROR',
        'failed',
        const {'response.duration': 1.5},
      )
      ..recordMetric(
        'host.requests',
        'counter',
        '1',
        'Host requests.',
        1,
        const {'route': '/ready'},
      )
      ..recordMetric(
        'host.requests',
        'counter',
        '1',
        'Host requests.',
        2,
        const {'route': '/ready'},
      );
    var callbackRan = false;
    final result = bridge.invoke(context, () {
      callbackRan = true;

      return 'complete';
    });
    final attributes = [
      for (final record in adapter.spans) ...record.attributes.values,
      for (final record in adapter.logs) ...record.attributes.values,
      for (final record in adapter.measurements) ...record.attributes.values,
    ];
    final recordedSpan = requireRecord(adapter.spans.singleOrNull);
    final recordedLog = requireRecord(adapter.logs.singleOrNull);
    final afterEpoch = greaterThan(BigInt.zero);
    expect(callbackRan, isTrue);
    expect(result, 'complete');
    expect(adapter.methods, [
      'currentContext',
      'startSpan',
      'contextWithSpan',
      'endSpan',
      'emitLog',
      'recordMetric',
      'recordMetric',
      'runInContext',
    ]);
    expect(
      attributes.every(
        (value) =>
            value is String || value is int || value is double || value is bool,
      ),
      isTrue,
    );
    expect(recordedSpan.attributes, {
      'request.id': 7,
      'response.ready': true,
    });
    expect(recordedLog.attributes, {'response.duration': 1.5});
    expect(
      adapter.measurements.map((measurement) => measurement.attributes),
      [
        {'route': '/ready'},
        {'route': '/ready'},
      ],
    );
    expect(
      recordedLog.number,
      17,
    );
    expect(recordedSpan.start, afterEpoch);
    expect(recordedSpan.end, afterEpoch);
    expect(recordedLog.time, afterEpoch);
    expect(adapter.measurements.map((measurement) => measurement.value), [
      1,
      2,
    ]);
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
      final root = requireRecord(spans.firstOrNull);
      final run = requireRecord(spans.lastOrNull);
      expect(root.parent, 'checkout');
      expect(root.attributes['monty_version'], '1.2.0');
      expect(channel.requests.firstOrNull?.configure.montyVersion, '1.2.0');
      expect(run.parent, ('checkout', root));
      expect(run.attributes['code.language'], 'python');
      expect(run.attributes['output'], 'null');
      final log = requireRecord(adapter.logs.singleOrNull);
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
      expect(root.end, greaterThanOrEqualTo(requireRecord(run.end)));
    },
  );

  test('kindless event logs ERROR before protocol teardown', () async {
    final channel = ScriptedChannel([
      answer([ok()]),
      answer([pb.ChildEvent()]),
    ]);
    final session = await ProtoSession.open(channel);
    await expectLater(session.feed('1'), throwsA(isA<MontyCrashedError>()));
    final log = requireRecord(adapter.logs.singleOrNull);
    expect(
      (log.body, log.severity, log.number),
      ('event with no kind', 'ERROR', 17),
    );
    final span = requireRecord(adapter.spans.lastOrNull);
    expect(log.span, same(span));
    expect(
      log.time,
      lessThanOrEqualTo(requireRecord(span.end)),
    );
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
    final span = requireRecord(adapter.spans.singleOrNull);
    expect(span.name, 'session {script_name}');
    expect(span.end, isNotNull);
    expect(adapter.logs.singleOrNull?.body, 'error ValueError');
  });

  test('reset, close, and worker death end their spans', () async {
    Reply accepting(pb.ParentRequest_Kind kind) => expecting(kind, [ok()]);
    final configure = accepting(pb.ParentRequest_Kind.configure);
    final reset = accepting(pb.ParentRequest_Kind.reset);
    final resetChannel = ScriptedChannel([
      configure,
      reset,
      configure,
    ]);
    final resetSession = await ProtoSession.open(resetChannel);
    final beforeReset = requireRecord(adapter.spans.singleOrNull);
    await resetSession.reset();
    expect(beforeReset.end, isNotNull);
    expect(adapter.spans, hasLength(2));
    final afterReset = requireRecord(adapter.spans.lastOrNull);
    await resetSession.close();
    expect(afterReset.end, isNotNull);
    expect(resetChannel.remaining, 0);

    adapter.clear();
    final crashedChannel = ScriptedChannel([
      configure,
      crash(CrashCause.killed, 'worker exited'),
    ]);
    final crashedSession = await ProtoSession.open(crashedChannel);
    await expectLater(
      crashedSession.feed('1'),
      throwsA(isA<MontyCrashedError>()),
    );
    final crashedSpans = adapter.spans;
    expect(crashedSpans.map((span) => span.name), [
      'session {script_name}',
      'run code',
    ]);
    expect(crashedSpans.every((span) => span.end != null), isTrue);
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
      final span = requireRecord(adapter.spans.singleOrNull);
      expect(span.name, 'install dependencies');
      expect(span.attributes['requirements'], '["example"]');
    },
  );

  test(
    'rejected install records the request span at the frame boundary',
    () async {
      final channel = ScriptedChannel([
        answer([ok()]),
        expecting(
          pb.ParentRequest_Kind.installDependencies,
          [raised('RuntimeError', 'rejected')],
        ),
      ]);
      final session = await ProtoSession.open(channel);
      addTearDown(session.close);
      adapter.clear();
      await expectLater(
        session.installDependencies(['example']),
        throwsA(isA<MontyRuntimeError>()),
      );
      final span = requireRecord(adapter.spans.singleOrNull);
      expect(span.name, 'install dependencies');
      expect(
        span.attributes['requirements'],
        '["example"]',
      );
      expect(span.end, isNotNull);
      expect(
        channel.requests.lastOrNull?.whichKind(),
        pb.ParentRequest_Kind.installDependencies,
      );
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
      final span = requireRecord(adapter.spans.lastOrNull);
      expect(captured, ('feed', span));
      expect(span.name, 'call {function_name}');
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
      seen.map((c) => (recordedContext(c).$2 as RecordedSpan).name),
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
