/// The browser default print sink: the console.
///
/// A browser has no process streams. Each delivery is its own console
/// entry, so fragments are not joined into lines: a recorded divergence for
/// the browser target.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:js_interop';

/// Writes [text] with `console.error` when [stream] is `stderr`, else with
/// `console.log`.
FutureOr<void> defaultPrint(String stream, String text) {
  if (stream == 'stderr') {
    _consoleError(text.toJS);
  } else {
    _consoleLog(text.toJS);
  }
}

@JS('console.log')
external void _consoleLog(JSString text);

@JS('console.error')
external void _consoleError(JSString text);
