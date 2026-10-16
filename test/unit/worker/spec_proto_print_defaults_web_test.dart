// Browser console defaults preserve each delivered fragment.
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

@JS('console')
external JSObject get _console;

(List<String>, List<String>) _captureConsole() {
  final logged = <String>[];
  final errored = <String>[];
  final log = _console['log'];
  final error = _console['error'];
  _console['log'] = ((JSAny? text) => logged.add('${text.dartify()}')).toJS;
  _console['error'] = ((JSAny? text) => errored.add('${text.dartify()}')).toJS;
  addTearDown(() {
    _console['log'] = log;
    _console['error'] = error;
  });

  return (logged, errored);
}

void main() {
  test(
    'stdout and stderr fragments remain separate console entries',
    () async {
      final pool = await Monty.start(maxProcesses: 1);
      addTearDown(pool.close);
      final session = await pool.checkout(printFlushInterval: Duration.zero);
      addTearDown(session.close);
      final (logged, errored) = _captureConsole();
      final call =
          await session.feedStart(
                "import sys\nprint('a', end='')\nf()\n"
                "print('b')\n"
                "print('e', end='', file=sys.stderr)\ng()\n"
                "print('rr', file=sys.stderr)",
              )
              as FunctionSnapshot;
      expect(logged, ['a']);
      final next =
          await call.resume(const ExternalReturnValue(MontyNone()))
              as FunctionSnapshot;
      expect(logged, ['a', 'b\n']);
      expect(errored, ['e']);
      expect(
        (await next.resume(const ExternalReturnValue(MontyNone()))
                as MontyComplete)
            .output,
        const MontyNone(),
      );
      expect(logged, ['a', 'b\n']);
      expect(errored, ['e', 'rr\n']);
    },
  );

  test(
    'oversized JS duration is refused before Configure',
    () async {
      final channel = ScriptedChannel([
        answer([protoInt(42)]),
      ]);
      final interval = Duration(seconds: math.pow(2, 64).toInt());
      await expectLater(
        ProtoSession.open(channel, SessionConfig(printFlushInterval: interval)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'invalid print_flush_interval: cannot convert float '
                'seconds to Duration: value is either too big or NaN',
          ),
        ),
      );
      expect(channel.requests, isEmpty);
    },
    skip: identical(1, 1.0) ? false : 'Only dart2js holds 2^64 seconds.',
  );
}
