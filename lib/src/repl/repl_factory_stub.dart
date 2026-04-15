import 'package:dart_monty_core/src/repl/repl_bindings.dart';

/// Stub for unsupported platforms.
ReplBindings createReplBindings() => throw UnsupportedError(
  'REPL requires dart:ffi (native) or dart:js_interop (web)',
);
