// Expected attribute names and encodings are the upstream tracing.rs contract.
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry_attributes.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

void main() {
  test('configuration retains every optional limit as an unsigned string', () {
    final attributes = configureAttributes(
      pb.Configure(
        typeCheck: true,
        typeCheckStubs: 'stubs',
        limits: pb.ResourceLimits(
          maxFeedDurationMicros: Int64(1),
          maxTurnDurationMicros: Int64(2),
          maxMemoryBytes: Int64(3),
          gcInterval: Int64(4),
          maxRecursionDepth: Int64(5),
          maxSuspensions: Int64(-1),
        ),
      ),
      null,
    ).values;
    expect(attributes, containsPair('type_check_stubs', 'stubs'));
    expect(attributes, containsPair('type_check', true));
    expect(attributes, containsPair('max_feed_duration_micros', '1'));
    expect(attributes, containsPair('max_turn_duration_micros', '2'));
    expect(attributes, containsPair('max_memory_bytes', '3'));
    expect(attributes, containsPair('gc_interval', '4'));
    expect(attributes, containsPair('max_recursion_depth', '5'));
    expect(attributes, containsPair('max_suspensions', '18446744073709551615'));
    expect(attributes, isNot(contains('worker_pid')));
  });
  test('timing uses unsigned creation and saturating signed end values', () {
    final event = pb.ChildEvent(
      totalExecutionMicros: Int64(-1),
      maxFeedDurationMicros: Int64(7),
    );
    expect(eventTiming(event).values, {
      'total_execution_micros': '18446744073709551615',
      'max_feed_duration_micros': '7',
    });
    expect(eventTiming(event, signed: true).values, {
      'total_execution_micros': identical(0, 0.0)
          ? '9223372036854775807'
          : int.parse('9223372036854775807'),
      'max_feed_duration_micros': 7,
    });
  });
  test('missing and optional OS arguments remain distinguishable', () {
    final missing = TelemetryAttributes();
    osAttributes(pb.OsCall(), missing);
    expect(missing.values, {'call_id': '0', 'function': '<missing>'});
    final local = TelemetryAttributes();
    osAttributes(pb.OsCall(dateTimeNow: pb.OsCall_DateTimeNow()), local);
    expect(local.values, {'call_id': '0', 'function': 'date_time_now'});
    final path = TelemetryAttributes();
    osAttributes(pb.OsCall(readText: '/tmp/example'), path);
    expect(path.values['args.path'], '/tmp/example');
  });
  test(
    'unicode errors preserve bytes, strings, offsets and missing objects',
    () {
      for (final (data, expected) in [
        (pb.UnicodeErrorData(objectBytes: [0, 255]), r'\x00\xff'),
        (pb.UnicodeErrorData(objectStr: 'é'), 'é'),
        (pb.UnicodeErrorData(), '<missing>'),
      ]) {
        data
          ..encoding = 'utf-8'
          ..reason = 'invalid'
          ..start = Int64(1)
          ..end = Int64(2);
        final attributes = errorAttributes(
          pb.ChildEvent(
            error: pb.Error(
              exception: pb.RaisedException(
                excType: 'UnicodeError',
                data: pb.ExcData(unicode: data),
              ),
            ),
          ),
        ).values;
        expect(attributes, containsPair('exc_data.object', expected));
        expect(attributes, containsPair('exc_data.encoding', 'utf-8'));
        expect(attributes, containsPair('exc_data.reason', 'invalid'));
        expect(attributes, containsPair('exc_data.start', '1'));
        expect(attributes, containsPair('exc_data.end', '2'));
      }
    },
  );
  test('JSON exceptions preserve optional diagnostic fields', () {
    final attributes = errorAttributes(
      pb.ChildEvent(
        error: pb.Error(
          exception: pb.RaisedException(
            excType: 'JSONDecodeError',
            data: pb.ExcData(
              json: pb.JsonErrorData(
                msg: 'bad',
                doc: '{',
                pos: Int64(1),
                lineno: Int64(2),
                colno: Int64(3),
              ),
            ),
          ),
        ),
      ),
    ).values;
    expect(attributes, containsPair('exc_data.msg', 'bad'));
    expect(attributes, containsPair('exc_data.doc', '{'));
    expect(attributes, containsPair('exc_data.pos', '1'));
    expect(attributes, containsPair('exc_data.lineno', '2'));
    expect(attributes, containsPair('exc_data.colno', '3'));
    final empty = errorAttributes(
      pb.ChildEvent(
        error: pb.Error(
          exception: pb.RaisedException(
            data: pb.ExcData(json: pb.JsonErrorData(msg: 'bad')),
          ),
        ),
      ),
    );
    expect(empty.values.keys.where((key) => key.startsWith('exc_data.')), [
      'exc_data.msg',
    ]);
  });
}
