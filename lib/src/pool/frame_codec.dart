/// Length-prefixed JSON framing for the out-of-process worker channel.
///
/// The parent and the worker are separate OS processes joined by a pipe, so
/// they need a way to find message boundaries in a byte stream. This is that,
/// and nothing more: a 4-byte little-endian unsigned length followed by that
/// many bytes of UTF-8 JSON.
///
/// **This is transport framing, not the value wire.** `WIRE_FORMAT_VERSION`
/// (`native/src/convert.rs:50`, v4) versions what the *interpreter* encoder
/// emits and its decoder accepts. Values still cross the FFI boundary in that
/// encoding, unchanged, inside the worker — this framing only decides where
/// one host↔worker message ends and the next begins. The two are independent
/// and must not be conflated: bumping one says nothing about the other.
///
/// Lives in `lib/` rather than `bin/` because the worker
/// (`bin/monty_worker.dart`) and the parent-side handle are in different
/// directories and Dart has no other way for both to import one copy. It is
/// deliberately free of `dart:io` so
/// `lib/` keeps its zero-`dart:io` property, which the web compilers rely on.
/// It is not exported from `dart_monty_core.dart` — internal machinery.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Bytes of the fixed-size length prefix.
const int frameHeaderBytes = 4;

/// Marks where framing begins in the worker's stdout.
///
/// **This is not decoration; the dev spawn path does not work without it.**
/// Measured 2026-08-16: `dart run <script>` writes `Running build hooks...`
/// to the CHILD'S STDOUT before the child's `main()` executes —
///
/// ```text
/// $ dart run bin/monty_worker.dart | xxd | head -3
/// 00000000: 5275 6e6e 696e 6720 6275 696c 6420 686f  Running build ho
/// 00000010: 6f6b 732e 2e2e 5275 6e6e 696e 6720 6275  oks...Running bu
/// 00000020: 696c 6420 686f 6f6b 732e 2e2e 3200 0000  ild hooks...2...
/// ```
///
/// — so a parent that starts reading length prefixes at byte 0 reads
/// `"Runn"` as a 1,852,796,754-byte frame. The child cannot suppress this: it
/// is emitted by the SDK before any of the child's code runs.
///
/// The parent therefore discards everything up to and including this marker,
/// ONCE, at handshake. After that the stream is exact and a bad length prefix
/// is a fatal protocol error, never a cue to hunt for the next plausible
/// frame — see [FrameFormatException].
final List<int> frameStreamMagic = List<int>.unmodifiable(
  '\n--MONTY-FRAMES--\n'.codeUnits,
);

/// Largest frame this codec will accept, in bytes.
///
/// A cap is not optional. The length prefix arrives from the far end of a
/// pipe, so an uncapped reader lets a corrupt or hostile 4-byte header ask the
/// parent to buffer up to 4 GiB before it can notice anything is wrong. 64 MiB
/// is far above any plausible REPL payload and far below a memory hazard.
const int maxFrameBytes = 64 * 1024 * 1024;

/// A frame that could not be read as this codec defines it.
///
/// A distinct type rather than a `FormatException` because the two mean
/// different things to a caller: a `FormatException` from `json.decode` says
/// the *payload* was malformed, which is a bug in whoever built the message;
/// this says the *stream* is no longer trustworthy, and the only correct
/// response is to kill the worker rather than try to resynchronise.
final class FrameFormatException implements Exception {
  /// Creates a [FrameFormatException] described by [message].
  const FrameFormatException(this.message);

  /// What was wrong with the frame.
  final String message;

  @override
  String toString() => 'FrameFormatException: $message';
}

/// Encodes [payload] as one length-prefixed JSON frame.
///
/// Throws [FrameFormatException] if the encoded payload exceeds
/// [maxFrameBytes], so an oversized frame fails at the sender — where the
/// offending payload is still in hand — rather than at a receiver that can only
/// report a number.
Uint8List encodeFrame(Map<String, Object?> payload) {
  final body = utf8.encode(json.encode(payload));
  if (body.length > maxFrameBytes) {
    throw FrameFormatException(
      'frame of ${body.length} bytes exceeds the $maxFrameBytes byte cap',
    );
  }
  final frame = Uint8List(frameHeaderBytes + body.length);
  ByteData.sublistView(frame).setUint32(0, body.length, Endian.little);
  frame.setRange(frameHeaderBytes, frame.length, body);

  return frame;
}

/// Index of [frameStreamMagic] in [buffer], or `-1` if it is not present.
///
/// Written out rather than reached for via a `String` search because the
/// preamble is arbitrary bytes: decoding it as UTF-8 to find an ASCII marker
/// can throw on a partial multi-byte sequence straddling a chunk boundary.
///
/// Lives here, beside the marker it looks for, so the web channel gets the
/// same scan without reimplementing it — and so it is reachable from a test
/// that runs on dart2js and dart2wasm, not only on the VM.
int indexOfFrameMagic(List<int> buffer) {
  final magic = frameStreamMagic;
  if (buffer.length < magic.length) return -1;

  outer:
  for (var i = 0; i <= buffer.length - magic.length; i++) {
    for (var j = 0; j < magic.length; j++) {
      if (buffer[i + j] != magic[j]) continue outer;
    }

    return i;
  }

  return -1;
}

/// Reassembles frames from a byte stream that splits them arbitrarily.
///
/// A pipe delivers bytes, not messages: one `stdout` write can arrive as three
/// chunks, and three writes can arrive as one. Feed every chunk to [add] and
/// drain [next] until it returns `null`.
final class FrameReader {
  Uint8List _buffer = Uint8List(0);

  /// Appends [chunk] to the pending bytes.
  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
    final grown = Uint8List(_buffer.length + chunk.length)
      ..setRange(0, _buffer.length, _buffer)
      ..setRange(_buffer.length, _buffer.length + chunk.length, chunk);
    _buffer = grown;
  }

  /// Returns the next complete frame, or `null` if one has not fully arrived.
  ///
  /// Throws [FrameFormatException] when the prefix announces a frame larger
  /// than [maxFrameBytes]. That is unrecoverable by design — see the type's
  /// doc for why resynchronising is the wrong response.
  Map<String, Object?>? next() {
    if (_buffer.length < frameHeaderBytes) return null;
    final length = ByteData.sublistView(
      _buffer,
      0,
      frameHeaderBytes,
    ).getUint32(0, Endian.little);
    if (length > maxFrameBytes) {
      throw FrameFormatException(
        'frame header announced $length bytes, above the $maxFrameBytes cap',
      );
    }
    final end = frameHeaderBytes + length;
    if (_buffer.length < end) return null;

    final body = Uint8List.sublistView(_buffer, frameHeaderBytes, end);
    final decoded = json.decode(utf8.decode(body));
    _buffer = Uint8List.fromList(Uint8List.sublistView(_buffer, end));

    if (decoded is! Map<String, Object?>) {
      throw FrameFormatException(
        'frame payload decoded to ${decoded.runtimeType}, '
        'expected a JSON object',
      );
    }

    return decoded;
  }

  /// Bytes buffered but not yet forming a complete frame.
  ///
  /// Exposed so a caller that sees the stream close can report a truncated tail
  /// as such, instead of reporting a clean end of stream.
  int get pendingBytes => _buffer.length;
}
