// The framing codec is the one piece of the worker channel that is compiled by
// EVERY backend — the native channel and the web channel both frame messages
// with it, so it must behave identically on the VM, on dart2js and on
// dart2wasm.
//
// Running it on chrome is not box-ticking. dart2js erases the int/double
// distinction and coerces bitwise operands to 32-bit signed, and this file's
// subject is a 32-bit little-endian length prefix — precisely the shape where a
// VM-green test can be unreachable on the backend carrying the bug. A frame
// whose length is misread by one bit does not fail loudly; it desynchronises
// the stream and the next frame is garbage.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/src/pool/frame_codec.dart';
import 'package:test/test.dart';

/// Splits [bytes] into chunks of [size] to simulate a pipe that does not
/// respect message boundaries.
List<Uint8List> _chunked(Uint8List bytes, int size) => [
  for (var i = 0; i < bytes.length; i += size)
    Uint8List.sublistView(bytes, i, (i + size).clamp(0, bytes.length)),
];

void main() {
  group('encodeFrame', () {
    test('prefixes the payload with its little-endian byte length', () {
      final frame = encodeFrame({'op': 'ping'});
      final body = utf8.encode(json.encode({'op': 'ping'}));

      expect(frame.length, frameHeaderBytes + body.length);
      expect(
        ByteData.sublistView(frame).getUint32(0, Endian.little),
        body.length,
      );
      expect(Uint8List.sublistView(frame, frameHeaderBytes), body);
    });

    test('the length is byte length, not character count', () {
      // The trap this pins: `'é'.length` is 1 in Dart and 2 bytes in UTF-8. A
      // prefix computed from the string rather than the encoded bytes reads
      // short by one for every non-ASCII character, and the reader then treats
      // the tail of one frame as the head of the next.
      final frame = encodeFrame({'v': 'héllo — wörld ✓'});
      final declared = ByteData.sublistView(
        frame,
      ).getUint32(0, Endian.little);

      expect(declared, frame.length - frameHeaderBytes);
      expect(
        declared,
        greaterThan(json.encode({'v': 'héllo — wörld ✓'}).length),
      );
    });

    test('rejects a payload above the cap at the sender', () {
      // Asserted at the boundary rather than by building a 64 MiB map, which
      // would make this test cost more than it proves.
      expect(maxFrameBytes, 64 * 1024 * 1024);
      expect(
        () => encodeFrame({'v': 'x' * (maxFrameBytes + 1)}),
        throwsA(isA<FrameFormatException>()),
      );
    });
  });

  group('FrameReader', () {
    test('returns null until a whole frame has arrived', () {
      final whole = encodeFrame({'a': 1});
      final reader = FrameReader()..add(whole.sublist(0, 3));
      final afterPartialHeader = reader.next();

      reader.add(whole.sublist(3, whole.length - 1));
      final afterPartialBody = reader.next();

      reader.add(whole.sublist(whole.length - 1));
      final complete = reader.next();
      final afterDrain = reader.next();

      expect(afterPartialHeader, isNull, reason: 'header incomplete');
      expect(afterPartialBody, isNull, reason: 'body incomplete');
      expect(complete, {'a': 1});
      expect(afterDrain, isNull);
    });

    test('reassembles frames split at every possible boundary', () {
      // The failure this catches is order-dependent: a reader that happens to
      // work when each write arrives whole can still corrupt the stream when
      // the pipe splits a length prefix across two reads. One chunk size is not
      // a test of that; every chunk size is.
      final payloads = [
        {'op': 'ping', 'id': 1},
        {'op': 'feedRun', 'code': '2 + 2', 'id': 2},
        {'op': 'result', 'value': 'MontyInt(4)', 'id': 3},
      ];
      final stream = Uint8List.fromList([
        for (final p in payloads) ...encodeFrame(p),
      ]);

      for (var size = 1; size <= stream.length; size++) {
        final reader = FrameReader();
        final seen = <Map<String, Object?>>[];
        for (final chunk in _chunked(stream, size)) {
          reader.add(chunk);
          for (var f = reader.next(); f != null; f = reader.next()) {
            seen.add(f);
          }
        }

        expect(seen, payloads, reason: 'failed at chunk size $size');
        expect(reader.pendingBytes, 0, reason: 'trailing bytes at size $size');
      }
    });

    test('coalesces several frames delivered in one chunk', () {
      final reader = FrameReader()
        ..add(
          Uint8List.fromList([
            ...encodeFrame({'id': 1}),
            ...encodeFrame({'id': 2}),
          ]),
        );

      final first = reader.next();
      final second = reader.next();
      final drained = reader.next();

      expect(first, {'id': 1});
      expect(second, {'id': 2});
      expect(drained, isNull);
    });

    test('round-trips a payload larger than any single chunk', () {
      // Exercises a multi-KiB length, i.e. a prefix that uses more than the low
      // byte. A codec that wrote only one byte of the length would pass every
      // small-frame test above and fail here.
      final big = {'code': 'x' * 100000};
      final reader = FrameReader();
      _chunked(encodeFrame(big), 4096).forEach(reader.add);

      expect(reader.next(), big);
    });

    test('a length prefix above the cap is fatal, not resynchronised', () {
      // The prefix comes off a pipe, so a corrupt one must stop the channel
      // rather than send the reader hunting for the next plausible frame — a
      // hunt an attacker controls the outcome of.
      final poisoned = Uint8List(frameHeaderBytes + 4);
      ByteData.sublistView(poisoned).setUint32(0, 0xFFFFFFFF, Endian.little);

      expect(
        () => (FrameReader()..add(poisoned)).next(),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('a 32-bit length is read unsigned', () {
      // dart2js coerces bitwise operands to 32-bit SIGNED. A length of
      // 0x80000000 read as signed is negative, and a negative length silently
      // becomes "not enough bytes yet" — the channel would hang rather than
      // fail. This asserts the cap rejects it, which it can only do if the
      // value was read as a large positive number.
      final poisoned = Uint8List(frameHeaderBytes);
      ByteData.sublistView(poisoned).setUint32(0, 0x80000000, Endian.little);

      expect(
        () => (FrameReader()..add(poisoned)).next(),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('a non-object payload is a framing error', () {
      final reader = FrameReader();
      final body = utf8.encode('[1,2,3]');
      final frame = Uint8List(frameHeaderBytes + body.length);
      ByteData.sublistView(frame).setUint32(0, body.length, Endian.little);
      frame.setRange(frameHeaderBytes, frame.length, body);

      expect(
        () => (reader..add(frame)).next(),
        throwsA(isA<FrameFormatException>()),
      );
    });
  });

  group('indexOfFrameMagic', () {
    test('finds the marker after arbitrary preamble noise', () {
      // The real preamble this models, measured 2026-08-16:
      // `dart run` writes "Running build hooks..." to the CHILD'S stdout
      // before the child's own `main()` executes.
      final buffer = <int>[
        ...utf8.encode('Running build hooks...Running build hooks...'),
        ...frameStreamMagic,
        ...encodeFrame({'type': 'ready'}),
      ];

      final at = indexOfFrameMagic(buffer);
      expect(at, 44);

      final reader = FrameReader()
        ..add(buffer.sublist(at + frameStreamMagic.length));
      expect(reader.next(), {'type': 'ready'});
    });

    test('returns -1 when the marker is absent or only partly present', () {
      expect(indexOfFrameMagic(utf8.encode('no marker here')), -1);
      expect(indexOfFrameMagic(const []), -1);
      expect(
        indexOfFrameMagic(frameStreamMagic.sublist(0, 5)),
        -1,
        reason: 'a prefix of the marker is not the marker',
      );
    });

    test('finds a marker at the very start and at the very end', () {
      expect(indexOfFrameMagic(frameStreamMagic), 0);
      expect(
        indexOfFrameMagic([0, 1, 2, ...frameStreamMagic]),
        3,
      );
    });

    test('does not match on a false start', () {
      // A run of bytes that begins like the marker and then diverges must not
      // consume it — the `continue outer` in the scan is what makes the real
      // marker still findable afterwards.
      final buffer = [
        ...frameStreamMagic.sublist(0, frameStreamMagic.length - 1),
        0x21,
        ...frameStreamMagic,
      ];

      expect(indexOfFrameMagic(buffer), frameStreamMagic.length);
    });
  });
}
