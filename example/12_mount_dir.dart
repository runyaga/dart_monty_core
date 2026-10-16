// ignore_for_file: avoid_print, file_names
// 12 — OSAccess: memory files, environment and composed host behavior.
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final file = MemoryFile('/data/hello.txt', 'Hello from memory!');
  final fs = OSAccess(files: [file], environ: {'APP_ENV': 'test'});
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      final read = await session.feedRun(
        "open('/data/hello.txt').read()",
        os: fs,
      );
      if (read != const MontyString('Hello from memory!'))
        throw StateError('read');
      await session.feedRun(
        "open('/data/hello.txt', 'w').write('updated')",
        os: fs,
      );
      if (file.content != 'updated') throw StateError('write');
      print(file.content);
      final env = await session.feedRun(
        "import os; os.getenv('APP_ENV')",
        os: fs,
      );
      if (env != const MontyString('test')) throw StateError('environment');
      print(env);
    }),
  );
}
