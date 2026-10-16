// A deterministic clock for channel grace periods. It controls public Zone
// timers and microtasks; no wall-clock waits or channel internals are read.
import 'dart:async';
import 'dart:collection';

/// Timer and microtask scheduler for protocol boundary tests.
final class ChannelClock {
  final _microtasks = Queue<void Function()>();
  final _timers = <_ChannelTimer>[];
  Duration _now = Duration.zero;

  /// Run [body] with time advanced only by [elapse].
  void run(void Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, callback) {
        _microtasks.add(zone.bindCallback(callback));
      },
      createTimer: (self, parent, zone, duration, callback) {
        final timer = _ChannelTimer(
          _now + duration,
          zone.bindCallback(callback),
        );
        _timers.add(timer);

        return timer;
      },
    ),
  );

  /// Control timers while allowing ordinary asynchronous test matchers.
  Future<void> runAsync(Future<void> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = _ChannelTimer(
          _now + duration,
          zone.bindCallback(callback),
        );
        _timers.add(timer);

        return timer;
      },
    ),
  );

  /// Complete all work already queued, without advancing time.
  void flush() {
    while (_microtasks.isNotEmpty) {
      _microtasks.removeFirst()();
    }
  }

  /// Advance the clock, firing active timers in deadline order.
  void elapse(Duration duration) {
    final end = _now + duration;
    flush();
    for (;;) {
      final due =
          _timers.where((timer) => timer.isActive && timer.at <= end).toList()
            ..sort((a, b) => a.at.compareTo(b.at));
      final timer = due.firstOrNull;
      if (timer == null) break;
      _now = timer.at;
      timer.fire();
      flush();
    }
    _now = end;
  }
}

final class _ChannelTimer implements Timer {
  _ChannelTimer(this.at, this._callback);

  final Duration at;
  final void Function() _callback;
  bool _isActive = true;
  int _tick = 0;

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _tick++;
    _callback();
  }

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() => _isActive = false;
}
