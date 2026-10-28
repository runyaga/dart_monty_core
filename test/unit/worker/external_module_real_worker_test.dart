// Host modules imported through a real native worker, started the way
// real_pool_vm_test.dart starts one: CI's `test` job and the gate's
// unit_tests stage provide the worker executable, so an untagged test may
// start one. The first test ports upstream monty v1.2.0's
// crates/monty-python/tests/test_external_modules.py —
// test_import_binds_the_host_module (:64-66) and
// test_submodules_are_attributes_of_their_parent (:326-353) — with their
// snapshot values and their four error messages.
//
// The second test is RED: upstream's module_value
// (crates/monty-python/src/external.rs:385-401) encodes a nested module
// under EACH attribute path it is reached by, while this port's arena
// writer (lib/src/worker/arena_writer.dart, _enterImportModule) gives one
// Dart module object one node, named by the path it was first met by — so
// the module under 'pkg.twin' arrives as 'pkg.sub'.
@TestOn('vm')
@Tags(['vm-only'])
library;

import 'package:dart_monty_core/dart_monty_core.dart'
    show
        ExternalModule,
        MontyBool,
        MontyHostFunction,
        MontyInt,
        MontyList,
        MontyRuntimeError,
        MontyString;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '../../integration/worker/_worker_harness.dart';

/// Every session's memory is bounded, as the harness's sessions are.
const ResourceLimits _bounded = ResourceLimits(maxMemory: 64 * 1024 * 1024);

/// The runtime error a feed raises, matched on upstream's `str(exc)`: the
/// exception type, a colon, and the message.
Matcher _runtimeError(String message) => isA<MontyRuntimeError>()
    .having((e) => e.toString(), 'message', message)
    .having(
      (e) => e.exception.excType,
      'excType',
      message.substring(0, message.indexOf(':')),
    );

void main() {
  expectNoWorkersLeftAfterEachTest();

  final add = MontyHostFunction('add', (args, kwargs) {
    return MontyInt(montyArg<int>(args, 0) + montyArg<int>(args, 1));
  });
  final concat = MontyHostFunction('concat', (args, kwargs) {
    return MontyString(
      montyArg<String>(args, 0) +
          switch (kwargs['b']) {
            MontyString(:final value) => value,
            _ => montyArg<String>(args, 1),
          },
    );
  });

  test('host modules import through a real worker as upstream does', () async {
    await withMonty((pool) async {
      // test_import_binds_the_host_module (:64-66): the host module binds
      // at `import tools`, and `from tools import concat` binds its
      // function, keyword argument included.
      final bound = await pool.withSessionWith(
        (session) => session.feedRun(
          'import tools\n'
          'from tools import concat\n'
          "[tools.add(1, 2), concat('a', b='b'), tools.VERSION]",
        ),
        SessionConfig(
          limits: _bounded,
          externalModules: {
            'tools': ExternalModule({
              'add': add,
              'concat': concat,
              'VERSION': 3,
            }),
          },
        ),
      );
      expect(
        bound,
        const MontyList([
          MontyInt(3),
          MontyString('ab'),
          MontyInt(3),
        ]),
      );

      // test_submodules_are_attributes_of_their_parent (:326-353).
      final sub = ExternalModule({'add': add, 'VERSION': 2});
      final pkg = ExternalModule({'VERSION': 1, 'sub': sub});
      await pool.withSessionWith(
        (session) async {
          final attrs = await session.feedRun(
            'import pkg.sub\n'
            'import pkg.sub as s\n'
            'from pkg import sub\n'
            'from pkg.sub import add, VERSION\n'
            '[pkg.VERSION, pkg.sub.VERSION, s.add(1, 2), sub.add(3, 4), '
            'add(5, 6), VERSION, type(pkg.sub).__name__]',
          );
          expect(
            attrs,
            const MontyList([
              MontyInt(1),
              MontyInt(2),
              MontyInt(3),
              MontyInt(7),
              MontyInt(11),
              MontyInt(2),
              MontyString('module'),
            ]),
          );

          // The four error cases (:338-353), with their exact messages.
          await expectLater(
            session.feedRun('import pkg.nope'),
            throwsA(
              _runtimeError(
                "ModuleNotFoundError: No module named 'pkg.nope'",
              ),
            ),
          );
          await expectLater(
            session.feedRun('from pkg.sub.deeper import x'),
            throwsA(
              _runtimeError(
                "ModuleNotFoundError: No module named 'pkg.sub.deeper'",
              ),
            ),
          );
          // A submodule is a module object like its parent.
          await expectLater(
            session.feedRun('import pkg.sub\npkg.sub()'),
            throwsA(
              _runtimeError("TypeError: 'module' object is not callable"),
            ),
          );
          // An attribute that is not a module is not a submodule.
          await expectLater(
            session.feedRun('import pkg.VERSION'),
            throwsA(
              _runtimeError(
                "ModuleNotFoundError: No module named 'pkg.VERSION'",
              ),
            ),
          );
        },
        SessionConfig(limits: _bounded, externalModules: {'pkg': pkg}),
      );
    }, const PoolOptions(maxProcesses: 1));
  });

  test(
    'a submodule reached under two names is a module under each path',
    () async {
      final sub = ExternalModule({'add': add});
      final pkg = ExternalModule({'sub': sub, 'twin': sub});

      // Measured on pydantic-monty 1.2.0 (the gate image's
      // /opt/pymonty-1.2.0/bin/python),
      // pool.checkout(external_modules={'pkg': pkg}).feed_run:
      //
      //   'import pkg\n[repr(pkg.sub), repr(pkg.twin)]'
      //     -> ["<module 'pkg.sub'>", "<module 'pkg.twin'>"]
      //   'import pkg\n[repr(pkg.sub.add), repr(pkg.twin.add)]'
      //     -> ["<function 'pkg.sub.add' external>",
      //         "<function 'pkg.twin.add' external>"]
      //   'import pkg\n[pkg.sub.add(1,2), pkg.twin.add(3,4)]' -> [3, 7]
      //   'import pkg\npkg.sub is pkg.twin' -> False
      //   'import pkg.twin\nfrom pkg.twin import add\nadd(5,6)' -> 11
      //
      // RED: each attribute path names the module it holds, as upstream's
      // module_value encodes it (external.rs:385-401). This port shares one
      // node between 'pkg.sub' and 'pkg.twin' and names it 'pkg.sub', so the
      // reprs below read 'pkg.sub' twice and `pkg.sub is pkg.twin` is True.
      await withMonty((pool) {
        return pool.withSessionWith((session) async {
          final reprs = await session.feedRun(
            'import pkg\n[repr(pkg.sub), repr(pkg.twin)]',
          );
          expect(
            reprs,
            const MontyList([
              MontyString("<module 'pkg.sub'>"),
              MontyString("<module 'pkg.twin'>"),
            ]),
          );

          final functions = await session.feedRun(
            'import pkg\n[repr(pkg.sub.add), repr(pkg.twin.add)]',
          );
          expect(
            functions,
            const MontyList([
              MontyString("<function 'pkg.sub.add' external>"),
              MontyString("<function 'pkg.twin.add' external>"),
            ]),
          );

          final calls = await session.feedRun(
            'import pkg\n[pkg.sub.add(1,2), pkg.twin.add(3,4)]',
          );
          expect(calls, const MontyList([MontyInt(3), MontyInt(7)]));

          final identity = await session.feedRun(
            'import pkg\npkg.sub is pkg.twin',
          );
          expect(identity, const MontyBool(false));

          final throughTwin = await session.feedRun(
            'import pkg.twin\nfrom pkg.twin import add\nadd(5,6)',
          );
          expect(throughTwin, const MontyInt(11));
        }, SessionConfig(limits: _bounded, externalModules: {'pkg': pkg}));
      }, const PoolOptions(maxProcesses: 1));
    },
  );
}
