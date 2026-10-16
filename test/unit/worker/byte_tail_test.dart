import 'dart:async';

import 'package:dart_monty_core/src/worker/byte_tail.dart';
import 'package:test/test.dart';

void main() {
  test('whole old chunks are dropped and the final chunk is trimmed', () async {
    final bytes = StreamController<List<int>>();
    final tail = ByteTail(bytes.stream, 4);
    bytes
      ..add([65, 66, 67, 68])
      ..add([69, 70, 71])
      ..add([72, 73, 74]);
    await bytes.close();
    await tail.drain(const Duration(seconds: 1));
    expect(tail.text, 'GHIJ');
  });
  test(
    'stream failure ends draining and keeps the diagnostic already read',
    () async {
      final bytes = StreamController<List<int>>();
      final tail = ByteTail(bytes.stream, 4);
      bytes
        ..add([32, 65, 66, 32])
        ..addError(StateError('pipe closed'));
      await tail.drain(const Duration(seconds: 1));
      await bytes.close();
      expect(tail.text, 'AB');
    },
  );
  test(
    'a cap cutting a UTF-8 character is represented by a replacement',
    () async {
      final bytes = StreamController<List<int>>();
      final tail = ByteTail(bytes.stream, 2);
      bytes.add([0xc3, 0xa9, 65]);
      await bytes.close();
      await tail.drain(const Duration(seconds: 1));
      expect(tail.text, '\uFFFDA');
    },
  );
}
