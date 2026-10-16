import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry.dart';
import 'package:dart_monty_core/src/worker/telemetry_channel.dart';
import 'package:dart_monty_core/src/worker/telemetry_recorder.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  setUp(adapter.clear);

  test(
    'suspension strings, offsets, eager futures and completion integers',
    () {
      final answerArena = pb.Arena(nodes: [intNode(42)]);
      TelemetryRecorder(requireRecord(telemetryBridge), 123)
        ..beginTurn(
          pb.ParentRequest(
            configure: pb.Configure(
              montyVersion: '1.1.0',
              limits: pb.ResourceLimits(maxMemoryBytes: Int64(1000)),
            ),
          ),
        )
        ..beginTurn(pb.ParentRequest(feed: pb.Feed(code: 'await ext(2)')))
        ..event(
          pb.ChildEvent(
            totalExecutionMicros: Int64(7),
            functionCall: pb.FunctionCall(
              functionName: 'ext',
              callId: 3,
              allowEagerAwait: true,
              position: pb.SourceRange(filename: 'x.py', start: 6, end: 12),
              args: [0],
              values: pb.Arena(nodes: [intNode(2)]),
            ),
          ),
        )
        ..beginTurn(
          pb.ParentRequest(
            resumeFutures: pb.ResumeFutures(
              values: answerArena,
              results: [
                pb.FutureResult(
                  callId: 3,
                  result: pb.ExtFunctionResult(returnValue: 0),
                ),
              ],
            ),
          ),
        )
        ..event(
          pb.ChildEvent(
            totalExecutionMicros: Int64(9),
            complete: pb.Complete(
              value: 0,
              values: answerArena,
            ),
          ),
        )
        ..close();
      final root = requireRecord(adapter.spans.firstOrNull).attributes;
      final pending = requireRecord(adapter.spans.lastOrNull).attributes;
      expect(root['max_memory_bytes'], '1000');
      expect(root['worker_pid'], 123);
      expect(
        pending,
        containsPair('total_execution_micros', '7'),
      );
      expect(
        pending['sandbox.code.offset.start'],
        6,
      );
      expect(pending['return_value'], 42);
      expect(
        adapter.spans.elementAtOrNull(1)?.attributes['total_execution_micros'],
        9,
      );
      expect(adapter.logs, isEmpty); // Eager single result is a span attribute.
    },
  );

  test('dump error closes only dump; abort answers the pending call', () {
    final recorder = TelemetryRecorder(requireRecord(telemetryBridge), null)
      ..beginTurn(pb.ParentRequest(configure: pb.Configure()))
      ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
      ..event(pb.ChildEvent(nameLookup: pb.NameLookup(name: 'x')));
    final pending = requireRecord(adapter.spans.lastOrNull);
    recorder
      ..beginTurn(pb.ParentRequest(dump: pb.Dump()))
      ..event(
        pb.ChildEvent(
          error: pb.Error(exception: pb.RaisedException(excType: 'ValueError')),
        ),
      );
    expect(adapter.spans.lastOrNull?.end, isNotNull);
    expect(pending.end, isNull);
    recorder.beginTurn(
      pb.ParentRequest(
        abortFeed: pb.AbortFeed(
          exception: pb.RaisedException(
            excType: 'TimeoutError',
            message: 'limit',
          ),
        ),
      ),
    );
    expect(pending.attributes['aborted_with'], 'raise TimeoutError: limit');
    expect(pending.end, isNotNull);
    recorder.close();
  });

  test(
    'typing fatal and unknown-stream logs preserve exact bodies and attributes',
    () {
      final recorder = TelemetryRecorder(requireRecord(telemetryBridge), null)
        ..beginTurn(pb.ParentRequest(configure: pb.Configure()))
        ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
        ..event(
          pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'bad type')),
        )
        ..event(
          pb.ChildEvent(fatalError: pb.FatalError(message: 'fatal')),
        )
        ..event(
          pb.ChildEvent(
            print: pb.Print(segments: [pb.PrintSegment(text: 'x')]),
          ),
        );
      expect(adapter.logs.map((l) => l.body), [
        'typing error',
        'fatal error',
        'print unspecified',
      ]);
      expect(adapter.logs.map((l) => l.number), [17, 17, 9]);
      expect(adapter.logs.lastOrNull?.attributes['stream'], 'unspecified');
      recorder.close();
    },
  );

  test(
    'OS wire attributes include defaults, bytes, unsigned size and timezone',
    () {
      final recorder = TelemetryRecorder(requireRecord(telemetryBridge), null)
        ..beginTurn(pb.ParentRequest(configure: pb.Configure()));
      for (final call in [
        pb.OsCall(mkdir: pb.OsCall_Mkdir(path: '/a')),
        pb.OsCall(
          writeBytes: pb.OsCall_BytesWrite(path: '/b', data: [0, 255]),
        ),
        pb.OsCall(urandom: pb.OsCall_Urandom(size: Int64(12))),
        pb.OsCall(
          dateTimeNow: pb.OsCall_DateTimeNow(
            tz: pb.TimeZone(offsetSeconds: 3600, name: 'X'),
          ),
        ),
      ]) {
        recorder
          ..event(pb.ChildEvent(osCall: call))
          ..beginTurn(
            pb.ParentRequest(
              resumeCall: pb.ResumeCall(
                result: pb.ExtFunctionResult(notHandled: pb.Unit()),
              ),
            ),
          );
      }
      expect(
        adapter.spans.elementAtOrNull(1)?.attributes['args.parents'],
        false,
      );
      expect(
        adapter.spans.elementAtOrNull(2)?.attributes['args.data'],
        r'\x00\xff',
      );
      expect(adapter.spans.elementAtOrNull(3)?.attributes['args.size'], '12');
      expect(
        adapter.spans.elementAtOrNull(4)?.attributes['args.tz_offset_seconds'],
        3600,
      );
      recorder.close();
    },
  );
  test('unsent native request produces no spans or buffered logs', () {
    final recorder = TelemetryRecorder(requireRecord(telemetryBridge), null);
    SentRecording(recorder, pb.ParentRequest(configure: pb.Configure()))
      ..event(pb.ChildEvent(fatalError: pb.FatalError(message: 'early')))
      ..sent(success: false)
      ..finish(dead: true);
    expect(adapter.spans, isEmpty);
    expect(adapter.logs, isEmpty);
  });

  test('death racing native flush closes the eventual span after its logs', () {
    final recorder = TelemetryRecorder(requireRecord(telemetryBridge), null);
    SentRecording(recorder, pb.ParentRequest(configure: pb.Configure()))
      ..event(pb.ChildEvent(fatalError: pb.FatalError(message: 'early')))
      ..finish(dead: true)
      ..sent(success: true);
    final root = requireRecord(adapter.spans.singleOrNull);
    final log = requireRecord(adapter.logs.singleOrNull);
    expect(root.name, 'session {script_name}');
    expect(log.body, 'fatal error');
    expect(log.span, same(root));
    expect(root.end, greaterThanOrEqualTo(log.time));
  });
  test('call keyword arguments and object ids survive into the span', () {
    TelemetryRecorder(requireRecord(telemetryBridge), null)
      ..event(
        pb.ChildEvent(
          functionCall: pb.FunctionCall(
            functionName: 'method',
            objectId: pb.Uuid(data: List.filled(16, 0)),
            kwargs: [pb.NodePair(key: 0, value: 1)],
            values: pb.Arena(
              nodes: [
                pb.MontyNode(str: 'amount'),
                intNode(42),
              ],
            ),
          ),
        ),
      )
      ..close();
    final attributes = requireRecord(adapter.spans.singleOrNull).attributes;
    expect(attributes['object_id'], '00000000-0000-0000-0000-000000000000');
    expect(attributes['kwargs'], '{"amount":42}');
    expect(adapter.spans.every((span) => span.end != null), isTrue);
  });
  test(
    'name lookup failure, absent answer and empty abort close pending spans',
    () {
      final recorder = TelemetryRecorder(requireRecord(telemetryBridge), null);
      for (final (answer, expected) in [
        (
          pb.ResumeNameLookup(error: pb.RaisedException(excType: 'KeyError')),
          'raise KeyError',
        ),
        (pb.ResumeNameLookup(undefined: pb.Unit()), 'undefined'),
        (pb.ResumeNameLookup(), '<missing>'),
      ]) {
        recorder
          ..event(pb.ChildEvent(nameLookup: pb.NameLookup(name: 'missing')))
          ..beginTurn(pb.ParentRequest(resumeNameLookup: answer));
        final span = requireRecord(adapter.spans.lastOrNull);
        expect(span.attributes['value'], expected);
        expect(span.end, isNotNull);
      }
      recorder
        ..event(pb.ChildEvent(nameLookup: pb.NameLookup(name: 'missing')))
        ..beginTurn(pb.ParentRequest(abortFeed: pb.AbortFeed()))
        ..close();
      expect(
        requireRecord(adapter.spans.lastOrNull).attributes['aborted_with'],
        '<missing>',
      );
    },
  );
}
