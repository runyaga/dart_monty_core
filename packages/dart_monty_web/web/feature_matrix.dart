import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/worker_conformance.dart';
import 'package:web/web.dart' as web;

Future<void> main() async {
  final output = web.document.querySelector('#output')!;
  void log(String text) {
    output.textContent = '${output.textContent}$text\n';
  }

  Monty? pool;
  var failures = 0;
  Future<void> probe(String name, Future<void> Function() body) async {
    try {
      await body();
      log('PASS $name');
    } on Object catch (e) {
      failures++;
      log('FAIL $name: $e');
    }
  }

  void require(bool value) {
    if (!value) throw StateError('unexpected result');
  }

  try {
    pool = await Monty.start(maxProcesses: 1);
    await probe('persistent feeds and dump/loadSession', () async {
      var session = await pool!.checkout();
      try {
        await session.feedRun('x = 40');
        final dump = await session.dump();
        await session.feedRun('x = 0');
        await session.close();
        session = await pool!.checkout();
        await session.loadSession(dump);
        require(await session.feedRun('x + 2') == const MontyInt(42));
      } finally {
        await session.close();
      }
    });
    await probe('typeCheck session', () async {
      final session = await pool!.checkout(typeCheck: true);
      try {
        try {
          await session.feedRun("x: int = 'wrong'");
        } on MontyTypingError {
          return;
        }
        throw StateError('expected MontyTypingError');
      } finally {
        await session.close();
      }
    });
    for (final entry in <String, (ResourceLimits, String)>{
      'memory limit': (
        const ResourceLimits(maxMemory: 1024 * 1024),
        "'a' * 10000000",
      ),
      'feed duration limit': (
        const ResourceLimits(maxFeedDuration: Duration(milliseconds: 50)),
        'while True:\n    pass',
      ),
      'turn duration limit': (
        const ResourceLimits(maxTurnDuration: Duration(milliseconds: 50)),
        'while True:\n    pass',
      ),
    }.entries) {
      await probe(entry.key, () async {
        final session = await pool!.checkout(limits: entry.value.$1);
        try {
          try {
            await session.feedRun(entry.value.$2);
          } on MontyRuntimeError catch (e) {
            final kind = e.exception.excType;
            require(
              entry.key == 'memory limit'
                  ? kind == 'MemoryError'
                  : kind == 'TimeoutError',
            );
            log('Observed $kind: $e');
            return;
          }
          throw StateError('expected resource error');
        } finally {
          await session.close();
        }
      });
    }
    // Same current worker fixture route as corpus_worker_web_test.dart.
    // Every fixture is attempted; failures retain their adjudicator reasons.
    final corpus = await runWorkerFixtureCorpus(pool: pool, log: log);
    failures += corpus.failures.length;
    log(
      'Corpus measured: ${corpus.executed.length} executed, ${corpus.passed} passed, ${corpus.failures.length} failed. Browser mount/recursion limitations are reported per fixture.',
    );
    output.setAttribute('data-complete', 'true');
    output.setAttribute('data-failures', '$failures');
    log('Matrix complete: $failures failures');
  } on Object catch (e) {
    log('Matrix aborted: $e');
  } finally {
    await pool?.close();
  }
}
