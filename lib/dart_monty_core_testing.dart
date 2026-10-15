/// Test doubles for code built on dart_monty_core.
///
/// Import this in tests beside the main library:
///
/// ```dart
/// import 'package:dart_monty_core/dart_monty_core.dart';
/// import 'package:dart_monty_core/dart_monty_core_testing.dart';
///
/// final session = FakeMontySession()..willReturn(const MontyInt(42));
/// expect(await session.feedRun('1 + 1'), const MontyInt(42));
/// expect(session.feeds, ['1 + 1']);
/// ```
library;

export 'src/fake_monty_session.dart' show FakeMontySession;
