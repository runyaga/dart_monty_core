import 'dart:async';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/platform/code_capture.dart' as code_capture;
import 'package:dart_monty_core/src/platform/monty_error.dart';
import 'package:dart_monty_core/src/platform/monty_exception.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_platform.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_resource_usage.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:meta/meta.dart';

const _restoreStateFn = '__restore_state__';
const _persistStateFn = '__persist_state__';

String _buildRestoreCode(Iterable<String> keys) {
  final buf = StringBuffer('__d = __restore_state__()');
  for (final key in keys) {
    buf.write('\n$key = __d["$key"]');
  }

  return buf.toString();
}

String _buildPersistCode(
  String code,
  Iterable<String> existingKeys,
) {
  final names = <String>{
    ...existingKeys,
    ...code_capture.extractAssignmentTargets(code),
  };
  if (names.isEmpty) return '__persist_state__({})';
  final buf = StringBuffer('__d2 = {}');
  for (final name in names) {
    buf
      ..write('\ntry:')
      ..write('\n    __d2["$name"] = $name')
      ..write('\nexcept Exception:')
      ..write('\n    pass');
  }
  buf.write('\n__persist_state__(__d2)');

  return buf.toString();
}

Map<String, Object?> _toArgMap(
  List<MontyValue> positional,
  Map<String, MontyValue>? kwargs,
) {
  final result = <String, Object?>{};
  if (kwargs != null) {
    result.addAll(kwargs.map((k, v) => MapEntry(k, v.dartValue)));
  }
  for (var i = 0; i < positional.length; i++) {
    result['_$i'] = positional[i].dartValue;
  }

  return result;
}

String _wrapSessionCode(
  String code,
  Iterable<String> stateKeys,
) {
  final restore = _buildRestoreCode(stateKeys);
  final persist = _buildPersistCode(code, stateKeys);
  final (processed, hasResult) = code_capture.captureLastExpression(code);
  final buf = StringBuffer(restore)
    ..write('\n')
    ..write(processed)
    ..write('\n')
    ..write(persist);
  if (hasResult) buf.write('\n__r');

  return buf.toString();
}

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

/// A stateful execution session that persists variables across calls.
///
/// Each [MontySession] wraps a [MontyPlatform] and maintains a snapshot of
/// Python globals between executions. Only JSON-serializable values persist
/// (int, float, str, bool, list, dict, None).
///
/// Register Dart callbacks with `externals` to let Python call host functions.
/// OS calls (pathlib, os.getenv, datetime) are handled by `osHandler`; if
/// none is provided, OS calls raise a Python exception.
///
/// ```dart
/// final platform = createMontyPlatform();
/// final session = MontySession(platform: platform);
/// await session.run('x = 42');
/// final result = await session.run('x + 1');
/// print(result.value); // MontyInt(43)
/// session.dispose();
/// ```
class MontySession {
  /// Creates a [MontySession] backed by [platform].
  ///
  /// The session does NOT take ownership of [platform] — calling [dispose]
  /// does not dispose the platform.
  MontySession({
    required MontyPlatform platform,
    OsCallHandler? osHandler,
  }) : _platform = platform,
       _osHandler = osHandler;

  final MontyPlatform _platform;
  final OsCallHandler? _osHandler;
  Map<String, Object?> _state = {};
  bool _isDisposed = false;

  /// The current persisted state map. Read-only snapshot.
  Map<String, Object?> get state => Map.unmodifiable(_state);

  /// Whether this session has been disposed.
  @visibleForTesting
  bool get isDisposed => _isDisposed;

  /// Executes [code] with state restored from previous calls.
  ///
  /// [externals] maps Python-callable function names to Dart handlers.
  /// Any Python call to a registered name is dispatched here; unregistered
  /// names raise a Python exception.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
    Map<String, MontyCallback> externals = const {},
  }) async {
    _checkNotDisposed();
    final wrapped = _wrapSessionCode(code, _state.keys);
    final extFns = [_restoreStateFn, _persistStateFn, ...externals.keys];
    final progress = await _safeCall(
      () => _platform.start(
        wrapped,
        externalFunctions: extFns,
        limits: limits,
        scriptName: scriptName,
      ),
    );

    return _dispatchLoop(progress, externals);
  }

  /// Starts iterative execution, surfacing [MontyPending] for user callbacks.
  ///
  /// Internal state functions are intercepted transparently. Register
  /// [externalFunctions] names here; handle pauses with [resume] and
  /// [resumeWithError].
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    _checkNotDisposed();
    final wrapped = _wrapSessionCode(code, _state.keys);
    final allExtFns = [_restoreStateFn, _persistStateFn, ...?externalFunctions];
    final initial = await _safeCall(
      () => _platform.start(
        wrapped,
        externalFunctions: allExtFns,
        limits: limits,
        scriptName: scriptName,
      ),
    );

    return _intercept(initial);
  }

  /// Resumes a paused execution with [returnValue].
  Future<MontyProgress> resume(Object? returnValue) async {
    _checkNotDisposed();

    return _intercept(await _safeCall(() => _platform.resume(returnValue)));
  }

  /// Resumes a paused execution by raising [errorMessage] in Python.
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    _checkNotDisposed();

    return _intercept(
      await _safeCall(() => _platform.resumeWithError(errorMessage)),
    );
  }

  /// Clears all persisted state.
  void clearState() {
    _checkNotDisposed();
    _state = {};
  }

  /// Disposes the session. Does NOT dispose the underlying platform.
  void dispose() {
    _isDisposed = true;
    _state = {};
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _captureState(List<MontyValue> arguments) {
    if (arguments.isEmpty) return;
    final arg = arguments.first;
    if (arg is MontyDict) {
      _state = arg.entries.map((k, v) => MapEntry(k, v.dartValue));
    }
  }

  Future<MontyResult> _dispatchLoop(
    MontyProgress initial,
    Map<String, MontyCallback> externals,
  ) async {
    var progress = initial;
    while (true) {
      switch (progress) {
        case MontyPending(functionName: _restoreStateFn):
          progress = await _safeCall(() => _platform.resume(_state));
        case MontyPending(functionName: _persistStateFn):
          _captureState(progress.arguments);
          progress = await _safeCall(() => _platform.resume(null));
        case MontyComplete(:final result):
          return result;
        case MontyPending(:final functionName):
          final cb = externals[functionName];
          if (cb == null) {
            progress = await _safeCall(
              () => _platform.resumeWithError(
                'No handler registered for: $functionName',
              ),
            );
          } else {
            try {
              final args = _toArgMap(progress.arguments, progress.kwargs);
              final result = await cb(args);
              progress = await _safeCall(() => _platform.resume(result));
            } on Object catch (e) {
              progress = await _safeCall(
                () => _platform.resumeWithError(e.toString()),
              );
            }
          }
        case MontyOsCall():
          progress = await _handleOsCall(progress);
        case MontyResolveFutures():
          progress = await _safeCall(() => _platform.resume(null));
        case MontyNameLookup(:final variableName):
          progress = await _safeCall(
            () => _platform.resumeNameLookupUndefined(variableName),
          );
      }
    }
  }

  Future<MontyProgress> _handleOsCall(MontyOsCall call) async {
    final handler = _osHandler;
    if (handler == null) {
      return _safeCall(
        () => _platform.resumeWithError(
          'OS operations not available — no OsCallHandler configured',
        ),
      );
    }
    try {
      final args = call.arguments.map((v) => v.dartValue).toList();
      final kwargs = call.kwargs?.map((k, v) => MapEntry(k, v.dartValue));
      final result = await handler(call.operationName, args, kwargs);

      return await _safeCall(() => _platform.resume(result));
    } on OsCallException catch (e) {
      final excType = e.pythonExceptionType;
      if (excType != null) {
        return _safeCall(
          () => _platform.resumeWithException(excType, e.message),
        );
      }

      return _safeCall(() => _platform.resumeWithError(e.message));
    } on Object catch (e) {
      return _safeCall(() => _platform.resumeWithError(e.toString()));
    }
  }

  Future<MontyProgress> _intercept(MontyProgress progress) async {
    var current = progress;
    while (true) {
      switch (current) {
        case MontyPending(functionName: _restoreStateFn):
          current = await _safeCall(() => _platform.resume(_state));
        case MontyPending(functionName: _persistStateFn):
          _captureState(current.arguments);
          current = await _safeCall(() => _platform.resume(null));
        case MontyComplete():
        case MontyPending():
        case MontyOsCall():
        case MontyResolveFutures():
        case MontyNameLookup():
          return current;
      }
    }
  }

  Future<MontyProgress> _safeCall(
    Future<MontyProgress> Function() fn,
  ) async {
    try {
      return await fn();
    } on MontyScriptError catch (e) {
      return MontyComplete(
        result: MontyResult(
          value: const MontyNone(),
          error: e.exception,
          usage: _zeroUsage,
        ),
      );
    } on MontyError catch (e) {
      return MontyComplete(
        result: MontyResult(
          value: const MontyNone(),
          error: MontyException(message: e.message),
          usage: _zeroUsage,
        ),
      );
    }
  }

  void _checkNotDisposed() {
    if (_isDisposed) throw StateError('MontySession has been disposed.');
  }
}
