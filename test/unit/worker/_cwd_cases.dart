// The sandbox working directory against a real worker. The expected values
// are upstream's (pydantic-monty 1.1.0, a pool session with no mounts) for
// the same code and OS answers. Shared by the VM harness
// (test/integration/worker/monty_snapshot_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases.
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_not_handled_exception.dart'
    show OsCallNotHandledException;
import 'package:test/test.dart';

import '_attribute_cases.dart' show WithSession;

void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// A directory's stat result: `os.chdir` reads only `st_mode`.
const MontyValue _dirStat = MontyNamedTuple(
  typeName: 'os.stat_result',
  fieldNames: ['st_mode'],
  values: [MontyInt(0x41ed)], // S_IFDIR | 0o755
);

void cwdSessionTests(String label, WithSession withSession) {
  group('working directory ($label)', () {
    test('the first feed is at "/"; os.chdir lasts into the next', () async {
      await withSession((s) async {
        expect(
          await s.feedRun('import os\nos.getcwd()', printCallback: _ignore),
          const MontyString('/'),
        );
        final stats = <List<MontyValue>>[];
        await s.feedRun(
          "os.chdir('/data')",
          printCallback: _ignore,
          os: (name, args, kwargs) {
            if (name != 'Path.stat') throw const OsCallNotHandledException();
            stats.add(args);

            return _dirStat;
          },
        );
        expect(stats, [
          [const MontyPath('/data')],
        ]);
        expect(
          await s.feedRun('os.getcwd()', printCallback: _ignore),
          const MontyString('/data'),
        );
      });
    });
  });
}
