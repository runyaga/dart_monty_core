import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Flutter Web integration for dart_monty_core.
abstract final class DartMontyFlutter {
  /// Loads the Monty JS bridge for Flutter Web.
  ///
  /// Must be called once before using Monty or MontyRepl on web —
  /// typically in `main()` before `runApp`.
  ///
  /// Safe to call multiple times: subsequent calls are no-ops if the bridge
  /// is already loaded.
  ///
  /// The bridge and its dependencies (dart_monty_worker.js and
  /// dart_monty_native.wasm) are served automatically from the
  /// `packages/dart_monty_core/assets/` path that Flutter exposes for every
  /// package asset. No manual file copying is required.
  static Future<void> ensureInitialized() async {
    if (_isBridgeLoaded()) return;

    await _injectScript(
      'packages/dart_monty_core/assets/dart_monty_bridge.js',
    );
  }
}

@JS('window.DartMontyBridge')
external JSAny? get _dartMontyBridge;

bool _isBridgeLoaded() => _dartMontyBridge != null;

Future<void> _injectScript(String src) {
  final completer = Completer<void>();
  final script = (web.document.createElement('script')
      as web.HTMLScriptElement)
    ..src = src
    ..onload = (web.Event _) {
      completer.complete();
    }.toJS
    ..onerror = (web.Event _) {
      completer.completeError(
        StateError('Failed to load Monty bridge from: $src'),
      );
    }.toJS;
  web.document.head!.appendChild(script);

  return completer.future;
}
