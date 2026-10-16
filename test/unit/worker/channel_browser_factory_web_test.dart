// Browser factory contracts; run unchanged under dart2js and dart2wasm.
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/channel_factory_web.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_browser_channel_fixture.dart';

@JS('navigator')
external JSObject get _navigator;

@JS('Object.defineProperty')
external JSObject _define(JSObject object, String name, JSObject descriptor);

@JS('Object.getOwnPropertyDescriptor')
external JSObject? _descriptor(JSObject object, String name);

void _hardware(int? count) {
  const key = 'hardwareConcurrency';
  final before = _descriptor(_navigator, key);
  final descriptor = JSObject()
    ..['configurable'] = true.toJS
    ..['value'] = count?.toJS;
  _define(_navigator, key, descriptor);
  addTearDown(() {
    if (before == null) {
      _navigator.delete(key.toJS);
    } else {
      _define(_navigator, key, before);
    }
  });
}

void main() {
  for (final run in [1, 2]) {
    for (final (count, expected) in [
      (7, 7),
      (1, 1),
      (0, 4),
      (-1, 4),
      (null, 4),
    ]) {
      test('hardwareConcurrency $count selects $expected (run $run)', () async {
        _hardware(count);
        expect(defaultMaxProcesses(), expected);
        final pool = await WorkerPool.start(const PoolOptions(minProcesses: 0));
        addTearDown(pool.close);
        expect(pool.maxProcesses, expected);
        await expectLater(
          Monty.start(minProcesses: expected + 1),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              'invalid pool size: minProcesses=${expected + 1} '
                  'maxProcesses=$expected',
            ),
          ),
        );
      });
    }
  }
  for (final run in [1, 2, 3, 4]) {
    test(
      'explicit asset base reaches the browser factory (run $run)',
      () async {
        final browser = BrowserChannelFixture();
        addTearDown(browser.restore);
        // Each run gets a distinct cache key, so it must fetch its
        // own module as well as construct its worker from the selected base.
        final base = '/chosen-worker-assets/run-$run';
        await expectLater(
          Monty.start(maxProcesses: 1, workerLocation: base),
          throwsA(
            isA<MontyCrashedError>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('Worker $base/dart_monty_core_worker.js:'),
                contains('fixture Worker construction observed'),
              ),
            ),
          ),
        );
        expect(browser.fetched, ['$base/dart_monty_core_worker.wasm']);
        expect(browser.workers, ['$base/dart_monty_core_worker.js']);
        browser.restore();
        final pool = await Monty.start(
          maxProcesses: 1,
          workerLocation: 'packages/dart_monty_core/assets',
        );
        addTearDown(pool.close);
        final session = await pool.checkout();
        addTearDown(session.close);
        expect(await session.feedRun('6 * 7'), const MontyInt(42));
        expect(session.workerPid, isNull);
      },
    );
  }
}
