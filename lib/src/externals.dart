import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart';

export 'package:dart_monty_core/src/platform/os_call_exception.dart';

/// A callback invoked when Python calls a registered host function.
///
/// Receives the named arguments map from Python. Return value is
/// serialized back to Python as the function's return value.
/// Return `null` to return `None` to Python.
typedef MontyCallback = Future<Object?> Function(Map<String, Object?> args);

/// A callback invoked when Python performs an OS operation (filesystem,
/// environment, datetime).
///
/// [operation] is the dotted operation name, e.g. `"Path.read_text"`,
/// `"os.getenv"`, `"datetime.now"`, `"date.today"`.
/// [args] and [kwargs] are the positional and keyword arguments.
///
/// For `"date.today"`, return a [MontyDate] with the current date.
/// For `"datetime.now"`, return a [MontyDateTime] with the current date/time.
///
/// Throw an [OsCallException] to raise a Python exception from the handler.
/// Return `null` to return `None` to Python.
typedef OsCallHandler =
    Future<Object?> Function(
      String operation,
      List<Object?> args,
      Map<String, Object?>? kwargs,
    );
