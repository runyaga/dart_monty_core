// The probe: start the pool with no setup, run `1 + 1`, write the result into
// #result. tool/consumers/drive.mjs passes only if the DOM reads `2`.
//
// Before the cutover this imports the internal pool, the entry point the
// parity adapter uses. The cutover PR switches it to the public
// `Monty.start` (import `package:dart_monty_core/dart_monty_core.dart`).
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// The internal pool, until the cutover (see the header).
// ignore: implementation_imports
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:flutter/widgets.dart';

@JS('document.getElementById')
external JSObject? _byId(String id);

Future<void> main() async {
  runApp(const SizedBox.shrink());
  String text;
  try {
    final value = await Monty.withPool(
      (pool) => pool.withSession((session) => session.feedRun('1 + 1')),
    );
    text = '${value.dartValue}';
  } on Object catch (error, stack) {
    text = 'ERROR: $error\n$stack';
  }
  _byId('result')!.setProperty('textContent'.toJS, text.toJS);
}
