part of 'telemetry.dart';

/// Stores the callback outcome even if an adapter throws after invoking it.
final class _Invocation<R> {
  _Invocation(this._body);
  bool entered = false;
  Object? error;

  final R Function() _body;
  ({R value})? _outcome;
  StackTrace _stack = StackTrace.empty;

  R run() {
    if (entered) return result();
    entered = true;
    try {
      final value = _body();
      _outcome = (value: value);

      return value;
    } on Object catch (caught, stack) {
      error = caught;
      _stack = stack;
      rethrow;
    }
  }

  R result() {
    final caught = error;
    if (caught != null) Error.throwWithStackTrace(caught, _stack);

    final outcome = _outcome;
    if (outcome == null) throw StateError('callback has not returned');

    return outcome.value;
  }
}
