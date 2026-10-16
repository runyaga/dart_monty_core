// Observe discovery through fetch, without reading the factory's cache.
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/channel_factory_web.dart';
import 'package:test/test.dart';

@JS('fetch')
external JSFunction get _fetch;

@JS('fetch')
external set _fetch(JSFunction value);

const _flutterScript =
    'assets/packages/dart_monty_core/lib/assets/dart_monty_core_worker.js';
const _packageScript =
    'packages/dart_monty_core/assets/dart_monty_core_worker.js';
const _packageWasm =
    'packages/dart_monty_core/assets/dart_monty_core_worker.wasm';

Future<void> _attempt() => expectLater(
  openChannel().ready,
  throwsA(
    isA<MontyCrashedError>().having(
      (error) => error.toString(),
      'message',
      'failed to spawn monty worker: fetch $_packageWasm: HTTP 503',
    ),
  ),
);

void main() {
  final fetched = <String>[];
  setUpAll(() async {
    final original = _fetch;
    addTearDown(() => _fetch = original);
    _fetch = ((JSString url) {
      final path = url.toDart;
      fetched.add(path);
      final headers = JSObject()
        ..['get'] = ((JSString name) => 'application/javascript'.toJS).toJS;
      final response = JSObject()
        ..['ok'] = (path == _packageScript).toJS
        ..['status'] = 503.toJS
        ..['headers'] = headers;

      return Future.value(response).toJS;
    }).toJS;
    await _attempt();
    expect(fetched, [_flutterScript, _packageScript, _packageWasm]);
  });

  for (final req in ['REQ-platforms-12', 'REQ-release-and-consumers-25']) {
    test('$req: resolved asset base survives subsequent starts', () async {
      fetched.clear();
      await _attempt();
      await _attempt();
      // Failed module fetches retry, but successful discovery stays cached.
      expect(fetched, [_packageWasm, _packageWasm]);
    });
  }
}
