import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:web/web.dart' as web;

String errorText(Object error) => switch (error) {
  MontySyntaxError() => 'syntax: ${error.display()}',
  MontyRuntimeError() => 'runtime: ${error.display()}',
  MontyTypingError() => 'typing: ${error.display()}',
  MontyCrashedError() => 'crashed worker: $error',
  _ => 'host: $error',
};

String formatValue(MontyValue value) => switch (value) {
  MontyNone() => 'None',
  MontyString(:final value) => value,
  MontyBool(:final value) => value ? 'True' : 'False',
  MontyTuple(items: final values) => '(${values.map(formatValue).join(', ')})',
  MontyList(items: final values) => '[${values.map(formatValue).join(', ')}]',
  ClassInstance() => value.toString(),
  ClassType() => value.toString(),
  ExternalModule() => value.toString(),
  MontyBigInt(:final value) => value.toString(),
  MontyBytes() => value.toString(),
  MontyClassProxy() => value.toString(),
  MontyClassTypeProxy() => value.toString(),
  MontyComplex() => value.toString(),
  MontyDate() => value.toString(),
  MontyDateTime() => value.toString(),
  MontyDict(:final pairs) =>
    '{${pairs.map((p) => '${formatValue(p.$1)}: ${formatValue(p.$2)}').join(', ')}}',
  MontyEllipsis() => '...',
  MontyExceptionValue() => value.toString(),
  MontyFileHandle() => value.toString(),
  MontyFloat(:final value) => value.toString(),
  MontyFrozenSet(:final items) => '{${items.map(formatValue).join(', ')}}',
  MontyHostFunction() => value.toString(),
  MontyInt(:final value) => value.toString(),
  MontyNamedTuple() => value.toString(),
  MontyNotImplemented() => 'NotImplemented',
  MontyPath() => value.toString(),
  MontySet(:final items) => '{${items.map(formatValue).join(', ')}}',
  MontyStdTypeProxy() => value.toString(),
  MontyTime() => value.toString(),
  MontyTimeDelta() => value.toString(),
  MontyTimeZone() => value.toString(),
};

Future<void> main() async {
  final editor =
      web.document.querySelector('#editor')! as web.HTMLTextAreaElement;
  final run = web.document.querySelector('#run')! as web.HTMLButtonElement;
  final reset = web.document.querySelector('#reset')! as web.HTMLButtonElement;
  final picker =
      web.document.querySelector('#examples')! as web.HTMLSelectElement;
  final output = web.document.querySelector('#output')!;
  final description = web.document.querySelector('#description')!;
  void append(String text) {
    output.textContent = '${output.textContent}$text';
  }

  Monty? pool;
  MontySession? session;
  late OSAccess files;
  var setup = 'default';
  var busy = true;
  void lock(bool value) {
    busy = value;
    run.disabled = reset.disabled = picker.disabled = value;
  }

  Future<void> checkout({bool seedFiles = true}) async {
    await session?.close();
    session = null;
    files = OSAccess(
      rootDir: '/work',
      files: seedFiles ? [MemoryFile('/work/hello.txt', 'hello')] : [],
    );
    await files.call(
      'Path.mkdir',
      [const MontyString('/work')],
      {'exist_ok': const MontyBool(true)},
    );
    session = await pool!.checkout(
      typeCheck: setup == 'typing',
      externalModules: setup == 'tools'
          ? {
              'tools': ExternalModule({
                'double': MontyHostFunction(
                  'double',
                  (args, kwargs) =>
                      MontyInt((args.single as MontyInt).value * 2),
                ),
                'ANSWER': const MontyInt(42),
              }),
            }
          : null,
      limits: const ResourceLimits(
        maxMemory: 64 * 1024 * 1024,
        maxFeedDuration: Duration(seconds: 5),
      ),
    );
  }

  Future<void> guarded(Future<void> Function() action) async {
    if (busy) return;
    lock(true);
    try {
      await action();
    } on Object catch (error) {
      append('${errorText(error)}\n');
    } finally {
      lock(false);
    }
  }

  run.addEventListener(
    'click',
    (() {
      unawaited(
        guarded(() async {
          final value = await session!.feedRun(
            editor.value,
            os: files.call,
            cwd: '/work',
            printCallback: (stream, text) {
              append(text);
            },
          );
          append('=> ${formatValue(value)}\n');
        }),
      );
    }).toJS,
  );
  reset.addEventListener(
    'click',
    (() {
      unawaited(
        guarded(() async {
          await checkout(seedFiles: false);
          output.textContent = 'Session reset.\n';
        }),
      );
    }).toJS,
  );
  try {
    final response = await web.window.fetch('examples.json'.toJS).toDart;
    if (!response.ok) throw StateError('examples.json: ${response.status}');
    final data =
        jsonDecode((await response.text().toDart).toDart) as List<dynamic>;
    for (final raw in data) {
      final item = raw as Map<String, dynamic>;
      final option = web.HTMLOptionElement()
        ..value = item['id'] as String
        ..textContent = item['title'] as String;
      picker.appendChild(option);
    }
    void load() {
      final item = data.cast<Map<String, dynamic>>().firstWhere(
        (e) => e['id'] == picker.value,
      );
      editor.value = item['source'] as String;
      description.textContent =
          '${item['description']} Expected: ${jsonEncode(item['expected'])}';
      setup = item['setup'] as String;
    }

    picker.addEventListener(
      'change',
      (() {
        unawaited(
          guarded(() async {
            load();
            await checkout();
            output.textContent = '';
          }),
        );
      }).toJS,
    );
    pool = await Monty.start(maxProcesses: 1);
    load();
    await checkout();
    append('Files live in memory for this page.\n');
    lock(false);
    web.window.addEventListener(
      'pagehide',
      (() {
        unawaited(() async {
          await session?.close();
          await pool?.close();
        }());
      }).toJS,
    );
  } on Object catch (error) {
    append(errorText(error));
  }
}
