/// dart_monty_core — thin Dart binding for pydantic/monty.
///
/// No plugins. No bridge. No registry.
///
/// ## Quick start
///
/// ```dart
/// import 'package:dart_monty_core/dart_monty_core.dart';
///
/// // One-shot execution
/// final platform = createMontyPlatform();
/// final result = await platform.run('1 + 1');
/// print(result.value); // MontyInt(2)
///
/// // Stateful session — backed by the Rust REPL heap
/// final session = MontySession();
/// await session.run('x = 42', externals: {
///   'my_fn': (args) async => 'hello',
/// });
///
/// // Persistent REPL (same Rust heap, lower-level API)
/// final repl = MontyRepl();
/// await repl.feed('x = 42');
/// final r = await repl.feed('x + 1');
/// print(r.value); // MontyInt(43)
/// await repl.dispose();
/// ```
library;

export 'src/externals.dart';
export 'src/monty.dart';
export 'src/monty_factory.dart';
export 'src/monty_session.dart';
export 'src/platform/code_capture.dart';
export 'src/platform/monty_error.dart';
export 'src/platform/monty_exception.dart';
export 'src/platform/monty_future_capable.dart';
export 'src/platform/monty_limits.dart';
export 'src/platform/monty_platform.dart';
export 'src/platform/monty_progress.dart';
export 'src/platform/monty_resource_usage.dart';
export 'src/platform/monty_result.dart';
export 'src/platform/monty_stack_frame.dart';
export 'src/platform/monty_value.dart';
export 'src/platform/os_call_exception.dart';
export 'src/repl/monty_repl.dart';
export 'src/repl/repl_platform.dart';
