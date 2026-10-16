// Malformed raw worker frames through the native subprocess boundary.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

// A peer that reads Configure and Feed, then sends a complete result with
// DateTime.timezone_name containing 0xff. Handwritten protobuf bytes keep
// the malformed UTF-8 intact; a generated String would repair it.
const _peer = '''
import struct, sys
def receive():
    size = struct.unpack('<I', sys.stdin.buffer.read(4))[0]
    sys.stdin.buffer.read(size)
def send(body):
    sys.stdout.buffer.write(struct.pack('<I', len(body)) + body)
    sys.stdout.buffer.flush()
receive()
send(bytes([0x52, 0]))
receive()
# ChildEvent.complete -> Complete.values -> Arena.nodes -> datetime.
date = bytes([0x08, 0xea, 0x0f, 0x10, 1, 0x18, 1, 0x40, 0, 0x4a, 1, 0xff])
node = bytes([0x9a, 1, len(date)]) + date
arena = bytes([8, 1, 0x12, len(node)]) + node
complete = bytes([0x12, len(arena)]) + arena
send(bytes([0x32, len(complete)]) + complete)
sys.stdin.buffer.read()
''';

Future<String?> _python() async {
  for (final command
      in Platform.isWindows ? ['python', 'python3'] : ['python3', 'python']) {
    try {
      if ((await Process.run(command, ['-c', 'import sys'])).exitCode == 0) {
        return command;
      }
    } on ProcessException {
      // Try the other conventional command name.
    }
  }

  return null;
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'malformed timezone UTF-8 discards the worker and session',
    () async {
      final python = await _python();
      if (python == null) {
        return markTestSkipped('Python is not available on PATH');
      }
      final channel = await ProcessChannel.spawn(
        WorkerExecutable(python, args: const ['-u', '-c', _peer]),
      );
      addTearDown(channel.close);
      final pool = await startMonty(
        const PoolOptions(
          minProcesses: 0,
          maxProcesses: 1,
          requestTimeout: Duration(seconds: 5),
        ),
        open: () => PendingSpawn((_) async => channel),
      );
      addTearDown(pool.close);
      final session = await pool.checkout();
      addTearDown(session.close);
      await expectLater(
        session.feedRun('result'),
        throwsA(
          protoCrash(
            'invalid payload from worker: failed to decode Protobuf message: '
            'DateTime.timezone_name: MontyNode.kind: '
            'Complete.values: ChildEvent.kind: '
            'invalid string value: data is not UTF-8 encoded',
          ),
        ),
      );
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
    },
  );
}
