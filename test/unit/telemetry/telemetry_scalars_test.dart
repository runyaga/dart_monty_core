// Expectations probed against upstream 1.1.0 with ../oracle-venv:
// .gate-logs/r2-p2-oracle.py and r2-p2-oracle.txt. No Dart rendering in oracle.
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry.dart';
import 'package:dart_monty_core/src/worker/telemetry_attributes.dart';
import 'package:dart_monty_core/src/worker/telemetry_recorder.dart';
import 'package:dart_monty_core/src/worker/telemetry_values.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  setUp(adapter.clear);
  _integers(adapter);
  _timings();
  _floatText(adapter);
}

void _integers(RecordingAdapter adapter) {
  for (final (digits, jsNumber, vmNumber, text) in [
    ('9007199254740991', true, true, '9007199254740991'),
    ('9007199254740992', true, true, '9007199254740992'),
    ('9007199254740993', false, true, '9007199254740993'),
    ('-9007199254740993', false, true, '-9007199254740993'),
    ('9223372036854775807', false, true, '9223372036854775807'),
    ('-9223372036854775808', false, true, '-9223372036854775808'),
    ('9223372036854775808', false, false, '9223372036854775808'),
    ('18446744073709551616', false, false, '18446744073709551616'),
    (
      '340282366920938463463374607431768211456',
      false,
      false,
      '"340282366920938463463374607431768211456"',
    ),
  ]) {
    test('integer $digits stays exact in output, return and lookup', () {
      final arena = pb.Arena(nodes: [bigIntNode(BigInt.parse(digits))]);
      final expected = _integer(text, jsNumber: jsNumber, vmNumber: vmNumber);
      _recordInteger(arena);
      final attributes = adapter.spans.map((span) => span.attributes).toList();
      expect(attributes[1]['output'], expected);
      expect(attributes[2]['return_value'], expected);
      expect(attributes[3]['value'], expected);
      expect(telemetryValue(arena, 0).cut, isFalse);
    });
  }
}

Matcher _integer(String digits, {bool jsNumber = false, bool vmNumber = true}) {
  final numeric = identical(0, 0.0) ? jsNumber : vmNumber;

  return numeric
      ? isA<int>().having((value) => value.toString(), 'exact decimal', digits)
      : equals(digits);
}

void _recordInteger(pb.Arena arena) {
  TelemetryRecorder(requireRecord(telemetryBridge), null)
    ..beginTurn(pb.ParentRequest(configure: pb.Configure()))
    ..beginTurn(pb.ParentRequest(feed: pb.Feed()))
    ..event(pb.ChildEvent(functionCall: pb.FunctionCall(functionName: 'f')))
    ..beginTurn(
      pb.ParentRequest(
        resumeCall: pb.ResumeCall(
          result: pb.ExtFunctionResult(returnValue: 0),
          values: arena,
        ),
      ),
    )
    ..event(pb.ChildEvent(nameLookup: pb.NameLookup(name: 'x')))
    ..beginTurn(
      pb.ParentRequest(
        resumeNameLookup: pb.ResumeNameLookup(value: 0, values: arena),
      ),
    )
    ..event(pb.ChildEvent(complete: pb.Complete(value: 0, values: arena)))
    ..close();
}

void _timings() {
  for (final (digits, signed, jsNumber) in [
    ('9007199254740991', '9007199254740991', true),
    ('9007199254740992', '9007199254740992', true),
    ('9007199254740993', '9007199254740993', false),
    ('9223372036854775807', '9223372036854775807', false),
    ('9223372036854775808', '9223372036854775807', false),
    ('18446744073709551615', '9223372036854775807', false),
  ]) {
    test('u64 $digits keeps unsigned text and saturating i64 timing', () {
      final count = Int64.parseInt(digits);
      final event = pb.ChildEvent(
        totalExecutionMicros: count,
        maxFeedDurationMicros: count,
      );
      expect(eventTiming(event).values.values, everyElement(digits));
      expect(
        eventTiming(event, signed: true).values.values,
        everyElement(_integer(signed, jsNumber: jsNumber)),
      );
      final config = configureAttributes(
        pb.Configure(limits: pb.ResourceLimits(maxMemoryBytes: count)),
        null,
      );
      expect(config.values['max_memory_bytes'], digits);
    });
  }
}

void _floatText(RecordingAdapter adapter) {
  for (final (value, expected) in [
    (1.0, '1'),
    (-0.0, '-0'),
    (1e-7, '0.0000001'),
    (1e16, '10000000000000000'),
    (1.5, '1.5'),
    (double.nan, 'nan'),
    (double.infinity, 'inf'),
    (double.negativeInfinity, '-inf'),
    (123456789.125, '123456789.125'),
    (5e-324, '0.${'0' * 323}5'),
  ]) {
    test('getenv scalar text for $value matches OTel', () {
      final attributes = TelemetryAttributes();
      osAttributes(
        pb.OsCall(
          getenv: pb.OsCall_Getenv(key: 'absent', default_2: 0),
          values: pb.Arena(nodes: [floatNode(value)]),
        ),
        attributes,
      );
      expect(attributes.values['args.default'], expected);
      expect(attributes.values, isNot(contains('length_limit_exceeded')));
    });
    test('future results scalar text for $value matches OTel', () {
      _recordFuture(value);
      expect(adapter.logs.single.attributes, {'results': '7: $expected'});
    });
  }
}

void _recordFuture(double value) {
  TelemetryRecorder(requireRecord(telemetryBridge), null)
    ..beginTurn(
      pb.ParentRequest(
        resumeFutures: pb.ResumeFutures(
          values: pb.Arena(nodes: [floatNode(value)]),
          results: [
            pb.FutureResult(
              callId: 7,
              result: pb.ExtFunctionResult(returnValue: 0),
            ),
          ],
        ),
      ),
    )
    ..close();
}
