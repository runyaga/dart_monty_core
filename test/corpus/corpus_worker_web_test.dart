// The upstream 1.1.0 corpus on the Web Worker, dart2js or dart2wasm, in
// whichever browser runs it; and crash recovery through one pool, under JSPI
// and under the forced fallback dispatch. Run by CI job `corpus-worker`:
//
//   dart test test/corpus -p chrome -c dart2js --tags=corpus-worker
//   dart test test/corpus -p firefox -c dart2wasm --tags=corpus-worker
//
// The recursion set is judged by the Worker's own JSPI probe, read here from
// the first Worker started: with JSPI each file meets its directives, without
// it each file equals upstream's browser build's recorded outcome.
@TestOn('browser')
@Tags(['worker', 'corpus-worker'])
library;

import 'dart:js_interop';

import 'package:dart_monty_core/src/worker/asset_base.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_channel.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:monty_conformance/worker_conformance.dart';
import 'package:test/test.dart';

import '_corpus_common.dart';
import '_crash_recovery.dart';

const _backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';

@JS('navigator.userAgent')
external String get _userAgent;

/// Equality of two 300,000-deep nested lists with the recursion limit lifted,
/// so the interpreter's native recursion overflows the Worker's stack (a
/// RangeError the Worker cannot catch) before any Python limit stops it.
const _deepCompare =
    'x = []\nfor i in range(300000):\n    x = [x]\n'
    'y = []\nfor i in range(300000):\n    y = [y]\nx == y';

/// Past the 32-bit address space's capacity: the allocator panics at once
/// (`capacity overflow`) and the wasm instance traps (`unreachable`), with
/// nothing allocated. Needs no `max_memory`: with one the engine raises
/// MemoryError instead.
const _trap = "x = 'a' * 3000000000\nlen(x)";

void main() {
  late WasmModuleCache cache;
  late String base;

  OpenChannel open({required bool forceNoJspi}) =>
      () => PendingSpawn(
        (cancelled) => WorkerChannel.spawn(
          cache,
          workerUrl: workerScriptUrl(base),
          forceNoJspi: forceNoJspi,
          cancelled: cancelled,
        ),
      );

  setUpAll(() async {
    base = await resolveAssetBase(workerScriptServed);
    cache = WasmModuleCache(workerWasmUrl(base));
  });

  // The probe has to be read before the corpus tests are declared, but the
  // assets are found only at run time: one test reads it, the rest read what
  // it stored.
  late bool jspi;
  test("the Worker's JSPI probe", () async {
    final probe = await WorkerChannel.spawn(
      cache,
      workerUrl: workerScriptUrl(base),
    );
    jspi = probe.jspi;
    final protocol = probe.protocol;
    probe.kill();
    // The record of which branch this run judges, with the browser.
    // ignore: avoid_print
    print('JSPI-PROBE $_backend jspi=$jspi protocol=$protocol ua=$_userAgent');
  });

  manifestTests();
  adjudicatorSelfTests();

  group('corpus', () {
    test('the upstream 1.1.0 corpus', () async {
      final target = CorpusTarget(
        label: _backend,
        profile: WorkerCorpusProfile.browser,
        jspi: jspi,
        startPool: () async => startMonty(
          corpusPoolOptions,
          open: open(forceNoJspi: false),
        ),
      );
      await runCorpusChecks(target);
    }, timeout: const Timeout(Duration(minutes: 15)));

    test(
      'the recursion set under the forced fallback ends in a pass or a '
      'crash ($_backend)',
      () async {
        final pool = await startMonty(
          corpusPoolOptions,
          open: open(forceNoJspi: true),
        );
        await runRecursionSetFallback(_backend, pool);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  const bounded = SessionConfig(
    limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
  );
  for (final noJspi in [false, true]) {
    final mode = noJspi ? 'forced fallback' : 'JSPI';
    group('crash recovery, $mode', () {
      crashRecoveryTests(
        '$_backend, $mode',
        [
          CrashCase(
            name: 'the request deadline kills a spinning Worker',
            code: 'while True:\n    pass',
            config: bounded,
            requestTimeout: const Duration(seconds: 1),
            check: (crash) {
              expect(crash.cause, CrashCause.killed);
              expect(crash.timedOut, isTrue);
            },
          ),
          CrashCase(
            name: 'a Worker stack overflow',
            code: _deepCompare,
            config: const SessionConfig(
              limits: ResourceLimits(
                maxMemory: 512 * 1024 * 1024,
                maxRecursionDepth: 100000000,
              ),
            ),
            check: (crash) {
              expect(crash.cause, CrashCause.vanished);
              // Chrome's text for a wasm stack overflow, then Firefox's.
              expect(
                crash.detail,
                anyOf(contains('RangeError'), contains('too much recursion')),
              );
            },
          ),
          CrashCase(
            name: 'a wasm trap',
            code: _trap,
            config: const SessionConfig(),
            check: (crash) {
              expect(crash.cause, CrashCause.vanished);
              expect(crash.detail, contains('unreachable'));
            },
          ),
        ],
        (_) =>
            () => PendingSpawn(
              (cancelled) => WorkerChannel.spawn(
                cache,
                workerUrl: workerScriptUrl(base),
                forceNoJspi: noJspi,
                cancelled: cancelled,
              ),
            ),
      );
    });
  }
}
