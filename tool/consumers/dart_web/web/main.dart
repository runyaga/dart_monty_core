// The probe: start the pool with no setup, run `1 + 1`, write the result into
// #result. tool/consumers/drive.mjs passes only if the DOM reads `2`.
//
// It uses only the public library, as a consumer does.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_monty_core/dart_monty_core.dart';

@JS('document.getElementById')
external JSObject? _byId(String id);

Future<void> main() async {
  String text;
  try {
    final value = await Monty.withPool(
      (monty) => monty.withSession((session) => session.feedRun('1 + 1')),
    );
    text = '${value.dartValue}';
  } on Object catch (error, stack) {
    text = 'ERROR: $error\n$stack';
  }
  _byId('result')!.setProperty('textContent'.toJS, text.toJS);
}
