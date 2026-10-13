// The traceback renderer against upstream's own renderings: each display
// case of the parity suite (_display_fixtures.g.dart) is fed to a fresh real
// worker, and the port's display() of the exception the worker raises must
// equal pydantic-monty 1.1.0's, byte for byte, in each format. Shared by the
// VM harness (test/integration/worker/real_worker_test.dart) and the Chrome
// one (worker_channel_web_test.dart), so vm, dart2js and dart2wasm run the
// same cases.
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:test/test.dart';

import '_display_fixtures.g.dart';
import '_kind_round_trips.dart' show OpenWorker;

/// The fixture tests, each on a fresh worker from [configured], closed at
/// its end. A fresh session names its first feed `<python-input-0>`, as the
/// oracle's did.
void displayFixtureTests(String label, OpenWorker configured) {
  test('the display suite has its cases ($label)', () {
    // The floor: a regeneration that lost cases must not pass as green.
    expect(displayFixtures.length, greaterThanOrEqualTo(19));
  });

  for (final fixture in displayFixtures) {
    test('display ${fixture.id} matches upstream ($label)', () async {
      final (turn, close) = await configured();
      try {
        final event = await turn(
          pb.ParentRequest(
            feed: pb.Feed(code: fixture.code, cwd: '/'),
          ),
        );
        expect(event.whichKind(), pb.ChildEvent_Kind.error, reason: '$event');
        final record = RaisedRecord.fromWire(event.error.exception);
        // Both spellings: the explicit format and the default.
        // ignore: avoid_redundant_argument_values
        expect(record.display('traceback'), fixture.traceback);
        expect(record.display(), fixture.traceback);
        expect(record.display('type-msg'), fixture.typeMsg);
        expect(record.display('msg'), fixture.msg);
        expect(
          () => record.display(fixture.badFormat),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              fixture.badFormatMessage,
            ),
          ),
        );
      } finally {
        await close();
      }
    });
  }
}
