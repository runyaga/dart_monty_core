import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

/// The last [capacity] bytes of a byte stream, which it always drains: a
/// worker blocks once its stderr pipe fills.
final class ByteTail {
  /// Drains bytes into a bounded diagnostic tail.
  ByteTail(Stream<List<int>> bytes, this.capacity) {
    _subscription = bytes.listen(
      _add,
      onDone: _end,
      onError: (Object _) => _end(),
    );
  }

  /// Maximum retained byte count.
  final int capacity;
  final _chunks = ListQueue<List<int>>();
  final _ended = Completer<void>();
  StreamSubscription<List<int>>? _subscription;
  int _length = 0;

  /// The tail as text, trimmed; a cut multi-byte character becomes U+FFFD.
  String get text {
    final bytes = [for (final chunk in _chunks) ...chunk];
    final start = math.max(0, bytes.length - capacity);

    return utf8.decode(bytes.sublist(start), allowMalformed: true).trim();
  }

  /// Waits up to [grace] for the stream to end, then stops listening.
  ///
  /// The exit code can arrive before the last of the output, so a reader
  /// waits; a process that inherited the pipe can hold it open forever, so
  /// the wait is bounded, and the subscription is cancelled so it cannot
  /// keep this process alive.
  Future<void> drain(Duration grace) async {
    await _ended.future.timeout(grace, onTimeout: () => null);
    await _subscription?.cancel();
    _subscription = null;
  }

  void _add(List<int> chunk) {
    _chunks.add(chunk);
    _length += chunk.length;
    for (;;) {
      final head = _chunks.firstOrNull;
      if (head == null || _length - head.length < capacity) break;
      _length -= _chunks.removeFirst().length;
    }
  }

  void _end() {
    if (!_ended.isCompleted) _ended.complete();
  }
}
