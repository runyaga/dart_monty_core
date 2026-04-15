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
/// // Stateful session with callbacks
/// final session = MontySession(platform: platform);
/// await session.run('x = 42', callbacks: {
///   'my_fn': (args) async => 'hello',
/// });
///
/// // Persistent REPL (native Rust heap)
/// final repl = MontyRepl();
/// await repl.feed('x = 42');
/// final r = await repl.feed('x + 1');
/// print(r.value); // MontyInt(43)
/// await repl.dispose();
/// ```
library;

export 'src/callbacks.dart';
export 'src/monty_factory.dart';
export 'src/monty_session.dart';
export 'src/platform/monty_error.dart';
export 'src/platform/monty_exception.dart';
export 'src/platform/monty_limits.dart';
export 'src/platform/monty_platform.dart';
export 'src/platform/monty_progress.dart';
export 'src/platform/monty_resource_usage.dart';
export 'src/platform/monty_result.dart';
export 'src/platform/monty_stack_frame.dart';
export 'src/platform/monty_value.dart';
export 'src/repl/monty_repl.dart';
