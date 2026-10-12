/// monty-proto framing: a 4-byte unsigned little-endian length prefix, then
/// that many bytes of protobuf.
///
/// Mirrors upstream `crates/monty-proto/src/frame.rs` at the pinned tag,
/// including `MAX_FRAME_LEN` and the two stream failures its `FrameReader`
/// distinguishes: a length prefix over the maximum, and EOF inside a frame.
/// Pure Dart, shared by every channel: a process pipe delivers arbitrary
/// chunks ([FrameDecoder]); the wasm worker returns one buffered turn
/// ([Frame.split]).
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:protobuf/protobuf.dart';

/// Whole-frame operations: encode a message, prefix a body, split a reply.
abstract final class Frame {
  /// Upstream's `MAX_FRAME_LEN` (256 MiB): the largest body a frame may carry.
  static const int maxLength = 256 * 1024 * 1024;

  /// Bytes in the little-endian length prefix.
  static const int prefixLength = 4;

  /// Encodes [message] as one frame: prefix and body in a single buffer.
  ///
  /// Throws [FrameTooLargeException] if the body exceeds [Frame.maxLength],
  /// before anything is sent, so the stream stays in sync.
  static Uint8List encode(GeneratedMessage message) =>
      wrap(message.writeToBuffer());

  /// Prefixes [body] with its length: [encode] for bytes already encoded.
  ///
  /// Throws [FrameTooLargeException] if [body] exceeds [limit].
  static Uint8List wrap(List<int> body, {int limit = maxLength}) {
    if (body.length > limit) {
      throw FrameTooLargeException(body.length, limit);
    }
    final out = Uint8List(prefixLength + body.length);
    ByteData.sublistView(out).setUint32(0, body.length, Endian.little);
    out.setRange(prefixLength, out.length, body);

    return out;
  }

  /// Splits one buffered reply holding whole frames into their bodies.
  ///
  /// Throws [FrameTruncatedException] if the reply ends inside a frame and
  /// [FrameTooLargeException] on a prefix over [Frame.maxLength].
  static List<Uint8List> split(Uint8List bytes) {
    final decoder = FrameDecoder();
    final frames = decoder.add(bytes);
    decoder.close();

    return frames;
  }
}

/// A failure that leaves the byte stream unusable: the next byte can no longer
/// be trusted to start a frame.
sealed class FrameException implements Exception {
  const FrameException();
}

/// A length prefix, or a body about to be sent, exceeds the maximum.
///
/// Upstream's `FrameError::FrameTooLarge`.
final class FrameTooLargeException extends FrameException {
  /// Creates the error for a frame of [length] bytes against [max].
  const FrameTooLargeException(this.length, this.max);

  /// The length the prefix claimed, or the size of the body to send.
  final int length;

  /// The maximum in force.
  final int max;

  @override
  String toString() =>
      'FrameTooLargeException: frame of $length bytes exceeds maximum of '
      '$max bytes';
}

/// The stream ended inside a frame: the peer died while writing.
///
/// Upstream's `FrameError::Truncated`.
final class FrameTruncatedException extends FrameException {
  /// Creates the error for a stream that ended [pendingBytes] into a frame.
  const FrameTruncatedException(this.pendingBytes);

  /// Bytes of the unfinished frame received before the end, prefix included.
  final int pendingBytes;

  @override
  String toString() =>
      'FrameTruncatedException: stream ended mid-frame, $pendingBytes '
      'bytes into it';
}

/// Incremental decoder: chunks with arbitrary boundaries in, whole frame
/// bodies out.
///
/// Each chunk is copied on [add], so a caller may reuse its buffer. A body
/// that arrives across many chunks is assembled once, when its last byte
/// arrives, not re-copied per chunk. Nothing is allocated from a length
/// prefix alone, so a bogus prefix under the maximum costs no memory until
/// its bytes actually arrive.
///
/// The first [FrameException] is final: the stream is desynchronised, and
/// every later [add] or [close] throws the same error.
final class FrameDecoder {
  /// Creates a decoder that rejects bodies longer than [maxLength].
  FrameDecoder({this.maxLength = Frame.maxLength});

  /// The largest body this decoder accepts. Upstream's `max_frame_len`.
  final int maxLength;

  final _parts = ListQueue<Uint8List>();
  int _buffered = 0;
  int? _bodyLength;
  FrameException? _failure;

  /// Bytes received of a frame not yet complete, prefix included.
  ///
  /// Zero means the stream is at a frame boundary.
  int get pendingBytes =>
      _buffered + (_bodyLength == null ? 0 : Frame.prefixLength);

  /// Feeds [chunk] and returns every frame body it completes, in order.
  ///
  /// An empty frame yields an empty body, which decodes to the default
  /// message. Throws [FrameTooLargeException] on a prefix over [maxLength].
  List<Uint8List> add(List<int> chunk) {
    final failure = _failure;
    if (failure != null) throw failure;
    if (chunk.isNotEmpty) {
      _parts.add(Uint8List.fromList(chunk));
      _buffered += chunk.length;
    }
    final frames = <Uint8List>[];
    for (;;) {
      final length = _bodyLength ?? _readPrefix();
      if (length == null || _buffered < length) break;
      frames.add(_take(length));
      _bodyLength = null;
    }

    return frames;
  }

  /// Ends the stream. A clean end is one at a frame boundary.
  ///
  /// Throws [FrameTruncatedException] if a frame was left unfinished.
  void close() {
    final failure = _failure;
    if (failure != null) throw failure;
    final pending = pendingBytes;
    if (pending != 0) _fail(FrameTruncatedException(pending));
  }

  /// Consumes a length prefix if four bytes are buffered; null otherwise.
  int? _readPrefix() {
    if (_buffered < Frame.prefixLength) return null;
    final length = ByteData.sublistView(
      _take(Frame.prefixLength),
    ).getUint32(0, Endian.little);
    if (length > maxLength) {
      _fail(FrameTooLargeException(length, maxLength));
    }
    _bodyLength = length;

    return length;
  }

  /// Records [failure] as final and throws it.
  Never _fail(FrameException failure) {
    _failure = failure;
    throw failure;
  }

  /// Removes the first [count] buffered bytes, which must all be present.
  Uint8List _take(int count) {
    _buffered -= count;
    final head = _parts.firstOrNull;
    if (head == null || count == 0) return Uint8List(0);
    if (head.length >= count) {
      _dropFront(head, count);

      return Uint8List.sublistView(head, 0, count);
    }
    final out = Uint8List(count);
    var filled = 0;
    for (Uint8List? part = head; filled < count; part = _parts.firstOrNull) {
      // Never null: _buffered counted every byte asked for.
      if (part == null) break;
      final n = part.length < count - filled ? part.length : count - filled;
      out.setRange(filled, filled + n, part);
      filled += n;
      _dropFront(part, n);
    }

    return out;
  }

  /// Drops [n] bytes from the front of [part], the first buffered chunk.
  void _dropFront(Uint8List part, int n) {
    _parts.removeFirst();
    if (n < part.length) _parts.addFirst(Uint8List.sublistView(part, n));
  }
}
