// Default browser print selection is per feed, even after a collector.
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_b2_support.dart';

@JS('console')
external JSObject get _console;

List<String> _capture() {
  final logged = <String>[];
  final previous = _console['log'];
  _console['log'] = ((JSAny? text) => logged.add('${text.dartify()}')).toJS;
  addTearDown(() => _console['log'] = previous);

  return logged;
}

Future<void> _selection(bool start) async {
  final logged = _capture();
  final completed = completeNone();
  final (session, _) = await poolB2Session([
    answer([
      printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'first')]),
      completed,
    ]),
    answer([
      printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'second')]),
      completed,
    ]),
  ]);
  final collector = CollectString();
  if (start) {
    await session.feedStart('print', printCallback: collector.call);
    final done = await session.feedStart('print') as MontyComplete;
    expect(done.output, const MontyNone());
  } else {
    await session.feedRun('print', printCallback: collector.call);
    expect(await session.feedRun('print'), const MontyNone());
  }
  expect(collector.output, 'first');
  expect(logged, ['second']);
}

void main() {
  for (final start in [false, true]) {
    test(
      'REQ-print-delivery-3: omission resets browser sink (start=$start)',
      () => _selection(start),
    );
  }
}
