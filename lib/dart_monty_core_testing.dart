/// Test doubles for code built on dart_monty_core.
///
/// Import this in tests instead of reaching into `src/`:
///
/// ```dart
/// import 'package:dart_monty_core/dart_monty_core_testing.dart';
///
/// final mock = MockMontyPlatform()
///   ..runResult = const MontyResult(value: MontyInt(42), usage: usage);
/// final result = await mock.run('1 + 1');
/// expect(mock.history.lastRunCode, '1 + 1');
/// ```
///
/// This library re-exports `dart_monty_core.dart`, so the types the mock is
/// configured with (`MontyResult`, `MontyProgress`, `MontyLimits`, ...) come
/// with it and one import is enough. It adds only the mock and its call
/// history; nothing else under `src/` becomes public through it.
library;

export 'dart_monty_core.dart';
export 'src/platform/mock_monty_platform.dart'
    show MockCallHistory, MockMontyPlatform;
