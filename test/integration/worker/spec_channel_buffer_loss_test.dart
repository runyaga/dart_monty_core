@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

void main() {
  test('REQ-print-delivery-48: crash loses a buffered partial line', () async {
    final channel = await ProcessChannel.spawn(await locateWorker());
    addTearDown(channel.close);
    final configured = await channel.turn(
      pb.ParentRequest(
        configure: pb.Configure(
          scriptName: 'buffer.py',
          protocolVersion: workerProtocolVersion,
          printFlushIntervalMs: 0,
          limits: pb.ResourceLimits(
            maxMemoryBytes: Int64(512 * 1024 * 1024),
            maxRecursionDepth: Int64(100000000),
          ),
        ),
      ),
    );
    expect(configured.whichKind(), pb.ChildEvent_Kind.ok);
    final texts = <String>[];
    void capture(pb.Print event) {
      texts.addAll(event.segments.map((segment) => segment.text));
    }

    // A normal turn flushes an otherwise identical partial line.
    final complete = await channel.turn(
      _feed("print('kept', end='')"),
      onPrint: capture,
    );
    expect(complete.whichKind(), pb.ChildEvent_Kind.complete);
    expect(texts, ['kept']);
    // Equality overflows the native stack only after print has executed.
    // No host suspension, completed line, or turn end can flush 'lost'.
    await expectLater(
      channel.turn(
        _feed(
          'x = []\nfor i in range(300000):\n    x = [x]\n'
          'y = []\nfor i in range(300000):\n    y = [y]\n'
          "print('lost', end='')\nx == y",
        ),
        onPrint: capture,
      ),
      throwsA(
        isA<MontyCrashedError>().having(
          (error) => error.cause,
          'cause',
          CrashCause.vanished,
        ),
      ),
    );
    expect(texts, ['kept']);
    expect(channel.isAlive, isFalse);
  });
}

pb.ParentRequest _feed(String code) => pb.ParentRequest(
  feed: pb.Feed(code: code, cwd: '/'),
);
