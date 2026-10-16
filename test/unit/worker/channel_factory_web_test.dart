// The factory must retry asset discovery after a failed search. This suite
// owns its factory cache and temporarily replaces fetch to simulate an outage.
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:js_interop';

import 'package:dart_monty_core/src/worker/asset_base.dart';
import 'package:dart_monty_core/src/worker/channel_factory_web.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:test/test.dart';

@JS('fetch')
external JSFunction get _fetch;

@JS('fetch')
external set _fetch(JSFunction value);

void main() {
  test('asset discovery retries after every candidate failed', () async {
    final original = _fetch;
    addTearDown(() => _fetch = original);
    final tried = <String>[];
    _fetch = ((JSString url) {
      tried.add(url.toDart);

      return Future<JSAny?>.error(StateError('offline')).toJS;
    }).toJS;
    // Two separate searches are the behaviour under test.
    // ignore: prefer-moving-to-variable
    final failedSearch = openChannel().ready;
    await expectLater(
      failedSearch,
      throwsA(
        isA<MontyCrashedError>().having(
          (e) => e.toString(),
          'message',
          contains('No dart_monty_core worker assets found'),
        ),
      ),
    );
    expect(tried, assetBases.map(workerScriptUrl).toList());

    _fetch = original;
    // A cached failure would throw again. A fresh search finds the real
    // test-server assets and starts a channel that can shut down normally.
    // A second, separate search is the behaviour under test.
    // ignore: prefer-moving-to-variable
    final channel = await openChannel().ready;
    addTearDown(channel.kill);
    expect(channel.isAlive, isTrue);
    await channel.close();
    expect(channel.isAlive, isFalse);
  });
}
