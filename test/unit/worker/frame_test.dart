// Framing (lib/src/worker/frame.dart) against upstream frame.rs's rules: a
// 4-byte little-endian length prefix, MAX_FRAME_LEN, and EOF inside a frame as
// an error distinct from EOF at a boundary. Pure Dart, so it runs on the VM,
// dart2js and dart2wasm through the unit and unit_web steps.
import 'dart:typed_data';

import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:protobuf/protobuf.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

final Matcher _truncated = throwsA(isA<FrameTruncatedException>());
final Matcher _tooLarge = throwsA(isA<FrameTooLargeException>());

/// Three frames: a Feed, an empty frame, and a body big enough to span many
/// chunks (and to need a two-byte prefix).
List<Uint8List> _bodies() => [
  pb.ParentRequest(feed: pb.Feed(code: 'x = 1\nx + 1')).writeToBuffer(),
  Uint8List(0),
  Uint8List.fromList(List.generate(70000, (i) => i * 7 % 256)),
];

Uint8List _stream(List<Uint8List> bodies) =>
    Uint8List.fromList([for (final b in bodies) ...Frame.wrap(b)]);

/// Feeds [bytes] in chunks of [size] and collects every body.
List<Uint8List> _decodeInChunks(Uint8List bytes, int size) {
  final decoder = FrameDecoder();
  final out = <Uint8List>[];
  for (var i = 0; i < bytes.length; i += size) {
    final end = i + size < bytes.length ? i + size : bytes.length;
    out.addAll(decoder.add(Uint8List.sublistView(bytes, i, end)));
  }
  decoder.close();

  return out;
}

void main() {
  group('encode', () {
    test('a frame is the body length, little-endian, then the body', () {
      final req = pb.ParentRequest(feed: pb.Feed(code: '1 + 1'));
      final body = req.writeToBuffer();
      final frame = Frame.encode(req);
      expect(frame.length, body.length + 4);
      expect(
        ByteData.sublistView(frame).getUint32(0, Endian.little),
        body.length,
      );
      expect(frame.sublist(4), body);
    });

    test('the prefix is little-endian past one byte', () {
      expect(Frame.wrap(Uint8List(0x010203)).sublist(0, 4), [3, 2, 1, 0]);
    });

    test('a body over the maximum is refused before anything is framed', () {
      expect(
        () => Frame.wrap(Uint8List(17), limit: 16),
        throwsA(
          isA<FrameTooLargeException>()
              .having((e) => e.length, 'length', 17)
              .having((e) => e.max, 'max', 16),
        ),
      );
      expect(Frame.wrap(Uint8List(16), limit: 16).length, 20);
    });
  });

  // Upstream checks the encoded length before it allocates the frame
  // (monty-proto frame.rs:116-143), so an oversized request costs nothing
  // and leaves the stream in sync.
  group('outbound size, checked before encoding', () {
    test('a message of exactly the limit encodes; one byte more does not', () {
      final request = pb.ParentRequest(feed: pb.Feed(code: 'x' * 300));
      final length = request.writeToBuffer().length;
      expect(Frame.encode(request, limit: length).length, length + 4);
      expect(
        () => Frame.encode(request, limit: length - 1),
        throwsA(
          isA<FrameTooLargeException>()
              .having((e) => e.length, 'length', length)
              .having((e) => e.max, 'max', length - 1),
        ),
      );
    });

    test('an oversized request is refused without being written', () {
      // 300 MiB when written, from one MiB shared by every node.
      final node = pb.MontyNode(str: 'x' * (1 << 20));
      final spy = _WriteSpy();
      final request = pb.ParentRequest(
        feed: pb.Feed(values: pb.Arena(nodes: List.filled(300, node))),
      )..unknownFields.mergeGroupField(99, spy);
      expect(() => Frame.encode(request), _tooLarge);
      expect(spy.written, isFalse);
    });

    test('the refusal names the encoded length and the maximum', () {
      // 2^33 bytes and more when written: no platform could build it.
      final node = pb.MontyNode(str: 'x' * (1 << 20));
      final request = pb.ParentRequest(
        feed: pb.Feed(values: pb.Arena(nodes: List.filled(8192, node))),
      );
      const arena = ((1 << 20) + 8) * 8192;
      const feed = arena + 6;
      expect(
        () => Frame.encode(request),
        throwsA(
          isA<FrameTooLargeException>()
              .having((e) => e.length, 'length', feed + 6)
              .having((e) => e.max, 'max', Frame.maxLength),
        ),
      );
    });

    test('the body is written once, straight after the prefix', () {
      final spy = _WriteSpy();
      final request = pb.ParentRequest(feed: pb.Feed(code: 'x = 1'))
        ..unknownFields.mergeGroupField(99, spy);
      final frame = Frame.encode(request);
      expect(spy.written, isTrue);
      expect(frame.sublist(4), request.writeToBuffer());
    });
  });

  group('empty frame', () {
    test('a default message encodes as a zero-length frame', () {
      expect(Frame.encode(pb.ParentRequest()), [0, 0, 0, 0]);
      expect(Frame.wrap(const []), [0, 0, 0, 0]);
    });

    test('decodes to one empty body, which is the default message', () {
      final decoder = FrameDecoder();
      final frames = decoder.add([0, 0, 0, 0]);
      expect(frames, hasLength(1));
      expect(onlyItem(frames), isEmpty);
      expect(decoder.pendingBytes, 0);
      expect(
        pb.ParentRequest.fromBuffer(onlyItem(frames)).whichKind(),
        pb.ParentRequest_Kind.notSet,
      );
      decoder.close();
    });

    test('consecutive empty frames are each reported', () {
      expect(Frame.split(Uint8List(12)), [isEmpty, isEmpty, isEmpty]);
    });

    test('an empty chunk changes nothing', () {
      final decoder = FrameDecoder();
      expect(decoder.add(const []), isEmpty);
      expect(decoder.add([5, 0]), isEmpty);
      expect(decoder.add(const []), isEmpty);
      expect(decoder.pendingBytes, 2);
    });
  });

  group('chunk splits', () {
    test('every two-chunk split yields the same frames', () {
      // Small bodies so all split points are cheap: one inside each prefix,
      // one inside each body, and each boundary.
      final bodies = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List(0),
        Uint8List.fromList([9]),
      ];
      final bytes = _stream(bodies);
      for (var cut = 0; cut <= bytes.length; cut++) {
        final decoder = FrameDecoder();
        final out = [
          ...decoder.add(Uint8List.sublistView(bytes, 0, cut)),
          ...decoder.add(Uint8List.sublistView(bytes, cut)),
        ];
        decoder.close();
        expect(out, bodies, reason: 'split at $cut');
      }
    });

    for (final size in [1, 3, 4, 5, 4096, 65536, 1 << 20]) {
      test('chunks of $size bytes', () {
        expect(_decodeInChunks(_stream(_bodies()), size), _bodies());
      });
    }

    test('a frame completes on the chunk that carries its last byte', () {
      final decoder = FrameDecoder();
      final frame = Frame.wrap([10, 20, 30]);
      expect(decoder.add(frame.sublist(0, 2)), isEmpty);
      expect(decoder.inFlightLength, 2, reason: 'prefix not yet read');
      expect(decoder.add(frame.sublist(2, 6)), isEmpty);
      expect(decoder.pendingBytes, 6);
      expect(decoder.inFlightLength, 7, reason: 'prefix and whole body');
      expect(decoder.add(frame.sublist(6)), [
        [10, 20, 30],
      ]);
      expect(decoder.pendingBytes, 0);
      expect(decoder.inFlightLength, 0);
    });

    test('a decoded message survives a one-byte-at-a-time stream', () {
      final req = pb.ParentRequest(
        feed: pb.Feed(code: 'print("hi")\n1 + 1'),
      );
      final frames = _decodeInChunks(Frame.encode(req), 1);
      expect(pb.ParentRequest.fromBuffer(onlyItem(frames)), req);
    });

    test('the caller may reuse a chunk buffer after add', () {
      final decoder = FrameDecoder();
      final chunk = Uint8List.fromList(Frame.wrap([7, 8, 9]).sublist(0, 6));
      expect(decoder.add(chunk), isEmpty);
      chunk.fillRange(0, chunk.length, 0xEE);
      expect(decoder.add([9]), [
        [7, 8, 9],
      ]);
    });

    test('a frame held whole in one chunk is unaffected by the next', () {
      final decoder = FrameDecoder();
      final first = decoder.add([
        ...Frame.wrap([1, 2]),
        3,
        0,
      ]);
      expect(first, [
        [1, 2],
      ]);
      decoder.add([0, 0, 4, 5, 6]);
      expect(onlyItem(first), [1, 2]);
    });
  });

  group('torn frame', () {
    test('a stream ending inside a prefix is truncated', () {
      final decoder = FrameDecoder()..add([3, 0]);
      expect(
        decoder.close,
        throwsA(
          isA<FrameTruncatedException>().having(
            (e) => e.pendingBytes,
            'pendingBytes',
            2,
          ),
        ),
      );
    });

    test('a stream ending inside a body is truncated', () {
      final torn = FrameDecoder()..add(Frame.wrap([1, 2, 3, 4]).sublist(0, 6));
      expect(
        torn.close,
        throwsA(
          isA<FrameTruncatedException>().having(
            (e) => e.pendingBytes,
            'pendingBytes',
            6,
          ),
        ),
      );
    });

    test('a stream ending right after a prefix is truncated', () {
      // Upstream: "EOF after a length prefix is always mid-frame".
      final decoder = FrameDecoder()..add([1, 0, 0, 0]);
      expect(decoder.pendingBytes, 4);
      expect(decoder.close, _truncated);
    });

    test('a stream ending at a boundary closes cleanly', () {
      final decoder = FrameDecoder()..add(_stream(_bodies()));
      expect(decoder.pendingBytes, 0);
      decoder.close();
      FrameDecoder().close();
    });

    test('Frame.split refuses a buffered reply that ends mid-frame', () {
      final reply = _stream(_bodies());
      expect(
        () => Frame.split(Uint8List.sublistView(reply, 0, reply.length - 1)),
        _truncated,
      );
      expect(Frame.split(reply), _bodies());
    });

    test('truncation is final', () {
      final decoder = FrameDecoder()..add([9]);
      expect(decoder.close, _truncated);
      expect(
        () => decoder.add([0, 0, 0]),
        _truncated,
      );
      expect(decoder.close, _truncated);
    });

    test('the message names the byte count', () {
      expect(
        const FrameTruncatedException(6).toString(),
        'FrameTruncatedException: stream ended mid-frame, 6 bytes into it',
      );
    });
  });

  group('oversize length prefix', () {
    test('an all-ones prefix is refused, not allocated', () {
      expect(
        () => FrameDecoder().add([0xFF, 0xFF, 0xFF, 0xFF]),
        throwsA(
          isA<FrameTooLargeException>()
              .having((e) => e.length, 'length', 0xFFFFFFFF)
              .having((e) => e.max, 'max', Frame.maxLength),
        ),
      );
    });

    test('MAX_FRAME_LEN is accepted and one more byte is not', () {
      expect(Frame.maxLength, 256 * 1024 * 1024);
      final atMax = FrameDecoder();
      final prefix = ByteData(4)..setUint32(0, Frame.maxLength, Endian.little);
      expect(atMax.add(prefix.buffer.asUint8List()), isEmpty);
      expect(atMax.pendingBytes, 4);

      prefix.setUint32(0, Frame.maxLength + 1, Endian.little);
      expect(
        () => FrameDecoder().add(prefix.buffer.asUint8List()),
        throwsA(
          isA<FrameTooLargeException>().having(
            (e) => e.length,
            'length',
            Frame.maxLength + 1,
          ),
        ),
      );
    });

    test('a prefix after good frames still fails, after they are lost', () {
      // The frames in the same chunk are not returned: once the stream is
      // desynchronised the channel is dead, as upstream's reader errors out.
      final decoder = FrameDecoder(maxLength: 8);
      expect(
        () => decoder.add([
          ...Frame.wrap([1]),
          9,
          0,
          0,
          0,
        ]),
        _tooLarge,
      );
    });

    test('the refusal is final', () {
      final decoder = FrameDecoder(maxLength: 8);
      expect(
        () => decoder.add([9, 0, 0, 0]),
        _tooLarge,
      );
      expect(
        () => decoder.add(Frame.wrap([1])),
        _tooLarge,
      );
      expect(decoder.close, _tooLarge);
    });

    test('Frame.split refuses an oversize prefix', () {
      expect(
        () => Frame.split(Uint8List.fromList([0xFF, 0xFF, 0xFF, 0x7F])),
        _tooLarge,
      );
    });

    test('the message names both sizes', () {
      expect(
        const FrameTooLargeException(9, 8).toString(),
        'FrameTooLargeException: frame of 9 bytes exceeds maximum of 8 bytes',
      );
    });
  });
}

/// An unknown group, carried by a request, that records whether the request
/// was ever serialised.
final class _WriteSpy extends UnknownFieldSet {
  bool written = false;

  @override
  void writeToCodedBufferWriter(CodedBufferWriter output) {
    written = true;
    super.writeToCodedBufferWriter(output);
  }
}
