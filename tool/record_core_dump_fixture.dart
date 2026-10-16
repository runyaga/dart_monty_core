// Rewrites test/unit/worker/_core_dump_fixture.g.dart with an idle dump made by
// core's worker, which tool/generate_dump_oracle.py --check loads in upstream.
//
//   bash tool/build_worker.sh
//   dart run tool/record_core_dump_fixture.dart
import 'dart:io';

import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';

import '../test/unit/worker/_dump_oracle.g.dart';

Future<void> main() async {
  final pool = await startMonty(const PoolOptions(maxProcesses: 1));
  try {
    final session = await pool.checkoutWith();
    await session.feedRun(dumpStateCode);
    final dump = await session.dump();
    await session.close();
    final hex = [for (final b in dump) b.toRadixString(16).padLeft(2, '0')];
    File('test/unit/worker/_core_dump_fixture.g.dart').writeAsStringSync(
      "// An idle dump made by core's worker, loaded in upstream by\n"
      '// tool/generate_dump_oracle.py --check and in core by\n'
      '// _boundary_cases.dart. Rewritten by tool/record_core_dump_fixture.dart.\n'
      '\n'
      '/// The dump, as hex.\n'
      "const coreIdleDumpHex =\n    '${hex.join()}';\n",
    );
  } finally {
    await pool.close();
  }
}
