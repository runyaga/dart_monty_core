/// Framing errors ([FrameException] and its subclasses) from `monty-proto`.
library;

/// Namespace for framing error types declared in `frame_errors.dart`.
abstract final class FrameErrors {}

/// A failure that leaves the byte stream unusable: the next byte can no longer
/// be trusted to start a frame.
sealed class FrameException implements Exception {
  const FrameException();
}

/// A length prefix, or a body about to be sent, exceeds the maximum.
///
/// No API this package exports throws it: a session's caller never sees
/// one. A request over the limit is refused before it is sent and reaches
/// the caller as a `MontyRuntimeError` (`RuntimeError`); a reply over it
/// desynchronises the stream, which ends the session with a
/// `MontyCrashedError`.
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

/// A whole frame arrived whose body does not decode as upstream decodes it:
/// malformed protobuf, invalid UTF-8, a node upstream rejects, or a frame
/// that exhausts the decode budget.
///
/// Upstream's `FrameError::Decode`; its pool discards the worker.
final class FrameDecodeException extends FrameException {
  /// Creates the error for the reason upstream's decoder would give.
  const FrameDecodeException(this.reason);

  /// What was wrong with the body.
  final String reason;

  @override
  String toString() => 'FrameDecodeException: frame decode error: $reason';
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
