// OS calls as upstream presents them to a host, and the host's system
// sleeps and coroutines (host_answers.dart).
// Pure Dart: vm, dart2js and dart2wasm.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart'
    show PythonRefusal;
import 'package:dart_monty_core/src/worker/frame_scan.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException, unknownExcType;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

typedef _Parts = (String, List<MontyValue>, Map<String, MontyValue>);

/// Every OS call kind, with what upstream presents for it.
Map<pb.OsCall, _Parts> _cases() {
  final none = pb.Arena(nodeCount: 1, nodes: [pb.MontyNode(str: 'd')]);

  return {
    pb.OsCall(exists: '/a'): (
      'Path.exists',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(isFile: '/a'): (
      'Path.is_file',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(isDir: '/a'): (
      'Path.is_dir',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(isSymlink: '/a'): (
      'Path.is_symlink',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(readText: '/a'): (
      'Path.read_text',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(readBytes: '/a'): (
      'Path.read_bytes',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(stat: '/a'): ('Path.stat', [MontyPath('/a')], {}),
    pb.OsCall(iterdir: '/a'): (
      'Path.iterdir',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(resolve: '/a'): (
      'Path.resolve',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(absolute: '/a'): (
      'Path.absolute',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(unlink: '/a'): (
      'Path.unlink',
      [MontyPath('/a')],
      {},
    ),
    pb.OsCall(rmdir: '/a'): ('Path.rmdir', [MontyPath('/a')], {}),
    pb.OsCall(
      writeText: pb.OsCall_TextWrite(path: '/a', data: 'x'),
    ): (
      'Path.write_text',
      [MontyPath('/a'), const MontyString('x')],
      {},
    ),
    pb.OsCall(
      appendText: pb.OsCall_TextWrite(path: '/a', data: 'x'),
    ): (
      'Path.append_text',
      [MontyPath('/a'), const MontyString('x')],
      {},
    ),
    pb.OsCall(
      writeBytes: pb.OsCall_BytesWrite(path: '/a', data: [1]),
    ): (
      'Path.write_bytes',
      [
        MontyPath('/a'),
        const MontyBytes([1]),
      ],
      {},
    ),
    pb.OsCall(
      appendBytes: pb.OsCall_BytesWrite(path: '/a', data: [1]),
    ): (
      'Path.append_bytes',
      [
        MontyPath('/a'),
        const MontyBytes([1]),
      ],
      {},
    ),
    pb.OsCall(
      open: pb.OsCall_Open(path: '/a', mode: 'rb'),
    ): (
      'open',
      [MontyPath('/a'), const MontyString('rb')],
      {},
    ),
    pb.OsCall(mkdir: pb.OsCall_Mkdir(path: '/a', existOk: true)): (
      'Path.mkdir',
      [MontyPath('/a')],
      {
        'parents': const MontyBool(false),
        'exist_ok': const MontyBool(true),
      },
    ),
    pb.OsCall(
      rename: pb.OsCall_Rename(src: '/a', dst: '/b'),
    ): (
      'Path.rename',
      [MontyPath('/a'), MontyPath('/b')],
      {},
    ),
    pb.OsCall(
      getenv: pb.OsCall_Getenv(key: 'K'),
      values: none,
    ): (
      'os.getenv',
      [const MontyString('K'), const MontyString('d')],
      {},
    ),
    pb.OsCall(getEnviron: pb.Unit()): ('os.environ', [], {}),
    pb.OsCall(dateToday: pb.Unit()): ('date.today', [], {}),
    pb.OsCall(dateTimeNow: pb.OsCall_DateTimeNow()): (
      'datetime.now',
      [const MontyNone()],
      {},
    ),
    pb.OsCall(
      dateTimeNow: pb.OsCall_DateTimeNow(
        tz: pb.TimeZone(offsetSeconds: 3600, name: 'X'),
      ),
    ): (
      'datetime.now',
      [const MontyTimeZone(offsetSeconds: 3600, name: 'X')],
      {},
    ),
    pb.OsCall(urandom: pb.OsCall_Urandom(size: Int64(8))): (
      'os.urandom',
      [const MontyInt(8)],
      {},
    ),
    pb.OsCall(time: pb.OsCall_TimeCall(caller: 'time.monotonic')): (
      'time.time',
      [const MontyString('time.monotonic')],
      {},
    ),
    pb.OsCall(sleep: pb.OsCall_Sleep(seconds: 0.5)): (
      'time.sleep',
      [const MontyFloat(0.5)],
      {},
    ),
    pb.OsCall(systemSleep: pb.OsCall_Sleep(seconds: 0.5)): (
      'system.sleep',
      [const MontyFloat(0.5)],
      {},
    ),
    pb.OsCall(asyncSleep: pb.OsCall_AsyncSleep(delay: 0.5)): (
      'asyncio.sleep',
      [const MontyFloat(0.5)],
      {},
    ),
    pb.OsCall(asyncSystemSleep: pb.OsCall_AsyncSleep(delay: 0.5)): (
      'system.async_sleep',
      [const MontyFloat(0.5)],
      {},
    ),
    pb.OsCall(import: pb.OsCall_Import(module: 'tools')): (
      'import',
      [const MontyString('tools')],
      {},
    ),
    pb.OsCall(
      importStubs: pb.OsCall_ImportStubs(modules: ['tools', 'other']),
    ): (
      'import_stubs',
      [
        const MontyList([
          MontyString('tools'),
          MontyString('other'),
        ]),
      ],
      {},
    ),
    pb.OsCall(
      scan: pb.OsCall_Scan(
        path: '/data',
        maxDepth: 1,
        followSymlinks: true,
        pattern: ['*.py'],
        caseSensitive: false,
        recurseSymlinks: true,
      ),
    ): (
      'Path.scan',
      [MontyPath('/data')],
      {
        'max_depth': const MontyInt(1),
        'follow_symlinks': const MontyBool(true),
        'pattern': const MontyList([MontyString('*.py')]),
        'case_sensitive': const MontyBool(false),
        'recurse_symlinks': const MontyBool(true),
      },
    ),
  };
}

void main() {
  group('osCallParts', () {
    test('every call, as OsFunctionCall::to_args gives it', () {
      final cases = _cases();
      expect(
        {for (final call in cases.keys) call.whichCall()},
        {...pb.OsCall_Call.values}..remove(pb.OsCall_Call.notSet),
      );
      for (final MapEntry(key: call, value: want) in cases.entries) {
        final (name, args, kwargs) = osCallParts(call);
        final reason = call.whichCall().name;
        expect(name, want.$1, reason: reason);
        expect(args, want.$2, reason: reason);
        expect(kwargs, want.$3, reason: reason);
      }
    });

    test("an OS call with no call is a FormatException with upstream's "
        'text', () {
      expect(
        () => osCallParts(pb.OsCall()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'missing required field OsCall.call',
          ),
        ),
      );
    });

    test('only asyncio.sleep, in either mode, accepts a future', () {
      expect(acceptsFuture('asyncio.sleep'), isTrue);
      expect(acceptsFuture('system.async_sleep'), isTrue);
      expect(acceptsFuture('time.sleep'), isFalse);
      expect(acceptsFuture('Path.read_text'), isFalse);
    });
  });

  group('system sleeps', () {
    pb.OsCall asyncSleep(int id, double delay) => pb.OsCall(
      callId: id,
      asyncSystemSleep: pb.OsCall_AsyncSleep(delay: delay),
    );

    test('a gathered sleep settles only once its delay has passed', () async {
      final host = HostAnswers(systemSleepMax: const Duration(seconds: 10));
      final clock = Stopwatch()..start();
      final answer = await host.osCall(asyncSleep(1, 0.2), parentSleeps: true);
      expect(answer.resumeCall.result.future, 1);
      final settled = await host.settle();
      expect(onlyItem(settled.resumeFutures.results).callId, 1);
      expect(
        clock.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 150)),
      );
    });

    test('gathered sleeps run at once: all are armed before any ends, and '
        'each settles when its timer fires', () async {
      // The timers are held, not run: no wall clock decides the order.
      final held = <Duration, _HeldTimer>{};
      await runZoned(
        () async {
          final host = HostAnswers(
            systemSleepMax: const Duration(seconds: 10),
          );
          for (final (id, delay) in [(1, 0.3), (2, 0.1), (3, 0.2)]) {
            await host.osCall(asyncSleep(id, delay), parentSleeps: true);
          }
          expect(held.keys.toSet(), {
            const Duration(milliseconds: 300),
            const Duration(milliseconds: 100),
            const Duration(milliseconds: 200),
          });
          final order = <int>[];
          for (final ms in [100, 200, 300]) {
            held[Duration(milliseconds: ms)]!.fire();
            final request = await host.settle();
            order.addAll(request.resumeFutures.results.map((r) => r.callId));
          }
          expect(order, [2, 3, 1]);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              held[duration] = _HeldTimer(callback),
        ),
      );
    });

    test('a decline from a future fails asyncio.sleep with TypeError, as '
        "upstream's coroutine returning NOT_HANDLED does", () async {
      for (final eager in [true, false]) {
        final host = HostAnswers(
          os: (name, args, kwargs) async =>
              throw const OsCallNotHandledException(),
        );
        final call = pb.OsCall(
          callId: 1,
          allowEagerAwait: eager,
          asyncSleep: pb.OsCall_AsyncSleep(delay: 0),
        );
        var answer = await host.osCall(call, parentSleeps: true);
        if (!eager) answer = await host.settle();
        final result = onlyItem(answer.resumeFutures.results).result;
        expect(result.error.excType, 'TypeError', reason: 'eager: $eager');
        expect(result.error.message, AsyncDecline.message);
      }
    });

    test('dispose ends every waiting sleep at once', () async {
      final host = HostAnswers(systemSleepMax: const Duration(seconds: 10));
      await host.osCall(asyncSleep(1, 5), parentSleeps: true);
      final inline = host.osCall(
        pb.OsCall(callId: 2, systemSleep: pb.OsCall_Sleep(seconds: 5)),
        parentSleeps: true,
      );
      final clock = Stopwatch()..start();
      host.dispose();
      await inline;
      await host.settle();
      expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
    });
  });

  group('host code: the Python exception a throw raises', () {
    test('any throw but ExternalException raises Exception with its text', () {
      for (final (error, text) in [
        (StateError('x'), 'Bad state: x'),
        (const FormatException('bad'), 'FormatException: bad'),
        (ArgumentError('a'), 'Invalid argument(s): a'),
        ('plain', 'plain'),
        (const OsCallNotHandledException(), 'OsCallNotHandledException()'),
      ]) {
        final raised = raisedFrom(error);
        expect(raised.excType, 'Exception', reason: '$error');
        expect(raised.message, text, reason: '$error');
        expect(raised.hasData(), isFalse, reason: '$error');
      }
    });

    test("the fallback's text is read as upstream reads an exception's "
        'argument: an unpaired surrogate is replaced', () {
      // PyO3's lossy conversion: the surrogate's three bytes, each replaced.
      expect(
        raisedFrom(StateError('a\uD800b')).message,
        'Bad state: a\uFFFD\uFFFD\uFFFDb',
      );
    });

    test('a thrown ExternalException always carries a message, as a '
        "raised Python exception's argument is", () {
      final raised = raisedFrom(const ExternalException('ValueError'));
      expect(raised.excType, 'ValueError');
      expect(raised.hasMessage(), isTrue);
      expect(raised.message, '');
      expect(raisedFrom(const ExternalException('KeyError', 'k')).message, 'k');
    });

    test('a SyntaxError without a message carries None, as upstream reads '
        'str(SyntaxError())', () {
      expect(
        raisedFrom(const ExternalException('SyntaxError')).message,
        'None',
      );
    });

    test('a throw whose toString throws raises Exception with no message, as '
        'upstream does when str() fails', () {
      final raised = raisedFrom(const _BadText());
      expect(raised.excType, 'Exception');
      expect(raised.hasMessage(), isFalse);
    });

    test('an unknown excType is an ArgumentError, which the sandbox '
        'receives as Exception', () {
      final raised = raisedFrom(const ExternalException('NoSuchError', 'm'));
      expect(raised.excType, 'Exception');
      expect(
        raised.message,
        unknownExcType('NoSuchError').toString(),
      );
      expect(unknownExcType('NoSuchError'), isA<ArgumentError>());
      expect(
        unknownExcType('NoSuchError').message,
        "Unknown exception type: 'NoSuchError'",
      );
    });

    test("a refusal Python makes too keeps Python's error", () {
      final raised = raisedFrom(
        PythonRefusal(const MontyNone(), 'cycle', 'ValueError', 'Circular'),
      );
      expect(raised.excType, 'ValueError');
      expect(raised.message, 'Circular');
    });
  });

  group('OS handler', () {
    final now = pb.OsCall(callId: 3, dateTimeNow: pb.OsCall_DateTimeNow());

    test('a returned None is the answer, not a decline', () async {
      final host = HostAnswers(os: (name, args, kwargs) => const MontyNone());
      final result = (await host.osCall(
        now,
        parentSleeps: true,
      )).resumeCall.result;
      expect(result.hasReturnValue(), isTrue);
      expect(result.hasNotHandled(), isFalse);
    });

    test('OsCallNotHandledException thrown synchronously declines', () async {
      final host = HostAnswers(
        os: (name, args, kwargs) => throw const OsCallNotHandledException(),
      );
      final answer = await host.osCall(now, parentSleeps: true);
      expect(answer.resumeCall.result.hasNotHandled(), isTrue);
    });

    test('from a future it raises TypeError, as a NOT_HANDLED a coroutine '
        'returns does upstream', () async {
      final host = HostAnswers(
        os: (name, args, kwargs) =>
            Future.error(const OsCallNotHandledException()),
      );
      final result = (await host.osCall(
        now,
        parentSleeps: true,
      )).resumeCall.result;
      expect(result.hasNotHandled(), isFalse);
      expect(result.error.excType, 'TypeError');
      expect(result.error.message, AsyncDecline.message);
    });

    test("AsyncDecline's text is its message", () {
      expect(
        const AsyncDecline().toString(),
        'AsyncDecline: ${AsyncDecline.message}',
      );
    });

    test("ExternalException's text names its type and message", () {
      expect(
        const ExternalException('ValueError').toString(),
        'ExternalException(ValueError)',
      );
      expect(
        const ExternalException('ValueError', 'm').toString(),
        'ExternalException(ValueError, m)',
      );
    });

    test(
      'ExternalException raises its type; any other throw Exception',
      () async {
        for (final (thrown, type, message) in <(Exception, String, String)>[
          (
            const ExternalException('FileNotFoundError', 'nope'),
            'FileNotFoundError',
            'nope',
          ),
          (const FormatException('x'), 'Exception', 'FormatException: x'),
        ]) {
          final host = HostAnswers(os: (name, args, kwargs) => throw thrown);
          final error = (await host.osCall(
            now,
            parentSleeps: true,
          )).resumeCall.result.error;
          expect(error.excType, type);
          expect(error.message, message);
        }
      },
    );
  });

  test('a lookup resolving to a host function writes its index, 0, '
      "explicitly, as upstream's oneof encoder does", () {
    final host = HostAnswers(
      externalLookup: {
        'f': MontyHostFunction('f', (a, k) => const MontyNone()),
      },
    );
    final lookup = host.lookup('f').resumeNameLookup;
    expect(lookup.hasValue(), isTrue);
    expect(lookup.value, 0);
    // Field 2 (varint) with value 0: tag 0x10, then 0x00.
    final bytes = lookup.writeToBuffer();
    expect(bytes.sublist(bytes.length - 2), [0x10, 0x00]);
  });

  test('a lookup resolving to a host function names it by the lookup key '
      "and keeps its docstring, as upstream's resolve_name renames the "
      'converted function', () {
    final host = HostAnswers(
      externalLookup: {
        'alias': MontyHostFunction(
          'original',
          (a, k) => const MontyNone(),
          docstring: 'Doc.',
        ),
        'bare': MontyHostFunction('other', (a, k) => const MontyNone()),
      },
    );
    final alias = host.lookup('alias').resumeNameLookup;
    final aliasFunction = itemAt(alias.values.nodes, alias.value).function;
    expect(aliasFunction.name, 'alias');
    expect(aliasFunction.hasDocstring(), isTrue);
    expect(aliasFunction.docstring, 'Doc.');
    final bare = host.lookup('bare').resumeNameLookup;
    final bareFunction = itemAt(bare.values.nodes, bare.value).function;
    expect(bareFunction.name, 'bare');
    expect(bareFunction.hasDocstring(), isFalse);
  });

  test(
    'a failing module-map lookup answers imports and dotted calls',
    () async {
      final host = HostAnswers(externalModules: const _ThrowingModuleMap());

      final imported = await host.osCall(
        pb.OsCall(
          callId: 1,
          import: pb.OsCall_Import(module: 'tools'),
        ),
        parentSleeps: true,
      );
      final importError = imported.resumeCall.result.error;
      expect(importError.excType, 'Exception');
      expect(importError.message, 'FormatException: module lookup failed');

      final dotted = await host.call(_callTo('tools.run', id: 2));
      final callError = dotted.resumeCall.result.error;
      expect(callError.excType, 'Exception');
      expect(callError.message, 'FormatException: module lookup failed');
    },
  );

  test(
    'dotted calls resolve only public module functions and preserve async '
    'dispatch',
    () async {
      // Upstream (monty-python 1.2.0): a call whose name carries a dot
      // names an attribute of a host module (`src/external.rs`,
      // `callable`): the name is split at its last dot, the path before it
      // is walked through the host's modules, one public component at a
      // time, and the leaf is the attribute the module that path names
      // holds. A name without a dot is the lookup's own, and the lookup is
      // never consulted for a dotted name. The cases below follow
      // `crates/monty-python/tests/test_external_modules.py` (the module's
      // exposure, `test_name_based_calls_respect_module_exposure`) and
      // `crates/monty/test_cases/import__host_async.py` (the async tools,
      // `test_async_tools_run_concurrently`).
      final ran = <String>[];
      final add = MontyHostFunction('add', (args, kwargs) {
        ran.add('module.add');

        return MontyInt(montyArg<int>(args, 0) + montyArg<int>(args, 1));
      });
      final stubs = MontyHostFunction('import_stubs', (args, kwargs) {
        ran.add('module.import_stubs');

        return const MontyInt(11);
      });
      final host = HostAnswers(
        externalModules: {
          'pkg': ExternalModule({
            'sub': ExternalModule({'add': add}),
            '_secret': ExternalModule({'add': add}),
            'VERSION': 3,
          }),
          'tools': ExternalModule({
            'add': add,
            'VERSION': 3,
            'import_stubs': stubs,
          }),
        },
        externalLookup: {
          // A dotted name belongs to the modules: this entry must not run.
          'pkg.sub.add': MontyHostFunction('pkg.sub.add', (args, kwargs) {
            ran.add('lookup.dotted');

            return const MontyInt(-1);
          }),
          // A bare name is the lookup's own, as it always was.
          'add': MontyHostFunction('add', (args, kwargs) {
            ran.add('lookup.bare');

            return const MontyInt(-2);
          }),
          // A function named like an OS call is an ordinary function.
          'import_stubs': MontyHostFunction('import_stubs', (args, kwargs) {
            ran.add('lookup.import_stubs');

            return const MontyInt(-3);
          }),
        },
      );

      // A public nested module's function runs, as the module's own: the
      // dotted entry in the lookup is not consulted.
      final nested = await host.call(_callTo('pkg.sub.add', args: [1, 2]));
      expect(_value(nested.resumeCall), const MontyInt(3));
      expect(ran, contains('module.add'));
      expect(ran, isNot(contains('lookup.dotted')));

      // A bare name is the lookup's own, as it always was.
      final bare = await host.call(_callTo('add', args: [4, 5]));
      expect(_value(bare.resumeCall), const MontyInt(-2));
      expect(ran, contains('lookup.bare'));

      // An object id still routes the call to the host object, whatever
      // the name says: the modules are not consulted.
      host.objects.register(
        ClassInstance(
          _Counter(ran, 42),
          classType: ClassType(_counterClass, id: _counterClassId),
          id: _counterId,
          policies: (
            eagerAttrs: 'all',
            lazyAttrs: 'all',
            allowedMethods: 'all',
          ),
        ),
      );
      final onObject = await host.call(
        _callTo('pkg.sub.add', objectId: _counterId),
      );
      expect(_value(onObject.resumeCall), const MontyInt(42));
      expect(ran, contains('object.add'));
      expect(ran.where((name) => name == 'module.add'), hasLength(1));

      // A root the host does not offer is not found.
      final noRoot = await host.call(_callTo('nope.add'));
      expect(_notFound(noRoot.resumeCall), isTrue);
      expect(noRoot.resumeCall.result.hasError(), isFalse);

      // A missing component below a registered module is not found: the
      // walk stops at it.
      final noIntermediate = await host.call(_callTo('pkg.missing.add'));
      expect(_notFound(noIntermediate.resumeCall), isTrue);
      expect(noIntermediate.resumeCall.result.hasError(), isFalse);

      // A protected component is not found either: the sandbox never sees
      // a name starting with an underscore, as upstream's
      // `test_name_based_calls_respect_module_exposure` has it.
      final private = await host.call(_callTo('pkg._secret.add'));
      expect(_notFound(private.resumeCall), isTrue);
      expect(private.resumeCall.result.hasError(), isFalse);

      // A component that is not a module is not found: only a module may
      // carry the next component.
      final notAModule = await host.call(_callTo('pkg.VERSION.add'));
      expect(_notFound(notAModule.resumeCall), isTrue);
      expect(notAModule.resumeCall.result.hasError(), isFalse);

      // A leaf the module does not hold is not found.
      final noLeaf = await host.call(_callTo('tools.nope'));
      expect(_notFound(noLeaf.resumeCall), isTrue);
      expect(noLeaf.resumeCall.result.hasError(), isFalse);

      // A leaf that is not callable is an error, not a missing name: the
      // module holds it, and calling it is what fails.
      final notCallable = await host.call(_callTo('tools.VERSION'));
      final notCallableResult = notCallable.resumeCall.result;
      expect(notCallableResult.hasNotFound(), isFalse);
      expect(notCallableResult.hasError(), isTrue);
      expect(notCallableResult.error.excType, 'TypeError');

      // A function named like an OS call is an ordinary function, in the
      // lookup and in a module alike.
      final bareStubs = await host.call(_callTo('import_stubs'));
      expect(_value(bareStubs.resumeCall), const MontyInt(-3));
      expect(ran, contains('lookup.import_stubs'));
      final moduleStubs = await host.call(_callTo('tools.import_stubs'));
      expect(_value(moduleStubs.resumeCall), const MontyInt(11));
      expect(ran, contains('module.import_stubs'));

      // A coroutine-marked module function is started, not awaited in
      // place: two of them run at once, as upstream's gather does. The
      // first waits for the second, so it can only finish once the second
      // has started.
      final gate = _Gate();
      final asyncHost = HostAnswers(
        externalModules: {
          // Upstream refuses a name that is not an identifier, and a
          // keyword is not one: the module is named `async_tools`.
          'async_tools': ExternalModule({
            'first': MontyHostFunction(
              'first',
              coroutine((args, kwargs) async {
                await gate.wait();

                return const MontyInt(1);
              }),
            ),
            'second': MontyHostFunction(
              'second',
              coroutine((args, kwargs) async {
                gate.open();

                return const MontyInt(2);
              }),
            ),
            'boom': MontyHostFunction(
              'boom',
              coroutine((args, kwargs) async {
                throw const ExternalException('ValueError', 'boom');
              }),
            ),
          }),
        },
      );
      final first = await asyncHost
          .call(_callTo('async_tools.first'))
          .timeout(const Duration(seconds: 5));
      expect(first.resumeCall.result.hasFuture(), isTrue);
      final second = await asyncHost
          .call(_callTo('async_tools.second', id: 2))
          .timeout(const Duration(seconds: 5));
      expect(second.resumeCall.result.hasFuture(), isTrue);
      final boom = await asyncHost
          .call(_callTo('async_tools.boom', id: 3))
          .timeout(const Duration(seconds: 5));
      expect(boom.resumeCall.result.hasFuture(), isTrue);

      // They settle at once: the first could only finish because the
      // second started, and the third raises what it was told to.
      final settled = <int, pb.ExtFunctionResult>{};
      final values = <int, MontyValue>{};
      while (settled.length < 3) {
        final answer = await asyncHost.settle().timeout(
          const Duration(seconds: 5),
        );
        final futures = answer.resumeFutures;
        final reader = ArenaReader(futures.values);
        for (final result in futures.results) {
          settled[result.callId] = result.result;
          if (result.result.hasReturnValue()) {
            values[result.callId] = reader[result.result.returnValue];
          }
        }
      }
      expect(values[1], const MontyInt(1));
      expect(values[2], const MontyInt(2));
      final raised = _settledResult(settled, 3);
      expect(raised.hasError(), isTrue);
      expect(raised.error.excType, 'ValueError');
      expect(raised.error.message, 'boom');
    },
  );

  test('normalizeVirtualPath follows normalize_virtual_path', () {
    const cases = {
      '': '',
      '/': '/',
      '/a/b': '/a/b',
      'a/b': '/a/b',
      '/a/./b/': '/a/b',
      '/a/../../b': '/b',
      '..': '/',
      '//a//b': '/a/b',
      '/a/..': '/',
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect(normalizeVirtualPath(key), value, reason: key);
    }
  });

  test(
    'v1.2.0 OS calls preserve arguments validate stubs and dispatch scans',
    () async {
      // The wire a v1.2.0 worker speaks: `OsCall.import` is field 31,
      // `OsCall.import_stubs` field 32 and `OsCall.scan` field 33 (monty
      // 1.2.0, `proto/monty/v1/monty.proto`). The frames are built by hand
      // and read by the scanner, so the arguments, the refusal and the
      // dispatch are exercised as a worker drives them.
      const id = 7;
      final import = _scanned(
        _osCallFrame(_osCallBody(id, _importArm('tools'))),
      );
      final stubs = _scanned(
        _osCallFrame(_osCallBody(id, _importStubsArm(['tools', 'other']))),
      );
      final listing = _scanned(
        _osCallFrame(_osCallBody(id, _scanArm('/data'))),
      );
      final glob = _scanned(
        _osCallFrame(
          _osCallBody(
            id,
            _scanArm(
              '/data',
              maxDepth: 0,
              followSymlinks: true,
              pattern: ['*.py'],
              caseSensitive: false,
              recurseSymlinks: true,
            ),
          ),
        ),
      );

      // Every arm keeps its name and its arguments, as upstream's
      // `OsFunctionCall::to_args` presents them to a host.
      final cases = [
        _Case(
          'import names the module it asks for',
          import,
          'import',
          [const MontyString('tools')],
          const {},
        ),
        _Case(
          'import_stubs names every module, in the order they were asked '
              'for',
          stubs,
          'import_stubs',
          [
            const MontyList([
              MontyString('tools'),
              MontyString('other'),
            ]),
          ],
          const {},
        ),
        _Case(
          'a plain scan keeps its path and every keyword',
          listing,
          'Path.scan',
          [MontyPath('/data')],
          {
            'max_depth': const MontyNone(),
            'follow_symlinks': const MontyBool(false),
            'pattern': const MontyNone(),
            'case_sensitive': const MontyNone(),
            'recurse_symlinks': const MontyBool(false),
          },
        ),
        _Case(
          'a glob scan keeps the depth, the pattern and the flags it was '
              'given',
          glob,
          'Path.scan',
          [MontyPath('/data')],
          {
            'max_depth': const MontyInt(0),
            'follow_symlinks': const MontyBool(true),
            'pattern': const MontyList([MontyString('*.py')]),
            'case_sensitive': const MontyBool(false),
            'recurse_symlinks': const MontyBool(true),
          },
        ),
      ];
      for (final c in cases) {
        // The scanner kept the arm: a v1.2.0 field is not an unknown one.
        expect(
          c.call.whichCall(),
          isNot(pb.OsCall_Call.notSet),
          reason: c.reason,
        );
        final (partName, partArgs, partKwargs) = osCallParts(c.call);
        expect(partName, c.name, reason: c.reason);
        expect(partArgs, c.args, reason: c.reason);
        expect(partKwargs, c.kwargs, reason: c.reason);
      }

      // A stubs ask naming a module once reaches the handler.
      final handled = <String>[];
      final host = HostAnswers(
        os: (name, args, kwargs) {
          handled.add(name);

          return const MontyNone();
        },
      );
      final accepted = await _refused(host.osCall(stubs, parentSleeps: true));
      expect(accepted, isFalse, reason: 'each module is asked about once');
      expect(handled, ['import_stubs']);

      // A stubs ask naming a module twice is refused before any handler
      // runs: a host runs one factory per name, and a compromised child
      // must not multiply that work.
      final repeated = _scanned(
        _osCallFrame(
          _osCallBody(id, _importStubsArm(['tools', 'other', 'tools'])),
        ),
      );
      final refused = await _refused(
        host.osCall(repeated, parentSleeps: true),
      );
      expect(refused, isTrue, reason: 'a module asked about twice');
      expect(handled, ['import_stubs'], reason: 'the handler must not run');

      // The host's answer comes back as it was given: the tree a scan
      // returns, the root included, under the call's own id.
      const tree = MontyList([
        MontyTuple([
          MontyString(''),
          MontyBool(true),
          MontyBool(false),
          MontyBool(false),
        ]),
        MontyTuple([
          MontyString('a.py'),
          MontyBool(false),
          MontyBool(true),
          MontyBool(false),
        ]),
      ]);
      final seen = <(String, List<MontyValue>, Map<String, MontyValue>)>[];
      final scanning = HostAnswers(
        os: (name, args, kwargs) {
          seen.add((name, args, kwargs));

          return tree;
        },
      );
      final answer = await scanning.osCall(listing, parentSleeps: true);
      final (hostName, hostArgs, hostKwargs) = onlyItem(seen);
      expect(hostName, 'Path.scan');
      expect(hostArgs, [MontyPath('/data')]);
      expect(hostKwargs, {
        'max_depth': const MontyNone(),
        'follow_symlinks': const MontyBool(false),
        'pattern': const MontyNone(),
        'case_sensitive': const MontyNone(),
        'recurse_symlinks': const MontyBool(false),
      });
      final resumed = answer.resumeCall;
      expect(resumed.callId, id);
      expect(resumed.result.hasReturnValue(), isTrue);
      final reader = ArenaReader(resumed.values);
      expect(reader[resumed.result.returnValue], tree);

      // A call with no handler, and one the handler declines, are not
      // handled: the sandbox raises the error itself.
      final noHandler = await HostAnswers().osCall(listing, parentSleeps: true);
      expect(noHandler.resumeCall.result.hasNotHandled(), isTrue);
      final declined = await HostAnswers(
        os: (name, args, kwargs) => throw const OsCallNotHandledException(),
      ).osCall(listing, parentSleeps: true);
      expect(declined.resumeCall.result.hasNotHandled(), isTrue);

      // A decline from a future is a TypeError, as upstream's coroutine
      // returning NOT_HANDLED is.
      final asynchronous = await HostAnswers(
        os: (name, args, kwargs) =>
            Future.error(const OsCallNotHandledException()),
      ).osCall(listing, parentSleeps: true);
      final asynchronousResult = asynchronous.resumeCall.result;
      expect(asynchronousResult.hasNotHandled(), isFalse);
      expect(asynchronousResult.error.excType, 'TypeError');
      expect(asynchronousResult.error.message, AsyncDecline.message);
    },
  );

  group('MontyHostFunction.parity evaluation vs serialization', () {
    pb.FunctionCall callTo(
      String name, {
      int id = 1,
      bool eager = false,
    }) => pb.FunctionCall(
      callId: id,
      functionName: name,
      allowEagerAwait: eager,
      values: pb.Arena(),
    );

    test(
      'a throwing parity callback keeps Python Exception, while an opaque '
      'parity return gives TypeError (C-4)',
      () async {
        final host = HostAnswers(
          externalLookup: {
            'throws_state': MontyHostFunction.parity(
              'throws_state',
              (_, _) => throw StateError('from callback'),
            ),
            'throws_unsupported': MontyHostFunction.parity(
              'throws_unsupported',
              (_, _) => throw UnsupportedError('from callback'),
            ),
            'throws_coro': MontyHostFunction.parity(
              'throws_coro',
              parityCoroutine(
                (_, _) async => throw UnsupportedError('from coroutine'),
              ),
            ),
            'opaque_object': MontyHostFunction.parity(
              'opaque_object',
              (_, _) => Object(),
            ),
            'opaque_custom': MontyHostFunction.parity(
              'opaque_custom',
              (_, _) => const _Opaque(),
            ),
            'opaque_coro': MontyHostFunction.parity(
              'opaque_coro',
              parityCoroutine((_, _) async => Object()),
            ),
            'returns_null': MontyHostFunction.parity(
              'returns_null',
              (_, _) => null,
            ),
            'returns_null_coro': MontyHostFunction.parity(
              'returns_null_coro',
              parityCoroutine((_, _) async => null),
            ),
          },
        );

        final thrownState = (await host.call(
          callTo('throws_state'),
        )).resumeCall.result.error;
        expect(thrownState.excType, 'Exception');
        expect(thrownState.message, 'Bad state: from callback');

        final thrownUnsupported = (await host.call(
          callTo('throws_unsupported'),
        )).resumeCall.result.error;
        expect(thrownUnsupported.excType, 'Exception');
        expect(
          thrownUnsupported.message,
          'Unsupported operation: from callback',
        );

        final thrownCoro = onlyItem(
          (await host.call(
            callTo('throws_coro', eager: true),
          )).resumeFutures.results,
        ).result.error;
        expect(thrownCoro.excType, 'Exception');
        expect(
          thrownCoro.message,
          'Unsupported operation: from coroutine',
        );

        final opaqueObject = (await host.call(
          callTo('opaque_object'),
        )).resumeCall.result.error;
        expect(opaqueObject.excType, 'TypeError');
        expect(
          opaqueObject.message,
          'Cannot convert builtins.object to Monty value — wrap class '
          'instances in pydantic_monty.ClassInstance(...)',
        );

        final opaqueCustom = (await host.call(
          callTo('opaque_custom'),
        )).resumeCall.result.error;
        expect(opaqueCustom.excType, 'TypeError');
        expect(
          opaqueCustom.message,
          'Cannot convert ${const _Opaque().runtimeType} to Monty value — '
          'wrap class instances in pydantic_monty.ClassInstance(...)',
        );

        final opaqueCoro = onlyItem(
          (await host.call(
            callTo('opaque_coro', eager: true),
          )).resumeFutures.results,
        ).result.error;
        expect(opaqueCoro.excType, 'TypeError');
        expect(
          opaqueCoro.message,
          'Cannot convert builtins.object to Monty value — wrap class '
          'instances in pydantic_monty.ClassInstance(...)',
        );

        final nullSync = (await host.call(callTo('returns_null'))).resumeCall;
        expect(nullSync.result.hasReturnValue(), isTrue);
        expect(
          itemAt(nullSync.values.nodes, nullSync.result.returnValue).hasNone(),
          isTrue,
        );

        final nullCoro = (await host.call(
          callTo('returns_null_coro', eager: true),
        )).resumeFutures;
        final nullCoroResult = onlyItem(nullCoro.results).result;
        expect(nullCoroResult.hasReturnValue(), isTrue);
        expect(
          itemAt(
            nullCoro.values.nodes,
            nullCoroResult.returnValue,
          ).hasNone(),
          isTrue,
        );
      },
    );

    test(
      'isCoroutine reports coroutine marking and a legacy null ExternalAnswer '
      'gives RuntimeError',
      () {
        MontyValue plain(List<MontyValue> args, Map<String, MontyValue> kw) =>
            args.firstOrNull ?? kw['x'] ?? const MontyNone();
        final marked = coroutine(plain);
        expect(isCoroutine(plain), isFalse);
        expect(isCoroutine(marked), isTrue);

        final legacyNull = futuresRequest(const [
          (1, ExternalAnswer.value(null)),
        ]).resumeFutures;
        expect(
          onlyItem(legacyNull.results).result.error.excType,
          'RuntimeError',
        );

        final parityNull = futuresRequest(const [
          (1, ExternalAnswer.value(null, parity: true)),
        ]).resumeFutures;
        final parityResult = onlyItem(parityNull.results).result;
        expect(parityResult.hasReturnValue(), isTrue);
        expect(
          itemAt(parityNull.values.nodes, parityResult.returnValue).hasNone(),
          isTrue,
        );
      },
    );
  });
}

/// One OS call a v1.2.0 worker sends, and what the host must see of it.
final class _Case {
  const _Case(this.reason, this.call, this.name, this.args, this.kwargs);

  /// What the case is about, as a failure message says.
  final String reason;

  /// The call, as the scanner read it.
  final pb.OsCall call;

  /// The OS function's name.
  final String name;

  /// Its positional arguments.
  final List<MontyValue> args;

  /// Its keyword arguments.
  final Map<String, MontyValue> kwargs;
}

/// A varint, as the wire carries it.
List<int> _varint(int value) {
  final out = <int>[];
  var rest = value;
  do {
    var byte = rest & 0x7f;
    rest >>= 7;
    if (rest != 0) byte |= 0x80;
    out.add(byte);
  } while (rest != 0);

  return out;
}

/// The tag of the field [number], with the wire type [wire].
List<int> _tag(int number, int wire) => _varint((number << 3) | wire);

/// A varint field [number] holding [value].
List<int> _varintField(int number, int value) => [
  ..._tag(number, 0),
  ..._varint(value),
];

/// A length-delimited field [number] holding [bytes].
List<int> _bytesField(int number, List<int> bytes) => [
  ..._tag(number, 2),
  ..._varint(bytes.length),
  ...bytes,
];

/// A length-delimited field [number] holding the UTF-8 of [text].
List<int> _stringField(int number, String text) =>
    _bytesField(number, utf8.encode(text));

/// The `ChildEvent` frame carrying the OS call [body]: `os_call` is
/// field 3 of a child event.
Uint8List _osCallFrame(List<int> body) =>
    Uint8List.fromList(_bytesField(3, body));

/// The OS call in the raw frame [frame], as the scanner reads it.
pb.OsCall _scanned(Uint8List frame) => FrameScan.decodeChildEvent(frame).osCall;

/// An `OsCall` body: the call's id and the arm it carries.
List<int> _osCallBody(int id, List<int> arm) => [
  ..._varintField(1, id),
  ...arm,
];

/// The `import` arm (field 31): the module [module].
List<int> _importArm(String module) => _bytesField(31, _stringField(1, module));

/// The `import_stubs` arm (field 32): the modules [modules], in order.
List<int> _importStubsArm(List<String> modules) => _bytesField(
  32,
  [for (final module in modules) ..._stringField(1, module)],
);

/// The `scan` arm (field 33): the path and the arguments beside it.
///
/// An absent [maxDepth] and an absent [caseSensitive] are left out of the
/// frame, as upstream's `optional` fields are; a depth of zero and a case
/// sensitivity of false are written, so the two are told apart.
List<int> _scanArm(
  String path, {
  int? maxDepth,
  bool followSymlinks = false,
  List<String> pattern = const [],
  bool? caseSensitive,
  bool recurseSymlinks = false,
}) => _bytesField(33, [
  ..._stringField(1, path),
  if (maxDepth != null) ..._varintField(2, maxDepth),
  ..._varintField(3, followSymlinks ? 1 : 0),
  for (final part in pattern) ..._stringField(4, part),
  if (caseSensitive != null) ..._varintField(5, caseSensitive ? 1 : 0),
  ..._varintField(6, recurseSymlinks ? 1 : 0),
]);

/// Whether [answer] refuses the call: it throws, as an invalid payload
/// does, or answers with an error.
Future<bool> _refused(Future<pb.ParentRequest> answer) async {
  try {
    final reply = await answer;

    return reply.resumeCall.result.hasError();
  } on Object {
    return true;
  }
}

/// A timer that runs only when the test fires it.
final class _HeldTimer implements Timer {
  _HeldTimer(this._callback);

  final void Function() _callback;
  bool _isActive = true;

  /// Runs the callback now, unless cancelled or already run.
  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _callback();
  }

  @override
  void cancel() => _isActive = false;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _isActive ? 0 : 1;
}

/// A throw whose text cannot be rendered.
final class _BadText implements Exception {
  const _BadText();

  @override
  String toString() => throw StateError('no text');
}

/// A live external-module map whose lookup fails.
final class _ThrowingModuleMap extends MapBase<String, Object?> {
  const _ThrowingModuleMap();

  @override
  Object? operator [](Object? key) => throw const FormatException(
    'module lookup failed',
  );

  @override
  void operator []=(String key, Object? value) => throw UnimplementedError();

  @override
  Iterable<String> get keys => const [];

  @override
  void clear() => throw UnimplementedError();

  @override
  Object? remove(Object? key) => throw UnimplementedError();
}

/// An unconvertible custom Dart object.
final class _Opaque {
  const _Opaque();
}

/// A call of [name]: [args] are its positional arguments, and [objectId]
/// names the host object the call is a method call on.
pb.FunctionCall _callTo(
  String name, {
  int id = 1,
  List<int> args = const [],
  String? objectId,
}) => pb.FunctionCall(
  callId: id,
  functionName: name,
  objectId: objectId == null ? null : pb.Uuid(data: _uuidBytes(objectId)),
  values: pb.Arena(
    nodeCount: args.length,
    nodes: [for (final arg in args) intNode(arg)],
  ),
  args: [for (var i = 0; i < args.length; i++) i],
);

/// The bytes of the uuid [id], as the wire carries it.
List<int> _uuidBytes(String id) => [
  for (var i = 0; i < 32; i += 2)
    int.parse(id.replaceAll('-', '').substring(i, i + 2), radix: 16),
];

/// The value [call] returned, or null when it returned none.
MontyValue? _value(pb.ResumeCall call) {
  final result = call.result;
  if (!result.hasReturnValue()) return null;

  return ArenaReader(call.values)[result.returnValue];
}

/// Whether [call] answered that the name was not found.
bool _notFound(pb.ResumeCall call) => call.result.hasNotFound();

/// The result the settled future of the call [callId] carries, or a
/// failure naming what settled instead.
pb.ExtFunctionResult _settledResult(
  Map<int, pb.ExtFunctionResult> settled,
  int callId,
) {
  final result = settled[callId];
  if (result == null) {
    fail('no settled future for the call $callId, got ${settled.keys}');
  }

  return result;
}

/// A gate the test opens: the coroutine that waits for it can only finish
/// once the other one has started.
final class _Gate {
  final Completer<void> _opened = Completer<void>();
  bool _isOpen = false;

  /// Opens the gate.
  void open() {
    if (_isOpen) return;
    _isOpen = true;
    _opened.complete();
  }

  /// Waits for the gate to open.
  Future<void> wait() => _opened.future;
}

/// The receiver the object-id path calls: its method answers [answer].
final class _Counter {
  const _Counter(this.ran, this.answer);

  /// The names of the callbacks that ran.
  final List<String> ran;

  /// What the method answers.
  final int answer;
}

/// The class of the receiver the object-id path calls.
final HostClass<_Counter> _counterClass = HostClass(
  'Counter',
  instance: (
    fields: <String, Never>{},
    properties: <String, Never>{},
    methods: {
      'pkg.sub.add': (c, args, kwargs) {
        c.ran.add('object.add');

        return MontyInt(c.answer);
      },
    },
  ),
);

/// The identity of the receiver the object-id path calls.
const String _counterId = '00000000-0000-4000-8000-000000000001';

/// The identity of the class of that receiver.
const String _counterClassId = '00000000-0000-4000-8000-000000000002';
