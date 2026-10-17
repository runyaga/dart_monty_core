// Expectations: upstream 1.1.0 telemetry/metrics.rs, not Dart implementation.
import 'dart:async';

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry.dart';
import 'package:dart_monty_core/src/worker/telemetry_metrics.dart';
import 'package:dart_monty_core/src/worker/telemetry_recorder.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  setUp(adapter.clear);
  printCases(adapter);
  runCases(adapter);
  suspensionCases(adapter);
  housekeepingCases(adapter);
  answerCases(adapter);
  unsignedClockCase(adapter);
  instrumentCases(adapter);
}

TelemetryRecorder recorder() =>
    TelemetryRecorder(requireRecord(telemetryBridge), null);

void printCases(RecordingAdapter adapter) {
  test('metric delivery is immediate, raw, and context-free', () {
    requireRecord(telemetryBridge)
      ..recordMetric(
        'first',
        'counter',
        '1',
        'First raw measurement.',
        1,
        const {},
      )
      ..recordMetric(
        'first',
        'counter',
        '1',
        'First raw measurement.',
        2,
        const {},
      );
    expect(
      adapter.measurements.map((metric) => (metric.value, metric.context)),
      [(1, null), (2, null)],
    );
  });

  test('print bytes are exact UTF-8 totals per stream per event', () {
    runZoned(() {
      recorder()
        ..event(
          pb.ChildEvent(
            print: pb.Print(
              segments: [
                pb.PrintSegment(
                  stream: pb.PrintStream.PRINT_STREAM_STDOUT,
                  text: 'é',
                ),
                pb.PrintSegment(
                  stream: pb.PrintStream.PRINT_STREAM_STDERR,
                  text: '🙂',
                ),
                pb.PrintSegment(
                  stream: pb.PrintStream.PRINT_STREAM_STDOUT,
                  text: '\n',
                ),
                pb.PrintSegment(text: '?'),
              ],
            ),
          ),
        )
        ..close();
    }, zoneValues: {#telemetryContext: 'ambient host span'});
    final records = measurements(adapter, 'print.bytes');
    expect(records.map((m) => [m.attributes, m.value]), [
      [
        {'stream': 'stdout'},
        3,
      ],
      [
        {'stream': 'stderr'},
        4,
      ],
      [
        {'stream': 'unspecified'},
        1,
      ],
    ]);
    expect(records.every((m) => m.context == null), isTrue);
    expect(records.map((m) => (m.kind, m.unit, m.description)).toSet(), {
      ('counter', 'By', 'Bytes the sandbox printed, by stream.'),
    });
  });
}

void runCases(RecordingAdapter adapter) {
  test(
    'execution time uses monotonic cumulative deltas and configure resets',
    () {
      final subject = recorder();
      for (final total in [100, 250, 200, 300]) {
        subject
          ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
          ..event(
            pb.ChildEvent(
              complete: pb.Complete(),
              totalExecutionMicros: Int64(total),
            ),
          );
      }
      subject
        ..beginTurn(pb.ParentRequest(configure: pb.Configure()))
        ..event(pb.ChildEvent(ok: pb.Ok()))
        ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
        ..event(
          pb.ChildEvent(
            complete: pb.Complete(),
            totalExecutionMicros: Int64(10),
          ),
        )
        ..close();
      expect(measurements(adapter, 'run.execution_time').map((m) => m.value), [
        0.0001,
        0.00015,
        0.0,
        0.00005,
        0.00001,
      ]);
      expect(
        measurements(adapter, 'run.duration').map((m) => m.attributes),
        List.filled(5, {'outcome': 'complete'}),
      );
    },
  );
  for (final (event, outcome) in [
    (pb.ChildEvent(error: pb.Error()), 'error'),
    (pb.ChildEvent(typingError: pb.TypingError()), 'typing_error'),
    (pb.ChildEvent(fatalError: pb.FatalError()), 'fatal_error'),
    (pb.ChildEvent(shutdown: pb.ShutdownDump()), 'shutdown'),
  ]) {
    test('run ends with $outcome', () {
      recorder()
        ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
        ..event(event)
        ..close();
      expect(measurements(adapter, 'run.duration').map((m) => m.attributes), [
        {'outcome': outcome},
      ]);
      expect(measurements(adapter, 'run.execution_time'), hasLength(1));
    });
  }
}

void suspensionCases(RecordingAdapter adapter) {
  for (final (event, kind) in [
    (
      pb.ChildEvent(functionCall: pb.FunctionCall(functionName: 'unbounded')),
      'function',
    ),
    (pb.ChildEvent(osCall: pb.OsCall(readText: '/unbounded')), 'os'),
    (
      pb.ChildEvent(nameLookup: pb.NameLookup(name: 'unbounded')),
      'name_lookup',
    ),
    (pb.ChildEvent(resolveFutures: pb.ResolveFutures()), 'futures'),
  ]) {
    test('$kind suspension balances and records host answer', () {
      recorder()
        ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
        ..event(event)
        ..beginTurn(pb.ParentRequest(abortFeed: pb.AbortFeed()))
        ..close();
      expect(
        measurements(
          adapter,
          'run.suspensions',
        ).map((m) => [m.value, m.attributes]),
        [
          [
            1,
            {'kind': kind},
          ],
        ],
      );
      expect(
        measurements(adapter, 'pool.workers.suspended').map((m) => m.value),
        [1, -1],
      );
      expect(
        measurements(adapter, 'ext.call.duration').map((m) => m.attributes),
        [
          {
            'kind': kind,
            'outcome': 'aborted',
            if (kind == 'os') 'function': 'read_text',
          },
        ],
      );
    });
  }
  test('abandoning a suspension balances without charging a host answer', () {
    recorder()
      ..event(pb.ChildEvent(nameLookup: pb.NameLookup()))
      ..close()
      ..close();
    expect(
      measurements(adapter, 'pool.workers.suspended').map((m) => m.value),
      [1, -1],
    );
    expect(measurements(adapter, 'ext.call.duration'), isEmpty);
  });
}

void housekeepingCases(RecordingAdapter adapter) {
  test('restored suspension rebases execution and ends load before resume', () {
    recorder()
      ..beginTurn(pb.ParentRequest(load: pb.Load(state: [1, 2, 3])))
      ..event(
        pb.ChildEvent(
          nameLookup: pb.NameLookup(),
          totalExecutionMicros: Int64(10000000),
        ),
      )
      ..beginTurn(
        pb.ParentRequest(
          resumeNameLookup: pb.ResumeNameLookup(undefined: pb.Unit()),
        ),
      )
      ..event(
        pb.ChildEvent(
          complete: pb.Complete(),
          totalExecutionMicros: Int64(10000050),
        ),
      )
      ..close();
    expect(measurements(adapter, 'turn.duration').map((m) => m.attributes), [
      {'turn': 'load', 'outcome': 'ok'},
    ]);
    expect(measurements(adapter, 'run.execution_time').map((m) => m.value), [
      0.00005,
    ]);
    expect(measurements(adapter, 'run.duration'), isEmpty);
    expect(measurements(adapter, 'snapshot.bytes'), isEmpty);
  });
  test('dump size is actual bytes and leaves the suspended run open', () {
    final subject = recorder()
      ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
      ..event(pb.ChildEvent(nameLookup: pb.NameLookup()));
    for (final size in [7, 137]) {
      subject
        ..beginTurn(pb.ParentRequest(dump: pb.Dump()))
        ..event(
          pb.ChildEvent(dumpResult: pb.DumpResult(state: List.filled(size, 0))),
        );
    }
    expect(
      measurements(
        adapter,
        'snapshot.bytes',
      ).map((m) => [m.value, m.attributes]),
      [
        [
          7,
          {'op': 'dump'},
        ],
        [
          137,
          {'op': 'dump'},
        ],
      ],
    );
    expect(measurements(adapter, 'run.duration'), isEmpty);
    expect(
      measurements(adapter, 'pool.workers.suspended').map((m) => m.value),
      [1],
    );
    subject.close();
  });
  test('housekeeping error never synthesizes an execution sample', () {
    recorder()
      ..beginTurn(
        pb.ParentRequest(
          installDependencies: pb.InstallDependencies(requirements: ['x']),
        ),
      )
      ..event(pb.ChildEvent(error: pb.Error()))
      ..close();
    expect(measurements(adapter, 'turn.duration').map((m) => m.attributes), [
      {'turn': 'install_dependencies', 'outcome': 'error'},
    ]);
    expect(measurements(adapter, 'run.execution_time'), isEmpty);
  });
}

void answerCases(RecordingAdapter adapter) {
  for (final (answer, outcome) in [
    (pb.ExtFunctionResult(returnValue: 0), 'value'),
    (pb.ExtFunctionResult(error: pb.RaisedException()), 'error'),
    (pb.ExtFunctionResult(future: 7), 'future'),
    (pb.ExtFunctionResult(notFound: 'sandbox chosen'), 'not_found'),
    (pb.ExtFunctionResult(notHandled: pb.Unit()), 'not_handled'),
    (pb.ExtFunctionResult(), 'missing'),
  ]) {
    for (final eager in [false, true]) {
      test('call answer $outcome eager=$eager', () {
        final call = pb.ChildEvent(
          functionCall: pb.FunctionCall(
            functionName: 'unbounded',
            callId: 7,
            allowEagerAwait: eager,
          ),
        );
        final request = eager
            ? pb.ParentRequest(
                resumeFutures: pb.ResumeFutures(
                  results: [pb.FutureResult(callId: 7, result: answer)],
                ),
              )
            : pb.ParentRequest(resumeCall: pb.ResumeCall(result: answer));
        recorder()
          ..event(call)
          ..beginTurn(request)
          ..close();
        expect(
          measurements(adapter, 'ext.call.duration').map((m) => m.attributes),
          [
            {'kind': 'function', 'outcome': outcome},
          ],
        );
      });
    }
  }
  test('unmatched eager future result uses resolved outcome', () {
    recorder()
      ..event(
        pb.ChildEvent(
          functionCall: pb.FunctionCall(callId: 7, allowEagerAwait: true),
        ),
      )
      ..beginTurn(
        pb.ParentRequest(
          resumeFutures: pb.ResumeFutures(
            results: [
              pb.FutureResult(
                callId: 8,
                result: pb.ExtFunctionResult(returnValue: 0),
              ),
            ],
          ),
        ),
      )
      ..close();
    expect(
      measurements(adapter, 'ext.call.duration').map((m) => m.attributes),
      [
        {'kind': 'function', 'outcome': 'resolved'},
      ],
    );
  });
}

void unsignedClockCase(RecordingAdapter adapter) {
  test(
    'execution delta preserves unsigned clocks across the signed boundary',
    () {
      recorder()
        ..beginTurn(pb.ParentRequest(load: pb.Load()))
        ..event(
          pb.ChildEvent(
            ok: pb.Ok(),
            totalExecutionMicros: Int64.parseHex('7fffffffffffffff'),
          ),
        )
        ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
        ..event(
          pb.ChildEvent(
            complete: pb.Complete(),
            totalExecutionMicros: Int64.parseHex('8000000000000000'),
          ),
        )
        ..close();
      expect(measurements(adapter, 'run.execution_time').map((m) => m.value), [
        0.000001,
      ]);
    },
  );
}

void instrumentCases(RecordingAdapter adapter) {
  test('every metric uses an empty context', () {
    final ambientContext = Object();
    runZoned(
      () {
        for (final metric in TelemetryMetrics.values) {
          metric.record(metric.unit == 's' ? 0.5 : 1);
        }
      },
      zoneValues: {#telemetryContext: ambientContext},
    );

    expect(adapter.measurements, hasLength(TelemetryMetrics.values.length));
    expect(
      adapter.measurements.map((measurement) => measurement.context),
      everyElement(isNull),
    );
  });

  test('instrument schemas retain scalar categories', () {
    final expected = {
      'monty.pool.workers.live': ('up_down_counter', '{worker}'),
      'monty.pool.workers.idle': ('up_down_counter', '{worker}'),
      'monty.pool.workers.suspended': ('up_down_counter', '{worker}'),
      'monty.pool.checkout.wait': ('histogram', 's'),
      'monty.pool.worker.terminated': ('counter', '{worker}'),
      'monty.pool.session.duration': ('histogram', 's'),
      'monty.run.duration': ('histogram', 's'),
      'monty.run.execution_time': ('histogram', 's'),
      'monty.turn.duration': ('histogram', 's'),
      'monty.run.suspensions': ('counter', '{suspension}'),
      'monty.ext.call.duration': ('histogram', 's'),
      'monty.snapshot.bytes': ('histogram', 'By'),
      'monty.print.bytes': ('counter', 'By'),
      'monty.wire.frame.bytes': ('histogram', 'By'),
    };
    expect(
      {
        for (final metric in TelemetryMetrics.values)
          metric.name: (metric.kind, metric.unit),
      },
      expected,
    );

    for (final metric in TelemetryMetrics.values) {
      metric.record(metric.unit == 's' ? 0.5 : 1);
    }
    expect(adapter.measurements, hasLength(TelemetryMetrics.values.length));
    expect(
      adapter.measurements
          .where((measurement) => measurement.unit == 's')
          .every((measurement) => measurement.value is double),
      isTrue,
    );
    expect(
      adapter.measurements
          .where((measurement) => measurement.unit != 's')
          .every((measurement) => measurement.value is int),
      isTrue,
    );
  });

  test('recorder attributes retain upstream metric labels', () {
    recorder()
      ..event(
        pb.ChildEvent(
          print: pb.Print(
            segments: [
              pb.PrintSegment(
                stream: pb.PrintStream.PRINT_STREAM_STDOUT,
                text: 'x',
              ),
            ],
          ),
        ),
      )
      ..close();
    final printBytes = requireRecord(
      measurements(adapter, 'print.bytes').singleOrNull,
    );
    expect(printBytes.attributes, {
      'stream': 'stdout',
    });

    adapter.clear();
    recorder()
      ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
      ..event(pb.ChildEvent(osCall: pb.OsCall(readText: '/tmp/input')))
      ..beginTurn(pb.ParentRequest(abortFeed: pb.AbortFeed()))
      ..close();
    final suspensions = requireRecord(
      measurements(adapter, 'run.suspensions').singleOrNull,
    );
    final call = requireRecord(
      measurements(adapter, 'ext.call.duration').singleOrNull,
    );
    expect(suspensions.attributes, {
      'kind': 'os',
    });
    expect(call.attributes, {
      'kind': 'os',
      'function': 'read_text',
      'outcome': 'aborted',
    });

    adapter.clear();
    recorder()
      ..beginTurn(pb.ParentRequest(configure: pb.Configure()))
      ..event(pb.ChildEvent(ok: pb.Ok()))
      ..close();
    final turn = requireRecord(
      measurements(adapter, 'turn.duration').singleOrNull,
    );
    expect(turn.attributes, {
      'turn': 'configure',
      'outcome': 'ok',
    });

    adapter.clear();
    recorder()
      ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
      ..event(pb.ChildEvent(nameLookup: pb.NameLookup()))
      ..beginTurn(pb.ParentRequest(dump: pb.Dump()))
      ..event(pb.ChildEvent(dumpResult: pb.DumpResult(state: [1])))
      ..close();
    final snapshot = requireRecord(
      measurements(adapter, 'snapshot.bytes').singleOrNull,
    );
    expect(snapshot.attributes, {
      'op': 'dump',
    });

    adapter.clear();
    TelemetryMetrics.terminated.attribute(1, 'reason', 'closed');
    TelemetryMetrics.frame.attribute(1, 'direction', 'sent');
    expect(
      measurements(adapter, 'pool.worker.terminated').singleOrNull?.attributes,
      {
        'reason': 'closed',
      },
    );
    expect(measurements(adapter, 'wire.frame.bytes').singleOrNull?.attributes, {
      'direction': 'sent',
    });
  });
}
