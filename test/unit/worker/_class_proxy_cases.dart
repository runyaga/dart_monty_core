// Class proxies across a real worker boundary, shared by native and browser
// runners.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show montyClassProxy, montyClassTypeProxy;
import 'package:test/test.dart';

typedef WithClassProxySession =
    Future<void> Function(Future<void> Function(MontySession session) body);

const _hostClassId = '0123abcd-0000-4000-8000-00000000cafe';
const _hostInstanceId = 'fedcba98-7654-4000-8000-00000000face';

MontyClassTypeProxy _hostClass({
  String name = 'Remote',
  bool isDataclass = false,
  Map<String, MontyValue> attrs = const {'source': MontyString('host')},
}) => montyClassTypeProxy(
  name: name,
  id: _hostClassId,
  hostDefined: true,
  isDataclass: isDataclass,
  attrs: attrs,
);

MontyClassProxy _hostInstance() => montyClassProxy(
  classType: _hostClass(),
  instanceId: _hostInstanceId,
  attrs: const {'value': MontyInt(7)},
);

final class _HostBox {
  const _HostBox();
}

final HostClass<_HostBox> _hostBoxClass = HostClass(
  'HostBox',
  instance: (
    fields: {'hidden': (_) => const MontyInt(1)},
    properties: const {},
    methods: {
      'explode': (_, _, _) =>
          throw const ExternalException('ValueError', 'host method failed'),
    },
  ),
);

ClassInstance<_HostBox> _hostBox({
  ({Object? eagerAttrs, Object? lazyAttrs, Object? allowedMethods}) policies =
      const (eagerAttrs: null, lazyAttrs: null, allowedMethods: null),
}) => ClassInstance(
  const _HostBox(),
  classType: ClassType(_hostBoxClass),
  policies: policies,
);

void classProxySessionTests(
  String label,
  WithClassProxySession withSession,
) {
  group('class instances ($label)', () {
    test('an allowed method exception is catchable in the sandbox', () async {
      await withSession((session) async {
        final result = await session.feedRun(
          'try:\n'
          '    value.explode()\n'
          'except ValueError as error:\n'
          '    caught = (type(error).__name__, str(error))\n'
          'caught',
          inputs: {
            'value': _hostBox(
              policies: const (
                eagerAttrs: null,
                lazyAttrs: null,
                allowedMethods: ['explode'],
              ),
            ),
          },
        );

        const expected = MontyTuple([
          MontyString('ValueError'),
          MontyString('host method failed'),
        ]);
        expect(result, expected);
      });
    });

    test(
      'a method conversion hook exception is catchable in the sandbox',
      () async {
        late final HostClass<_HostBox> hostClass;
        hostClass = HostClass(
          'ConvertedInstance',
          instance: (
            fields: const {},
            properties: const {},
            methods: {'convert': (_, _, _) => const MontyInt(1)},
          ),
        );
        final value = ClassInstance(
          const _HostBox(),
          classType: ClassType(hostClass),
          policies: const (
            eagerAttrs: null,
            lazyAttrs: null,
            allowedMethods: ['convert'],
          ),
          convertValue: (_, _) =>
              throw const ExternalException('ValueError', 'conversion failed'),
        );
        await withSession((session) async {
          final result = await session.feedRun(
            'try:\n'
            '    value.convert()\n'
            'except ValueError as error:\n'
            '    caught = (type(error).__name__, str(error))\n'
            'caught',
            inputs: {'value': value},
          );

          expect(
            result,
            const MontyTuple([
              MontyString('ValueError'),
              MontyString('conversion failed'),
            ]),
          );
        });
      },
    );

    test(
      'a method return conversion exception is catchable in the sandbox',
      () async {
        late final HostClass<_HostBox> hostClass;
        hostClass = HostClass(
          'UnencodableInstance',
          instance: (
            fields: const {},
            properties: const {},
            methods: {'return_value': (_, _, _) => const _HostBox()},
          ),
        );
        final value = ClassInstance(
          const _HostBox(),
          classType: ClassType(hostClass),
          policies: const (
            eagerAttrs: null,
            lazyAttrs: null,
            allowedMethods: ['return_value'],
          ),
        );
        await withSession((session) async {
          final result = await session.feedRun(
            'try:\n'
            '    value.return_value()\n'
            'except TypeError:\n'
            "    caught = 'converted'\n"
            'caught',
            inputs: {'value': value},
          );

          expect(result, const MontyString('converted'));
        });
      },
    );

    test('method AttributeErrors stay errors in the sandbox', () async {
      late final HostClass<_HostBox> badResultClass;
      badResultClass = const HostClass(
        'UnencodableResult',
        instance: (
          fields: {},
          properties: {},
          methods: {},
        ),
      );
      final badResult = ClassInstance(
        const _HostBox(),
        classType: ClassType(badResultClass),
        policies: const (
          eagerAttrs: ['missing'],
          lazyAttrs: null,
          allowedMethods: null,
        ),
      );
      late final HostClass<_HostBox> hostClass;
      hostClass = HostClass(
        'AttributeErrors',
        instance: (
          fields: const {},
          properties: const {},
          methods: {
            'body': (_, _, _) =>
                throw const ExternalException('AttributeError', 'body'),
            'hook': (_, _, _) => const MontyInt(1),
            'result': (_, _, _) => badResult,
          },
        ),
      );
      final value = ClassInstance(
        const _HostBox(),
        classType: ClassType(hostClass),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: ['body', 'hook', 'result'],
        ),
        convertValue: (name, item) => name == 'hook'
            ? throw const ExternalException('AttributeError', 'hook')
            : item,
      );
      await withSession((session) async {
        final result = await session.feedRun(
          'caught = []\n'
          'try:\n'
          '    value.body()\n'
          'except AttributeError as error:\n'
          '    caught.append(str(error))\n'
          'try:\n'
          '    value.hook()\n'
          'except AttributeError as error:\n'
          '    caught.append(str(error))\n'
          'try:\n'
          '    value.result()\n'
          'except AttributeError as error:\n'
          '    caught.append(str(error))\n'
          'tuple(caught)',
          inputs: {'value': value},
        );

        expect(
          result,
          const MontyTuple([
            MontyString('body'),
            MontyString('hook'),
            MontyString(
              "'UnencodableResult' object has no attribute 'missing'",
            ),
          ]),
        );
      });
    });

    test('async method exceptions are catchable in the sandbox', () async {
      late final HostClass<_HostBox> hostClass;
      hostClass = HostClass(
        'AsyncInstance',
        instance: (
          fields: const {},
          properties: const {},
          methods: {
            'body': (_, _, _) => Future<Object>.error(
              const ExternalException('ValueError', 'body'),
            ),
            'hook': (_, _, _) => Future<Object>.value(const MontyInt(1)),
            'result': (_, _, _) => Future<Object>.value(const _HostBox()),
          },
        ),
      );
      final value = ClassInstance(
        const _HostBox(),
        classType: ClassType(hostClass),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: ['body', 'hook', 'result'],
        ),
        convertValue: (name, item) => name == 'hook'
            ? throw const ExternalException('ValueError', 'hook')
            : item,
      );
      await withSession((session) async {
        final result = await session.feedRun(
          'async def catches():\n'
          '    caught = []\n'
          '    try:\n'
          '        await value.body()\n'
          '    except ValueError:\n'
          "        caught.append('body')\n"
          '    try:\n'
          '        await value.hook()\n'
          '    except ValueError:\n'
          "        caught.append('hook')\n"
          '    try:\n'
          '        await value.result()\n'
          '    except TypeError:\n'
          "        caught.append('result')\n"
          '    return tuple(caught)\n'
          'await catches()',
          inputs: {'value': value},
        );

        expect(
          result,
          const MontyTuple([
            MontyString('body'),
            MontyString('hook'),
            MontyString('result'),
          ]),
        );
      });
    });

    test(
      'lazy AttributeErrors make hasattr false and select getattr defaults',
      () async {
        late final HostClass<_HostBox> hostClass;
        hostClass = HostClass(
          'MissingAttributes',
          instance: (
            fields: {
              'body': (_) =>
                  throw const ExternalException('AttributeError', 'body'),
              'hook': (_) => const MontyInt(1),
            },
            properties: const {},
            methods: const {},
          ),
        );
        final value = ClassInstance(
          const _HostBox(),
          classType: ClassType(hostClass),
          policies: const (
            eagerAttrs: null,
            lazyAttrs: 'all',
            allowedMethods: null,
          ),
          convertValue: (name, item) => name == 'hook'
              ? throw const ExternalException('AttributeError', 'hook')
              : item,
        );
        await withSession((session) async {
          final result = await session.feedRun(
            '(hasattr(value, "body"), hasattr(value, "hook"), '
            'getattr(value, "body", "body default"), '
            'getattr(value, "hook", "hook default"))',
            inputs: {'value': value},
          );

          expect(
            result,
            const MontyTuple([
              MontyBool(false),
              MontyBool(false),
              MontyString('body default'),
              MontyString('hook default'),
            ]),
          );
        });
      },
    );

    test(
      'other lazy attribute errors bypass hasattr and getattr defaults',
      () async {
        late final HostClass<_HostBox> hostClass;
        hostClass = HostClass(
          'FailingAttributes',
          instance: (
            fields: {
              'body': (_) => throw const ExternalException('KeyError', 'body'),
              'hook': (_) => const MontyInt(1),
            },
            properties: const {},
            methods: const {},
          ),
        );
        final value = ClassInstance(
          const _HostBox(),
          classType: ClassType(hostClass),
          policies: const (
            eagerAttrs: null,
            lazyAttrs: 'all',
            allowedMethods: null,
          ),
          convertValue: (name, item) => name == 'hook'
              ? throw const ExternalException('KeyError', 'hook')
              : item,
        );
        await withSession((session) async {
          final result = await session.feedRun(
            'caught = []\n'
            'try:\n'
            '    hasattr(value, "body")\n'
            'except KeyError as error:\n'
            '    caught.append(str(error))\n'
            'try:\n'
            '    getattr(value, "body", "default")\n'
            'except KeyError as error:\n'
            '    caught.append(str(error))\n'
            'try:\n'
            '    hasattr(value, "hook")\n'
            'except KeyError as error:\n'
            '    caught.append(str(error))\n'
            'try:\n'
            '    getattr(value, "hook", "default")\n'
            'except KeyError as error:\n'
            '    caught.append(str(error))\n'
            'tuple(caught)',
            inputs: {'value': value},
          );

          expect(
            result,
            const MontyTuple([
              MontyString("'body'"),
              MontyString("'body'"),
              MontyString("'hook'"),
              MontyString("'hook'"),
            ]),
          );
        });
      },
    );

    test('an unhandled host SyntaxError becomes a syntax error', () async {
      late final HostClass<_HostBox> hostClass;
      hostClass = HostClass(
        'SyntaxFailure',
        instance: (
          fields: const {},
          properties: const {},
          methods: {
            'fail': (_, _, _) =>
                throw const ExternalException('SyntaxError', 'host syntax'),
          },
        ),
      );
      final value = ClassInstance(
        const _HostBox(),
        classType: ClassType(hostClass),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: ['fail'],
        ),
      );
      await withSession((session) async {
        await expectLater(
          session.feedRun('value.fail()', inputs: {'value': value}),
          throwsA(
            isA<MontySyntaxError>().having(
              (error) => error.exception.message,
              'exception message',
              'host syntax',
            ),
          ),
        );
      });
    });

    test('an unhandled host exception becomes a runtime error', () async {
      late final HostClass<_HostBox> hostClass;
      hostClass = HostClass(
        'RuntimeFailure',
        instance: (
          fields: const {},
          properties: const {},
          methods: {
            'fail': (_, _, _) =>
                throw const ExternalException('ValueError', 'host value'),
          },
        ),
      );
      final value = ClassInstance(
        const _HostBox(),
        classType: ClassType(hostClass),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: ['fail'],
        ),
      );
      await withSession((session) async {
        await expectLater(
          session.feedRun('value.fail()', inputs: {'value': value}),
          throwsA(
            isA<MontyRuntimeError>()
                .having(
                  (error) => error.exception.excType,
                  'exception type',
                  'ValueError',
                )
                .having(
                  (error) => error.exception.message,
                  'exception message',
                  'host value',
                ),
          ),
        );
      });
    });

    test(
      'a session remains usable after an unhandled host exception',
      () async {
        late final HostClass<_HostBox> hostClass;
        hostClass = HostClass(
          'RecoverableFailure',
          instance: (
            fields: const {},
            properties: const {},
            methods: {
              'fail': (_, _, _) =>
                  throw const ExternalException('ValueError', 'host value'),
            },
          ),
        );
        final value = ClassInstance(
          const _HostBox(),
          classType: ClassType(hostClass),
          policies: const (
            eagerAttrs: null,
            lazyAttrs: null,
            allowedMethods: ['fail'],
          ),
        );
        await withSession((session) async {
          await expectLater(
            session.feedRun('value.fail()', inputs: {'value': value}),
            throwsA(isA<MontyRuntimeError>()),
          );

          expect(await session.feedRun('6 * 7'), const MontyInt(42));
        });
      },
    );

    test(
      'a live sandbox instance is reused without proxy attributes',
      () async {
        await withSession((session) async {
          final original =
              await session.feedRun(
                    'class Local:\n'
                    '    pass\n'
                    'saved = Local()\n'
                    'saved',
                  )
                  as MontyClassProxy;
          final supplied = montyClassProxy(
            classType: original.classType,
            instanceId: original.instanceId,
            attrs: const {'value': MontyInt(99)},
          );
          await session.feedRun('saved.value = 2');

          expect(
            await session.feedRun(
              'value is saved',
              inputs: {'value': supplied},
            ),
            const MontyBool(true),
          );
          expect(
            await session.feedRun('value.value', inputs: {'value': supplied}),
            const MontyInt(2),
          );
        });
      },
    );

    test(
      'a host-backed instance keeps its supplied identity and attributes',
      () async {
        await withSession((session) async {
          final supplied = _hostInstance();
          await session.feedRun('first = value', inputs: {'value': supplied});
          final result =
              await session.feedRun('value', inputs: {'value': supplied})
                  as MontyClassProxy;

          expect(result.instanceId, supplied.instanceId);
          expect(result.classType.id, supplied.classType.id);
          expect(result.classType.hostDefined, isTrue);
          expect(result.attrs, supplied.attrs);
          expect(
            await session.feedRun(
              'type(first) is type(value)',
              inputs: {'value': supplied},
            ),
            const MontyBool(true),
          );
        });
      },
    );

    test(
      'a missing sandbox instance raises and leaves its session usable',
      () async {
        late final MontyClassProxy proxy;
        await withSession((source) async {
          proxy =
              await source.feedRun(
                    'class Local:\n'
                    '    pass\n'
                    'Local()',
                  )
                  as MontyClassProxy;
        });
        await withSession((session) async {
          await expectLater(
            session.feedRun('value', inputs: {'value': proxy}),
            throwsA(
              isA<MontyRuntimeError>()
                  .having(
                    (error) => error.exception.excType,
                    'exception type',
                    'RuntimeError',
                  )
                  .having(
                    (error) => error.exception.message,
                    'exception message',
                    startsWith('invalid input type: '),
                  ),
            ),
          );
          expect(await session.feedRun('6 * 7'), const MontyInt(42));
        });
      },
    );

    test(
      'a restored host instance without a registration is a proxy',
      () async {
        late final Uint8List dump;
        await withSession((source) async {
          await source.feedRun('saved = value', inputs: {'value': _hostBox()});
          dump = await source.dump();
        });
        await withSession((session) async {
          await session.loadSession(dump);
          final decoded = await session.feedRun('saved');

          expect(decoded, isA<MontyClassProxy>());
        });
      },
    );

    test('a session dump leaves host wrapper registrations behind', () async {
      late final HostClass<_HostBox> instanceClass;
      instanceClass = HostClass(
        'SavedInstance',
        instance: (
          fields: const {},
          properties: const {},
          methods: {
            'describe': (_, _, _) => const MontyString('registered'),
          },
        ),
      );
      final instance = ClassInstance(
        const _HostBox(),
        classType: ClassType(instanceClass),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: ['describe'],
        ),
      );
      final type = ClassType(
        HostClass(
          'SavedType',
          methods: {'describe': (_, _) => const MontyString('registered')},
        ),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: ['describe'],
        ),
      );
      late final Uint8List dump;
      await withSession((source) async {
        expect(
          await source.feedRun(
            '(instance.describe(), type.describe())',
            inputs: {'instance': instance, 'type': type},
          ),
          const MontyTuple([
            MontyString('registered'),
            MontyString('registered'),
          ]),
        );
        await source.feedRun(
          'saved_instance = instance\n'
          'saved_type = type',
          inputs: {'instance': instance, 'type': type},
        );
        dump = await source.dump();
      });
      await withSession((restored) async {
        await restored.loadSession(dump);
        final result = await restored.feedRun(
          'missing = []\n'
          'try:\n'
          '    saved_instance.describe()\n'
          'except RuntimeError:\n'
          "    missing.append('instance')\n"
          'try:\n'
          '    saved_type.describe()\n'
          'except RuntimeError:\n'
          "    missing.append('type')\n"
          'tuple(missing)',
        );

        expect(
          result,
          const MontyTuple([
            MontyString('instance'),
            MontyString('type'),
          ]),
        );
      });
    });

    test(
      'a restored unregistered instance has absent lazy attributes',
      () async {
        late final Uint8List dump;
        await withSession((source) async {
          await source.feedRun(
            'saved = value',
            inputs: {
              'value': _hostBox(
                policies: const (
                  eagerAttrs: null,
                  lazyAttrs: ['hidden'],
                  allowedMethods: null,
                ),
              ),
            },
          );
          dump = await source.dump();
        });
        await withSession((session) async {
          await session.loadSession(dump);
          final result = await session.feedRun(
            'try:\n'
            '    saved.hidden\n'
            'except AttributeError:\n'
            "    result = 'absent'\n"
            'result',
          );

          expect(result, const MontyString('absent'));
        });
      },
    );
  });

  group('class types ($label)', () {
    test('construction forwards positional and keyword arguments', () async {
      final calls = <(List<MontyValue>, Map<String, MontyValue>)>[];
      late final HostClass<_HostBox> hostClass;
      hostClass = HostClass(
        'Constructed',
        construct: (args, kwargs) {
          calls.add((args, kwargs));

          return const _HostBox();
        },
      );
      final value = ClassType(
        hostClass,
        init: true,
      );
      await withSession((session) async {
        await session.feedRun(
          "(value(1, first='a'), value(2, second='b'))",
          inputs: {'value': value},
        );

        late final List<MontyValue> firstArgs;
        firstArgs = [const MontyInt(1)];
        late final Map<String, MontyValue> firstKwargs;
        firstKwargs = {
          'first': const MontyString('a'),
        };
        late final List<MontyValue> secondArgs;
        secondArgs = [const MontyInt(2)];
        late final Map<String, MontyValue> secondKwargs;
        secondKwargs = {
          'second': const MontyString('b'),
        };
        final callIterator = calls.iterator;
        final hasFirstCall = callIterator.moveNext();
        expect(hasFirstCall, isTrue);
        final firstCall = callIterator.current;
        expect(firstCall.$1, firstArgs);
        expect(firstCall.$2, firstKwargs);
        final hasSecondCall = callIterator.moveNext();
        expect(hasSecondCall, isTrue);
        final secondCall = callIterator.current;
        expect(secondCall.$1, secondArgs);
        expect(secondCall.$2, secondKwargs);
        final hasExtraCall = callIterator.moveNext();
        expect(hasExtraCall, isFalse);
      });
    });

    test('class method AttributeErrors stay errors in the sandbox', () async {
      late final HostClass<_HostBox> hostClass;
      hostClass = HostClass(
        'ClassAttributeErrors',
        methods: {
          'body': (_, _) =>
              throw const ExternalException('AttributeError', 'body'),
          'hook': (_, _) => const MontyInt(1),
        },
      );
      final value = ClassType(
        hostClass,
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: ['body', 'hook'],
        ),
        convertValue: (name, item) => name == 'hook'
            ? throw const ExternalException('AttributeError', 'hook')
            : item,
      );
      await withSession((session) async {
        final result = await session.feedRun(
          'caught = []\n'
          'try:\n'
          '    value.body()\n'
          'except AttributeError as error:\n'
          '    caught.append(str(error))\n'
          'try:\n'
          '    value.hook()\n'
          'except AttributeError as error:\n'
          '    caught.append(str(error))\n'
          'tuple(caught)',
          inputs: {'value': value},
        );

        expect(
          result,
          const MontyTuple([MontyString('body'), MontyString('hook')]),
        );
      });
    });

    test(
      'async class method exceptions are catchable in the sandbox',
      () async {
        final value = ClassType(
          HostClass(
            'AsyncClassMethods',
            methods: {
              'body': (_, _) => Future<Object>.error(
                const ExternalException('AttributeError', 'body'),
              ),
              'hook': (_, _) => Future<Object>.value(const MontyInt(1)),
              'result': (_, _) => Future<Object>.value(const _HostBox()),
            },
          ),
          policies: const (
            eagerAttrs: null,
            lazyAttrs: null,
            allowedMethods: ['body', 'hook', 'result'],
          ),
          convertValue: (name, item) => name == 'hook'
              ? throw const ExternalException('AttributeError', 'hook')
              : item,
        );
        await withSession((session) async {
          final result = await session.feedRun(
            'async def catches():\n'
            '    caught = []\n'
            '    try:\n'
            '        await value.body()\n'
            '    except AttributeError as error:\n'
            '        caught.append(str(error))\n'
            '    try:\n'
            '        await value.hook()\n'
            '    except AttributeError as error:\n'
            '        caught.append(str(error))\n'
            '    try:\n'
            '        await value.result()\n'
            '    except TypeError:\n'
            "        caught.append('result')\n"
            '    return tuple(caught)\n'
            'await catches()',
            inputs: {'value': value},
          );

          expect(
            result,
            const MontyTuple([
              MontyString('body'),
              MontyString('hook'),
              MontyString('result'),
            ]),
          );
        });
      },
    );

    test('a new host class takes its supplied metadata', () async {
      await withSession((session) async {
        final result = await session.feedRun(
          'import dataclasses\n'
          '(value.__name__, dataclasses.is_dataclass(value), value.source)',
          inputs: {
            'value': _hostClass(
              name: 'RemoteRecord',
              isDataclass: true,
              attrs: const {'source': MontyString('remote')},
            ),
          },
        );

        expect(
          result,
          const MontyTuple([
            MontyString('RemoteRecord'),
            MontyBool(true),
            MontyString('remote'),
          ]),
        );
      });
    });

    test('a host class is interned across feeds by its identity', () async {
      await withSession((session) async {
        final type = _hostClass();
        await session.feedRun('first = value', inputs: {'value': type});

        expect(
          await session.feedRun('first is value', inputs: {'value': type}),
          const MontyBool(true),
        );
      });
    });

    test(
      're-encoding a host class updates its metadata and attributes',
      () async {
        await withSession((session) async {
          await session.feedRun(
            'first = value',
            inputs: {
              'value': _hostClass(
                name: 'Before',
                attrs: const {'old': MontyInt(1)},
              ),
            },
          );

          final result = await session.feedRun(
            'import dataclasses\n'
            '(first is value, first.__name__, dataclasses.is_dataclass(first), '
            'hasattr(first, "old"), first.current)',
            inputs: {
              'value': _hostClass(
                name: 'After',
                isDataclass: true,
                attrs: const {'current': MontyInt(2)},
              ),
            },
          );

          expect(
            result,
            const MontyTuple([
              MontyBool(true),
              MontyString('After'),
              MontyBool(true),
              MontyBool(false),
              MontyInt(2),
            ]),
          );
        });
      },
    );

    test(
      're-encoding a host class with no attributes keeps its attributes',
      () async {
        await withSession((session) async {
          await session.feedRun(
            'first = value',
            inputs: {'value': _hostClass()},
          );

          final result = await session.feedRun(
            '(first is value, first.source)',
            inputs: {'value': _hostClass(attrs: const {})},
          );

          expect(
            result,
            const MontyTuple([MontyBool(true), MontyString('host')]),
          );
        });
      },
    );
  });
}
