import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/src/worker_fixture_host.dart';

/// Runs a browser mount fixture in the corpus's virtual filesystem.
Future<MontyValue> runMountFixture(MontySession session, String source) =>
    session.feedRun(
      source,
      cwd: '/mnt',
      os: WorkerFixtureOs.mounted().call,
      externalLookup: {'root': MontyPath('/mnt')},
      printCallback: _discard,
    );

// Corpus directives adjudicate outcomes, not printed output.
void _discard(String stream, String text) {
  return;
}
