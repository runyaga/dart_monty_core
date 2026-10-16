@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '../../unit/worker/_spec_channel_support.dart';

const int _miB = 1024 * 1024;

void main() {
  for (final scenario in ['minimum', 'queued', 'in-flight']) {
    test(
      'REQ-print-delivery-24: $scenario drain raises the threshold once',
      () {
        final clock = SpecChannelClock();
        clock.run(() {
          final pipe = StreamController<List<int>>(sync: true);
          final queue = EventQueue(
            pipe.stream,
            limit: ProcessChannel.readAheadLimit,
            drainAllowance: ProcessChannel.drainAllowance,
            onDesync: () => fail('valid fixture frames must decode'),
          );
          final firstSize = scenario == 'queued' ? _miB * 6 : _miB * 3;
          final first = _frame(firstSize);
          pipe.add(first);
          final partial = scenario == 'in-flight' ? _frame(_miB * 6) : <int>[];
          if (partial.isNotEmpty) pipe.add(partial.sublist(0, 8));
          unawaited(queue.endWithin(const Duration(seconds: 1)));
          clock.flush();
          _paused(pipe, false);
          if (partial.isNotEmpty) pipe.add(partial.sublist(8));
          // max(4 MiB, queued + complete size of in-flight frame) + 1 MiB.
          final expectedBound = switch (scenario) {
            'queued' => _miB * 7,
            'in-flight' => _miB * 10,
            _ => _miB * 5,
          };
          final received = first.length + partial.length;
          final filler = _frame(expectedBound - received - 1);
          pipe.add(filler);
          _paused(pipe, false);
          final crossing = _frame(64);
          pipe.add(crossing);
          _paused(pipe, true);
          // A second drain must not grant another MiB.
          unawaited(queue.endWithin(const Duration(seconds: 1)));
          clock.flush();
          _paused(pipe, true);
          clock.elapse(const Duration(milliseconds: 999));
          _listening(pipe, true);
          clock.elapse(const Duration(milliseconds: 1));
          _listening(pipe, false);
          // Expiry keeps every complete frame but stops accepting new ones.
          pipe.add(_frame(128));
          final sizes = <int>[];
          unawaited(_read(queue, sizes));
          clock.flush();
          expect(sizes, [
            first.length,
            if (partial.isNotEmpty) partial.length,
            filler.length,
            crossing.length,
          ]);
          queue.cancel();
          unawaited(pipe.close());
          clock.flush();
        });
      },
    );
  }
}

Future<void> _read(EventQueue queue, List<int> sizes) async {
  for (;;) {
    final event = await queue.next();
    if (event == null) return;
    sizes.add(Frame.encode(event).length);
  }
}

List<int> _frame(int wireBytes) {
  var textBytes = wireBytes - 21;
  for (;;) {
    final frame = Frame.encode(
      pb.ChildEvent(
        print: pb.Print(
          segments: [
            pb.PrintSegment(
              stream: pb.PrintStream.PRINT_STREAM_STDOUT,
              text: 'x' * textBytes,
            ),
          ],
        ),
      ),
    );
    if (frame.length == wireBytes) return frame;
    textBytes += wireBytes - frame.length;
  }
}

void _paused(StreamController<List<int>> pipe, bool expected) {
  expect(pipe.isPaused, expected);
}

void _listening(StreamController<List<int>> pipe, bool expected) {
  expect(pipe.hasListener, expected);
}
