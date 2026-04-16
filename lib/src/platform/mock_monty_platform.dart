import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_future_capable.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_platform.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/platform/monty_snapshot_capable.dart';
import 'package:dart_monty_core/src/platform/monty_state_mixin.dart';

/// Captures all arguments passed to [MockMontyPlatform] methods.
///
/// Access via [MockMontyPlatform.history].
final class MockCallHistory {
  /// Codes passed to [MockMontyPlatform.run], in call order.
  final List<String> runCodes = [];

  /// Limits passed to [MockMontyPlatform.run], in call order.
  final List<MontyLimits?> runLimitsList = [];

  /// Script names passed to [MockMontyPlatform.run], in call order.
  final List<String?> runScriptNamesList = [];

  /// Codes passed to [MockMontyPlatform.start], in call order.
  final List<String> startCodes = [];

  /// External function lists passed to [MockMontyPlatform.start], in order.
  final List<List<String>?> startExternalFunctionsList = [];

  /// Limits passed to [MockMontyPlatform.start], in call order.
  final List<MontyLimits?> startLimitsList = [];

  /// Script names passed to [MockMontyPlatform.start], in call order.
  final List<String?> startScriptNamesList = [];

  /// Return values passed to [MockMontyPlatform.resume], in call order.
  final List<Object?> resumeReturnValues = [];

  /// Error messages passed to [MockMontyPlatform.resumeWithError], in order.
  final List<String> resumeErrorMessages = [];

  /// Number of times [MockMontyPlatform.resumeAsFuture] was called.
  int resumeAsFutureCount = 0;

  /// Results maps passed to [MockMontyPlatform.resolveFutures], in call order.
  final List<Map<int, Object?>> resolveFuturesResultsList = [];

  /// Errors maps passed to [MockMontyPlatform.resolveFutures], in call order.
  final List<Map<int, String>?> resolveFuturesErrorsList = [];

  /// Snapshot data passed to [MockMontyPlatform.restore], in call order.
  final List<Uint8List> restoreDataList = [];

  /// The most recent code passed to [MockMontyPlatform.run], or `null`.
  String? get lastRunCode => runCodes.isEmpty ? null : runCodes.last;

  /// The most recent limits passed to [MockMontyPlatform.run], or `null`.
  MontyLimits? get lastRunLimits =>
      runLimitsList.isEmpty ? null : runLimitsList.last;

  /// The most recent script name passed to [MockMontyPlatform.run], or `null`.
  String? get lastRunScriptName =>
      runScriptNamesList.isEmpty ? null : runScriptNamesList.last;

  /// The most recent code passed to [MockMontyPlatform.start], or `null`.
  String? get lastStartCode => startCodes.isEmpty ? null : startCodes.last;

  /// The most recent external functions passed to [MockMontyPlatform.start].
  List<String>? get lastStartExternalFunctions =>
      startExternalFunctionsList.isEmpty
      ? null
      : startExternalFunctionsList.last;

  /// The most recent limits passed to [MockMontyPlatform.start], or `null`.
  MontyLimits? get lastStartLimits =>
      startLimitsList.isEmpty ? null : startLimitsList.last;

  /// The most recent script name passed to [MockMontyPlatform.start].
  String? get lastStartScriptName =>
      startScriptNamesList.isEmpty ? null : startScriptNamesList.last;

  /// The most recent return value passed to [MockMontyPlatform.resume].
  Object? get lastResumeReturnValue =>
      resumeReturnValues.isEmpty ? null : resumeReturnValues.last;

  /// Most recent error message passed to [MockMontyPlatform.resumeWithError].
  String? get lastResumeErrorMessage =>
      resumeErrorMessages.isEmpty ? null : resumeErrorMessages.last;

  /// The most recent results map passed to [MockMontyPlatform.resolveFutures].
  Map<int, Object?>? get lastResolveFuturesResults =>
      resolveFuturesResultsList.isEmpty ? null : resolveFuturesResultsList.last;

  /// The most recent errors map passed to [MockMontyPlatform.resolveFutures].
  Map<int, String>? get lastResolveFuturesErrors =>
      resolveFuturesErrorsList.isEmpty ? null : resolveFuturesErrorsList.last;

  /// The most recent snapshot data passed to [MockMontyPlatform.restore].
  Uint8List? get lastRestoreData =>
      restoreDataList.isEmpty ? null : restoreDataList.last;

  /// Codes passed to [MockMontyPlatform.compileCode], in call order.
  final List<String> compileCodeList = [];

  /// Data passed to [MockMontyPlatform.runPrecompiled], in call order.
  final List<Uint8List> runPrecompiledDataList = [];

  /// Data passed to [MockMontyPlatform.startPrecompiled], in call order.
  final List<Uint8List> startPrecompiledDataList = [];

  /// The most recent code passed to [MockMontyPlatform.compileCode].
  String? get lastCompileCode =>
      compileCodeList.isEmpty ? null : compileCodeList.last;

  /// The most recent data passed to [MockMontyPlatform.runPrecompiled].
  Uint8List? get lastRunPrecompiledData =>
      runPrecompiledDataList.isEmpty ? null : runPrecompiledDataList.last;

  /// The most recent data passed to [MockMontyPlatform.startPrecompiled].
  Uint8List? get lastStartPrecompiledData =>
      startPrecompiledDataList.isEmpty ? null : startPrecompiledDataList.last;
}

/// A mock implementation of [MontyPlatform] for testing.
///
/// Configure expected return values before calling methods:
/// ```dart
/// final mock = MockMontyPlatform();
/// mock.runResult = MontyResult(value: 42, usage: usage);
/// final result = await mock.run('1 + 1');
/// expect(mock.history.lastRunCode, '1 + 1');
/// ```
///
/// For [start], [resume], and [resumeWithError], enqueue progress values
/// using [enqueueProgress]:
/// ```dart
/// mock.enqueueProgress(MontyPending(functionName: 'fetch', arguments: []));
/// mock.enqueueProgress(MontyComplete(result: result));
/// ```
class MockMontyPlatform extends MontyPlatform
    with MontyStateMixin
    implements MontySnapshotCapable, MontyFutureCapable {
  /// Creates a [MockMontyPlatform].
  MockMontyPlatform();

  @override
  String get backendName => 'MockMontyPlatform';

  // ---------------------------------------------------------------------------
  // Config (what to return)
  // ---------------------------------------------------------------------------

  /// The result returned by [run].
  ///
  /// Must be set before calling [run] or a [StateError] is thrown.
  MontyResult? runResult;

  /// The snapshot data returned by [snapshot].
  ///
  /// Must be set before calling [snapshot] or a [StateError] is thrown.
  Uint8List? snapshotData;

  /// The platform instance returned by [restore].
  ///
  /// Must be set before calling [restore] or a [StateError] is thrown.
  MontyPlatform? restoreResult;

  // ---------------------------------------------------------------------------
  // Invocation history (what was called)
  // ---------------------------------------------------------------------------

  /// All recorded call arguments. Use this to inspect what was passed.
  final history = MockCallHistory();

  final Queue<MontyProgress> _progressQueue = Queue<MontyProgress>();

  /// Adds a [MontyProgress] to the FIFO queue consumed by [start],
  /// [resume], [resumeWithError], [resumeAsFuture], and
  /// [resolveFutures].
  void enqueueProgress(MontyProgress progress) {
    _progressQueue.add(progress);
  }

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    final result = runResult;
    if (result == null) {
      throw StateError(
        'runResult not set. Assign a MontyResult before calling run().',
      );
    }
    history.runCodes.add(code);
    history.runLimitsList.add(limits);
    history.runScriptNamesList.add(scriptName);

    return result;
  }

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('start');
    assertIdle('start');
    markActive();

    history.startCodes.add(code);
    history.startExternalFunctionsList.add(externalFunctions);
    history.startLimitsList.add(limits);
    history.startScriptNamesList.add(scriptName);

    return _dequeueAndTransition();
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    assertNotDisposed('resume');
    assertActive('resume');

    history.resumeReturnValues.add(returnValue);

    return _dequeueAndTransition();
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');

    history.resumeErrorMessages.add(errorMessage);

    return _dequeueAndTransition();
  }

  @override
  Future<MontyProgress> resumeAsFuture() async {
    assertNotDisposed('resumeAsFuture');
    assertActive('resumeAsFuture');

    history.resumeAsFutureCount++;

    return _dequeueAndTransition();
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) async {
    assertNotDisposed('resolveFutures');
    assertActive('resolveFutures');

    history.resolveFuturesResultsList.add(results);
    history.resolveFuturesErrorsList.add(errors);

    return _dequeueAndTransition();
  }

  @override
  Future<Uint8List> compileCode(String code) async {
    history.compileCodeList.add(code);

    // Encode the code as UTF-8 JSON so tests can decode and verify the input.
    return Uint8List.fromList(utf8.encode(jsonEncode({'code': code})));
  }

  @override
  Future<MontyResult> runPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    final result = runResult;
    if (result == null) {
      throw StateError(
        'runResult not set. Assign a MontyResult before calling '
        'runPrecompiled().',
      );
    }
    history.runPrecompiledDataList.add(compiled);

    return result;
  }

  @override
  Future<MontyProgress> startPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('startPrecompiled');
    assertIdle('startPrecompiled');
    markActive();

    history.startPrecompiledDataList.add(compiled);

    return _dequeueAndTransition();
  }

  @override
  Future<Uint8List> snapshot() async {
    final data = snapshotData;
    if (data == null) {
      throw StateError(
        'snapshotData not set. Assign a Uint8List before calling snapshot().',
      );
    }

    return data;
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    final platform = restoreResult;
    if (platform == null) {
      throw StateError(
        'restoreResult not set. Assign a MontyPlatform before calling '
        'restore().',
      );
    }
    history.restoreDataList.add(data);

    return platform;
  }

  @override
  Future<void> dispose() async {
    await restoreResult?.dispose();
    markDisposed();
  }

  /// Dequeues progress and transitions state: `MontyComplete` → idle,
  /// everything else stays active.
  MontyProgress _dequeueAndTransition() {
    final progress = _dequeueProgress();
    if (progress is MontyComplete) {
      markIdle();
    }

    return progress;
  }

  MontyProgress _dequeueProgress() {
    if (_progressQueue.isEmpty) {
      throw StateError(
        'No progress enqueued. Call enqueueProgress() before '
        'start(), resume(), resumeWithError(), resumeAsFuture(), '
        'or resolveFutures().',
      );
    }

    return _progressQueue.removeFirst();
  }
}
