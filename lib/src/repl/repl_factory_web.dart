import 'package:dart_monty_core/src/repl/repl_bindings.dart';
import 'package:dart_monty_core/src/repl/wasm_repl_bindings.dart';
import 'package:dart_monty_core/src/wasm/wasm_bindings_js.dart';

/// Creates REPL bindings using the WASM web backend.
ReplBindings createReplBindings() =>
    WasmReplBindings(bindings: WasmBindingsJs());
