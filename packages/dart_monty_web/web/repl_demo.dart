import 'dart:async';
import 'dart:js_interop';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:web/web.dart' as web;

void main() async {
  final output =
      web.document.getElementById('output')! as web.HTMLDivElement;
  final input =
      web.document.getElementById('input')! as web.HTMLInputElement;
  final runButton =
      web.document.getElementById('run')! as web.HTMLButtonElement;

  void write(String text, {String? className}) {
    final div = web.document.createElement('div') as web.HTMLDivElement
      ..textContent = text;
    if (className != null) div.className = className;
    output..appendChild(div)..scrollTop = output.scrollHeight;
  }

  write('Monty REPL initialized.', className: 'system-line');

  final repl = MontyRepl();

  // Enable UI
  input.disabled = false;
  runButton.disabled = false;
  input.placeholder = 'Type Python code...';

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) return;

    input.value = '';
    write('>>> $code', className: 'input-line');

    try {
      final result = await repl.feed(code);

      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        write(result.printOutput!, className: 'print-line');
      }

      if (result.error != null) {
        write(result.error!.message, className: 'error-line');
      } else if (result.value is! MontyNull) {
        write('=> ${result.value}', className: 'output-line');
      }
    } on Object catch (e) {
      write('Error: $e', className: 'error-line');
    }
  }

  runButton.onclick = (web.MouseEvent e) {
    unawaited(execute());
  }.toJS;

  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') {
      unawaited(execute());
    }
  }.toJS;
}
