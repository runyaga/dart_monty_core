// Observe discovery through fetch and the actual Worker constructor.
@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/channel_factory_web.dart';
import 'package:test/test.dart';

import '_browser_channel_fixture.dart';

const _flutterScript =
    'assets/packages/dart_monty_core/lib/assets/dart_monty_core_worker.js';
const _flutterWasm =
    'assets/packages/dart_monty_core/lib/assets/dart_monty_core_worker.wasm';

Future<void> _attempt() => expectLater(
  openChannel().ready,
  throwsA(
    isA<MontyCrashedError>().having(
      (error) => error.toString(),
      'message',
      allOf(
        contains('Worker $_flutterScript:'),
        contains('fixture Worker construction observed'),
      ),
    ),
  ),
);

void main() {
  late BrowserChannelFixture browser;
  setUpAll(() async {
    browser = BrowserChannelFixture(servedScript: _flutterScript);
    addTearDown(browser.restore);
    await _attempt();
    expect(browser.fetched, [_flutterScript, _flutterWasm]);
    expect(browser.workers, [_flutterScript]);
  });

  for (final run in [1, 2]) {
    test('resolved asset base survives subsequent starts (run $run)', () async {
      browser.fetched.clear();
      browser.workers.clear();
      await _attempt();
      await _attempt();
      // Both successful discovery and compilation stay cached even when
      // Worker construction fails; every start uses the selected script.
      expect(browser.fetched, isEmpty);
      expect(browser.workers, [_flutterScript, _flutterScript]);
    });
  }
}
