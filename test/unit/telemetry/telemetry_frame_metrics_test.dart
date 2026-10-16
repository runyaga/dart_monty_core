import 'dart:typed_data';

import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry.dart';
import 'package:dart_monty_core/src/worker/telemetry_recorder.dart';
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:test/test.dart';

import 'recording_adapter.dart';

void main() {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  setUp(adapter.clear);
  for (final streamed in [false, true]) {
    test('frame measurements include headers, streamed=$streamed', () async {
      final port = _Port();
      final channel = WorkerConnection.accept(port, (
        ready: true,
        error: null,
        jspi: true,
        protocol: workerProtocolVersion,
        events: null,
        outcome: null,
        trap: null,
        print: null,
        stderr: null,
      ))..recorder = TelemetryRecorder(requireRecord(telemetryBridge), null);
      final request = pb.ParentRequest(feed: pb.Feed(code: '1'));
      final printed = Frame.encode(
        pb.ChildEvent(
          print: pb.Print(
            segments: [
              pb.PrintSegment(
                stream: pb.PrintStream.PRINT_STREAM_STDOUT,
                text: 'é',
              ),
            ],
          ),
        ),
      );
      // Valid noncanonical protobuf: duplicate total_execution_micros field.
      // Re-encoding the decoded event would lose these bytes.
      final completed = Frame.wrap([
        0xa0,
        1,
        1,
        0xa0,
        1,
        2,
        ...pb.ChildEvent(complete: pb.Complete()).writeToBuffer(),
      ]);
      final turn = channel.turn(request);
      if (streamed) {
        channel.onMessage((
          ready: null,
          error: null,
          jspi: null,
          protocol: null,
          events: null,
          outcome: null,
          trap: null,
          print: printed,
          stderr: null,
        ));
      }
      channel.onReply(
        Uint8List.fromList([
          if (!streamed) ...printed,
          ...completed,
        ]),
        outcomeContinue,
      );
      await turn;
      channel.kill();
      final records = measurements(adapter, 'wire.frame.bytes');
      expect(records.map((m) => [m.attributes, m.value]), [
        [
          {'direction': 'sent'},
          requireRecord(port.frames.singleOrNull).length,
        ],
        [
          {'direction': 'received'},
          printed.length,
        ],
        [
          {'direction': 'received'},
          completed.length,
        ],
      ]);
    });
  }
}

final class _Port implements WorkerPort {
  final frames = <Uint8List>[];
  final acknowledgements = <int>[];
  int terminations = 0;

  @override
  void post(Uint8List frame) => frames.add(frame);

  @override
  void acknowledge(int bytes) => acknowledgements.add(bytes);

  @override
  void terminate() => terminations++;
}
