// Demonstrates the download/upload snapshot pattern:
//   1. Run code → snapshot() → Uint8List bytes
//   2. Simulate storage (base64 round-trip)
//   3. Restore bytes in a new session → state and execution continue
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// Simulates serialisation to/from persistent storage via base64.
Uint8List _storageRoundTrip(Uint8List bytes) =>
    base64Decode(base64Encode(bytes));

void main() {
  group('snapshot download/upload', () {
    test('run → download → upload → state and execution survive', () async {
      final montyA = Monty();
      addTearDown(montyA.dispose);

      await montyA.run('x = 10');
      await montyA.run('y = x * 3');
      await montyA.run('label = "result"');

      // "Download" snapshot bytes (save to disk / IndexedDB / server).
      final downloadedBytes = montyA.snapshot();
      expect(downloadedBytes, isNotEmpty);

      // Simulate storage round-trip.
      final uploadedBytes = _storageRoundTrip(downloadedBytes);

      // "Upload" to new session (restore on next app launch).
      final montyB = Monty();
      addTearDown(montyB.dispose);
      montyB.restore(uploadedBytes);

      expect(montyB.state['x'], equals(10));
      expect(montyB.state['y'], equals(30));
      expect(montyB.state['label'], equals('result'));

      // Continue executing from the restored state.
      final result = await montyB.run('y + x');
      expect(result.value, equals(const MontyInt(40)));
    });

    test('snapshot envelope is v1 JSON with dartState key', () {
      final m = Monty();
      addTearDown(m.dispose);
      final envelope =
          jsonDecode(utf8.decode(m.snapshot())) as Map<String, dynamic>;
      expect(envelope['v'], equals(1));
      expect(envelope, contains('dartState'));
    });

    test('invalid bytes throw ArgumentError on restore', () {
      final m = Monty();
      addTearDown(m.dispose);
      expect(
        () => m.restore(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])),
        throwsArgumentError,
      );
    });

    test('session is still usable after failed restore', () async {
      final m = Monty();
      addTearDown(m.dispose);
      expect(
        () => m.restore(Uint8List.fromList([1, 2, 3])),
        throwsArgumentError,
      );
      final result = await m.run('1 + 1');
      expect(result.value, equals(const MontyInt(2)));
    });
  });
}
