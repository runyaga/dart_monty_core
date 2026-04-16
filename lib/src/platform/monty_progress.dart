import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:meta/meta.dart';

/// Deep equality instance shared across [MontyPending] operations.
const _deepEquality = DeepCollectionEquality();

/// The progress of a multi-step Monty Python execution.
///
/// A sealed class with five subtypes:
/// - [MontyComplete] — execution finished with a [MontyResult].
/// - [MontyPending] — execution paused, awaiting an external function call.
/// - [MontyOsCall] — execution paused, awaiting an OS/filesystem operation.
/// - [MontyResolveFutures] — execution paused, awaiting resolution of one
///   or more futures created by prior `resumeAsFuture()` calls.
/// - [MontyNameLookup] — execution paused, awaiting a name resolution.
///
/// Use pattern matching to handle all cases:
/// ```dart
/// switch (progress) {
///   case MontyComplete(:final result):
///     print(result.value);
///   case MontyPending(:final functionName, :final arguments):
///     print('Call $functionName with $arguments');
///   case MontyOsCall(:final operationName, :final arguments):
///     print('OS call: $operationName with $arguments');
///   case MontyResolveFutures(:final pendingCallIds):
///     print('Resolve futures: $pendingCallIds');
///   case MontyNameLookup(:final variableName):
///     print('Lookup: $variableName');
/// }
/// ```
sealed class MontyProgress {
  /// Creates a [MontyProgress].
  const MontyProgress();

  /// Creates a [MontyProgress] from a JSON map.
  ///
  /// The `type` discriminator selects the subtype:
  /// - `'complete'` → [MontyComplete]
  /// - `'pending'` → [MontyPending]
  /// - `'name_lookup'` → [MontyNameLookup]
  factory MontyProgress.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;

    return switch (type) {
      'complete' => MontyComplete.fromJson(json),
      'pending' => MontyPending.fromJson(json),
      'os_call' => MontyOsCall.fromJson(json),
      'resolve_futures' => MontyResolveFutures.fromJson(json),
      'name_lookup' => MontyNameLookup.fromJson(json),
      _ => throw ArgumentError.value(type, 'type', 'Unknown progress type'),
    };
  }

  /// Serializes this progress to a JSON-compatible map.
  Map<String, dynamic> toJson();
}

/// Execution completed with a [result].
@immutable
final class MontyComplete extends MontyProgress {
  /// Creates a [MontyComplete] with the given [result].
  const MontyComplete({required this.result});

  /// Creates a [MontyComplete] from a JSON map.
  ///
  /// Expected keys: `type` (must be `'complete'`), `result` (required map).
  factory MontyComplete.fromJson(Map<String, dynamic> json) {
    return MontyComplete(
      result: MontyResult.fromJson(json['result'] as Map<String, dynamic>),
    );
  }

  /// The final result of the execution.
  final MontyResult result;

  /// The Python expression result. Shorthand for `result.value`.
  ///
  /// Equivalent to `MontyComplete.output` in the JS `@pydantic/monty` SDK.
  MontyValue get output => result.value;

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'complete', 'result': result.toJson()};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyComplete && other.result == result);
  }

  @override
  int get hashCode => result.hashCode;

  @override
  String toString() => 'MontyComplete($result)';
}

/// Execution paused, awaiting the return value of an external function call.
///
/// M7A additions:
/// - [kwargs] — keyword arguments passed by the Python call site. When
///   non-null, the call used `fn(key=value)` syntax.
/// - [callId] — a unique identifier for this call, used to correlate
///   pending calls with their resolution in async/futures scenarios (M13).
/// - [methodCall] — `true` when the call was made as a method on an
///   object (e.g. `obj.method()`), `false` for plain function calls.
///
/// ```dart
/// case MontyPending(:final functionName, :final kwargs):
///   if (kwargs != null) {
///     print('$functionName called with kwargs: $kwargs');
///   }
/// ```
@immutable
final class MontyPending extends MontyProgress {
  /// Creates a [MontyPending] with the given [functionName] and [arguments].
  const MontyPending({
    required this.functionName,
    required this.arguments,
    this.kwargs,
    this.callId = 0,
    this.methodCall = false,
  });

  /// Creates a [MontyPending] from a JSON map.
  ///
  /// Expected keys: `type` (must be `'pending'`), `function_name`,
  /// `arguments` (list, defaults to empty if absent), `kwargs` (map,
  /// optional), `call_id` (int, defaults to 0), `method_call` (bool,
  /// defaults to false).
  factory MontyPending.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['arguments'] as List<dynamic>?;
    final rawKwargs = json['kwargs'] as Map<String, dynamic>?;

    return MontyPending(
      functionName: json['function_name'] as String,
      arguments: rawArgs != null
          ? rawArgs.map(MontyValue.fromJson).toList()
          : const [],
      kwargs: rawKwargs?.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
      callId: json['call_id'] as int? ?? 0,
      methodCall: json['method_call'] as bool? ?? false,
    );
  }

  /// The name of the external function to call.
  final String functionName;

  /// The positional arguments to pass to the external function.
  final List<MontyValue> arguments;

  /// Keyword arguments from the Python call site.
  ///
  /// `null` when no keyword arguments were used. An empty map `{}`
  /// means kwargs were explicitly empty (e.g. `fn(**{})`).
  final Map<String, MontyValue>? kwargs;

  /// A unique identifier for this pending call.
  ///
  /// Used to correlate calls with their resolutions in async execution
  /// scenarios. Defaults to `0` for single-call-at-a-time workflows.
  final int callId;

  /// Whether this was a method call (e.g. `obj.method()`) rather than
  /// a plain function call.
  final bool methodCall;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'pending',
      'function_name': functionName,
      'arguments': arguments.map((e) => e.toJson()).toList(),
      if (kwargs != null)
        'kwargs': kwargs!.map((k, v) => MapEntry(k, v.toJson())),
      if (callId != 0) 'call_id': callId,
      if (methodCall) 'method_call': methodCall,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyPending &&
            other.functionName == functionName &&
            _deepEquality.equals(other.arguments, arguments) &&
            _deepEquality.equals(other.kwargs, kwargs) &&
            other.callId == callId &&
            other.methodCall == methodCall);
  }

  @override
  int get hashCode => Object.hash(
    functionName,
    _deepEquality.hash(arguments),
    _deepEquality.hash(kwargs),
    callId,
    methodCall,
  );

  @override
  String toString() => 'MontyPending($functionName, $arguments)';
}

/// Execution paused, awaiting an OS/filesystem operation.
///
/// Yielded when Python code accesses `pathlib`, `os.getenv`, `os.environ`,
/// or similar OS-level operations.
/// The host (Dart) handles the I/O and resumes with the result.
///
/// ```dart
/// case MontyOsCall(:final operationName, :final arguments):
///   switch (operationName) {
///     case 'Path.exists':
///       final path = arguments.first as String;
///       progress = await platform.resume(File(path).existsSync());
///     case 'os.getenv':
///       final key = arguments.first as String;
///       progress = await platform.resume(Platform.environment[key]);
///   }
/// ```
@immutable
final class MontyOsCall extends MontyProgress {
  /// Creates a [MontyOsCall].
  const MontyOsCall({
    required this.operationName,
    required this.arguments,
    this.kwargs,
    this.callId = 0,
  });

  /// Creates a [MontyOsCall] from a JSON map.
  factory MontyOsCall.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['arguments'] as List<dynamic>?;
    final rawKwargs = json['kwargs'] as Map<String, dynamic>?;

    return MontyOsCall(
      operationName: json['operation_name'] as String,
      arguments: rawArgs != null
          ? rawArgs.map(MontyValue.fromJson).toList()
          : const [],
      kwargs: rawKwargs?.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
      callId: json['call_id'] as int? ?? 0,
    );
  }

  /// The OS operation name, e.g. `"Path.read_text"`, `"os.getenv"`.
  final String operationName;

  /// The positional arguments for the operation.
  final List<MontyValue> arguments;

  /// Keyword arguments from the Python call site.
  final Map<String, MontyValue>? kwargs;

  /// Unique call identifier for async correlation.
  final int callId;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'os_call',
      'operation_name': operationName,
      'arguments': arguments.map((e) => e.toJson()).toList(),
      if (kwargs != null)
        'kwargs': kwargs!.map((k, v) => MapEntry(k, v.toJson())),
      if (callId != 0) 'call_id': callId,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyOsCall &&
            other.operationName == operationName &&
            _deepEquality.equals(other.arguments, arguments) &&
            _deepEquality.equals(other.kwargs, kwargs) &&
            other.callId == callId);
  }

  @override
  int get hashCode => Object.hash(
    operationName,
    _deepEquality.hash(arguments),
    _deepEquality.hash(kwargs),
    callId,
  );

  @override
  String toString() => 'MontyOsCall($operationName, $arguments)';
}

/// Execution paused, awaiting resolution of pending futures.
///
/// Returned after one or more external function calls were resumed with
/// `resumeAsFuture()`. The VM continues executing until it reaches an
/// `await` expression, then yields this progress with the list of
/// [pendingCallIds] that need resolution.
///
/// Resolve futures using `resolveFutures()`:
/// ```dart
/// case MontyResolveFutures(:final pendingCallIds):
///   final results = await Future.wait(
///     pendingCallIds.map((id) => fetchResult(id)),
///   );
///   progress = await platform.resolveFutures(
///     Map.fromIterables(pendingCallIds, results),
///   );
/// ```
@immutable
final class MontyResolveFutures extends MontyProgress {
  /// Creates a [MontyResolveFutures] with the given [pendingCallIds].
  const MontyResolveFutures({required this.pendingCallIds});

  /// Creates a [MontyResolveFutures] from a JSON map.
  ///
  /// Expected keys: `type` (must be `'resolve_futures'`),
  /// `pending_call_ids` (list of ints).
  factory MontyResolveFutures.fromJson(Map<String, dynamic> json) {
    final rawIds = json['pending_call_ids'] as List<dynamic>;

    return MontyResolveFutures(pendingCallIds: List<int>.from(rawIds));
  }

  /// The call IDs of futures that need resolution.
  final List<int> pendingCallIds;

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'resolve_futures', 'pending_call_ids': pendingCallIds};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyResolveFutures &&
            _deepEquality.equals(other.pendingCallIds, pendingCallIds));
  }

  @override
  int get hashCode => _deepEquality.hash(pendingCallIds);

  @override
  String toString() => 'MontyResolveFutures($pendingCallIds)';
}

/// Execution paused, awaiting resolution of an unrecognized variable name.
///
/// Returned when the engine encounters a name that is not in the built-in
/// scope and not registered as an external function. The host must either
/// supply a value or indicate the name is undefined (raising NameError).
///
/// Resolve using `resumeNameLookup()` on the platform:
/// ```dart
/// case MontyNameLookup(:final variableName):
///   final value = constants[variableName];
///   if (value != null) {
///     progress = await platform.resumeNameLookup(variableName, value);
///   } else {
///     progress = await platform.resumeNameLookupUndefined(variableName);
///   }
/// ```
@immutable
final class MontyNameLookup extends MontyProgress {
  /// Creates a [MontyNameLookup].
  const MontyNameLookup({required this.variableName});

  /// Creates a [MontyNameLookup] from a JSON map.
  factory MontyNameLookup.fromJson(Map<String, dynamic> json) {
    return MontyNameLookup(
      variableName: json['variable_name'] as String? ?? '',
    );
  }

  /// The name the engine is trying to resolve.
  final String variableName;

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'name_lookup', 'variable_name': variableName};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyNameLookup && other.variableName == variableName);
  }

  @override
  int get hashCode => variableName.hashCode;

  @override
  String toString() => 'MontyNameLookup($variableName)';
}
