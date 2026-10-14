// Host objects (host_objects.dart): the wrappers' policies, the per-session
// registry's invariants, the member guard ahead of any host code, and the
// writer's and reader's handling of the wrappers.
// Pure Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '../../_accessors.dart';

final class _Box {
  _Box(this.n);

  int n;
}

/// Every host callback that ran, by name.
final List<String> _ran = [];

final HostClass<_Box> _boxClass = HostClass(
  'Box',
  instance: HostMembers(
    fields: {
      'n': (b) {
        _ran.add('n');

        return MontyInt(b.n);
      },
    },
    properties: {
      '_hidden': (b) {
        _ran.add('_hidden');

        return const MontyInt(0);
      },
    },
    methods: {
      'bump': (b, args, kwargs) {
        _ran.add('bump');

        return MontyInt(++b.n);
      },
      '_secret': (b, args, kwargs) {
        _ran.add('_secret');

        return const MontyString('secret');
      },
    },
  ),
  construct: _newBox,
);

_Box _newBox(List<MontyValue> args, Map<String, MontyValue> kwargs) {
  _ran.add('__call__');

  return _Box(0);
}

const _all = HostPolicies(
  eagerAttrs: 'all',
  lazyAttrs: 'all',
  allowedMethods: 'all',
);

String _id(int n) =>
    '00000000-0000-0000-0000-${n.toRadixString(16).padLeft(12, '0')}';

pb.Uuid _wire(String id) => pb.Uuid(
  data: [
    for (var i = 0; i < 32; i += 2)
      int.parse(id.replaceAll('-', '').substring(i, i + 2), radix: 16),
  ],
);

ClassInstance<_Box> _box(int id, {_Box? value, HostPolicies policies = _all}) =>
    ClassInstance(
      value ?? _Box(1),
      classType: ClassType(_boxClass, id: _id(100)),
      id: _id(id),
      policies: policies,
    );

/// A host answering for [objects].
HostAnswers _host(HostObjects objects) => HostAnswers(objects: objects);

pb.FunctionCall _call(String name, String id) => pb.FunctionCall(
  functionName: name,
  callId: 1,
  objectId: _wire(id),
  values: pb.Arena(),
);

/// The exception [request] answers its call with.
pb.RaisedException _raised(pb.ParentRequest request) =>
    request.resumeCall.result.error;

/// A class whose property raises on the host.
final HostClass<_Box> _raising = HostClass(
  'Box',
  instance: HostMembers(
    properties: {
      'boom': (b) => throw const ExternalException('KeyError', 'boom'),
    },
  ),
);

/// A class with an async method.
final HostClass<_Box> _slow = HostClass(
  'Box',
  instance: HostMembers(
    methods: {
      'later': (b, args, kwargs) => Future.value(const MontyInt(5)),
    },
  ),
);

/// The first box's id, and the box class's.
final String _one = _id(1);
final String _classId = _id(100);

/// Throws an [ArgumentError] whose message matches [message].
Matcher _argumentError(Object message) => throwsA(
  isA<ArgumentError>().having((e) => e.message, 'message', message),
);

void main() {
  setUp(_ran.clear);

  group('policies', () {
    test('a bare string other than all is refused, as upstream', () {
      expect(
        () => ClassInstance(
          _Box(1),
          classType: ClassType(_boxClass),
          policies: const HostPolicies(lazyAttrs: 'n'),
        ),
        _argumentError(
          "lazy_attrs must be 'all', None or a set of names, got 'n'",
        ),
      );
      expect(
        () => ClassType(
          _boxClass,
          instancePolicies: const HostPolicies(eagerAttrs: 'x'),
        ),
        _argumentError(contains('instance_eager_attrs must be')),
      );
    });

    test('a class keeps one default id; an instance gets a fresh one', () {
      final first = ClassType(_boxClass);
      final second = ClassType(_boxClass);
      expect(first.id, second.id);
      final a = ClassInstance(_Box(1), classType: first);
      final b = ClassInstance(_Box(1), classType: second);
      expect(a.id, isNot(b.id));
      expect(a.id, matches(RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-4')));
    });

    test('an id that is not a uuid is refused', () {
      expect(
        () => ClassType(_boxClass, id: 'nope'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('the registry (upstream InstanceStore)', () {
    test('instances and classes share one id namespace', () {
      final objects = HostObjects()..register(_box(1));
      expect(
        () => objects.register(ClassType(_boxClass, id: _id(1))),
        throwsA(
          isA<PythonRefusal>().having(
            (e) => e.excType,
            'excType',
            'ValueError',
          ),
        ),
      );
    });

    test('the same object re-sent with a new wrapper replaces its policy', () {
      final box = _Box(1);
      final closed = _box(1, value: box, policies: HostPolicies.none);
      final open = _box(1, value: box);
      final objects = HostObjects()
        ..register(closed)
        ..register(open);
      expect(objects[_one], same(open));
    });

    test('an id bound to a different object is refused', () {
      final objects = HostObjects()..register(_box(1));
      expect(
        () => objects.register(_box(1)),
        throwsA(
          isA<PythonRefusal>().having(
            (e) => e.text,
            'text',
            'wrapper id $_one already identifies a different object in '
                'this session',
          ),
        ),
      );
    });

    test('the class an instance implies never replaces a granted one', () {
      final granted = ClassType(_boxClass, id: _classId, init: true);
      final objects = HostObjects()..register(granted);
      ArenaWriter(objects: objects).add(_box(1));
      expect(objects[_classId], same(granted));
      // An absent class is registered by its instance.
      final fresh = HostObjects();
      final box = _box(2);
      ArenaWriter(objects: fresh).add(box);
      expect(fresh[_classId], same(box.classType));
    });

    test("an unknown receiver, or another session's, is refused", () async {
      final mine = HostObjects();
      ArenaWriter(objects: mine).add(_box(1));
      _ran.clear();
      final other = _host(HostObjects());
      final bump = _call('bump', _one);
      final raised = _raised(await other.call(bump));
      expect(raised.excType, 'RuntimeError');
      expect(
        raised.message,
        contains("no host object registered for method call 'bump'"),
      );
      final lookup = other.lookup('n', objectId: _one);
      expect(lookup.resumeNameLookup.hasUndefined(), isTrue);
      expect(_ran, isEmpty);
      // The control: the session that sent it routes the call.
      final routed = await _host(mine).call(bump);
      expect(routed.resumeCall.result.hasReturnValue(), isTrue);
      expect(_ran, ['bump']);
    });
  });

  group('the member guard runs before any host code', () {
    late HostObjects objects;
    setUp(() {
      objects = HostObjects();
      ArenaWriter(objects: objects).add(_box(1));
      ArenaWriter(objects: objects).add(
        ClassType(_boxClass, id: _classId, init: true),
      );
      _ran.clear();
    });

    for (final name in ['_secret', '__init__', '__getattr__', '_']) {
      test('a method named $name is refused, nothing run', () async {
        final raised = _raised(await _host(objects).call(_call(name, _one)));
        expect(raised.excType, 'AttributeError');
        expect(raised.message, "host method '$name' is not exposed");
        expect(_ran, isEmpty);
      });
    }

    test('a lazy attribute named _hidden is undefined, nothing run', () {
      final answer = _host(objects).lookup('_hidden', objectId: _one);
      expect(answer.resumeNameLookup.hasUndefined(), isTrue);
      expect(_ran, isEmpty);
    });

    test('controls: a public member, and construction', () async {
      final host = _host(objects);
      final bumped = await host.call(_call('bump', _one));
      expect(bumped.resumeCall.result.hasReturnValue(), isTrue);
      final built = await host.call(_call('__call__', _classId));
      expect(built.resumeCall.result.hasReturnValue(), isTrue);
      expect(_ran, ['bump', '__call__']);
    });

    test('__call__ on an instance is refused by its policy', () async {
      final answer = await _host(objects).call(_call('__call__', _one));
      expect(
        _raised(answer).message,
        "'Box' object has no attribute '__call__'",
      );
      expect(_ran, isEmpty);
    });
  });

  group('lazy attributes', () {
    test('a raise other than AttributeError reaches the sandbox', () {
      final objects = HostObjects();
      final id = _id(3);
      ArenaWriter(objects: objects).add(
        ClassInstance(
          _Box(1),
          classType: ClassType(_raising),
          id: id,
          policies: _all,
        ),
      );
      final answer = _host(objects).lookup('boom', objectId: id);
      final error = answer.resumeNameLookup.error;
      expect(error.excType, 'KeyError');
      expect(error.message, 'boom');
    });

    test('an async method is a coroutine', () async {
      final objects = HostObjects();
      ArenaWriter(objects: objects).add(
        ClassInstance(
          _Box(1),
          classType: ClassType(_slow),
          id: _id(4),
          policies: _all,
        ),
      );
      final answer = await _host(objects).call(_call('later', _id(4)));
      expect(answer.resumeCall.result.future, 1);
    });
  });

  group('the writer and the reader', () {
    test('one wrapper is one node; its class is shared by id', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final box = _box(1, policies: HostPolicies.none);
      final other = _box(2, policies: HostPolicies.none);
      final a = writer.add(box);
      expect(writer.add(box), a);
      final b = writer.add(other);
      expect(b, isNot(a));
      final nodes = writer.arena.nodes;
      expect(
        itemAt(nodes, a).classInstance.classType,
        itemAt(nodes, b).classInstance.classType,
      );
    });

    test('a value that is not a MontyValue or a wrapper is a TypeError', () {
      expect(
        () => ArenaWriter(objects: HostObjects()).add(_Box(1)),
        throwsA(
          isA<PythonRefusal>().having((e) => e.excType, 'excType', 'TypeError'),
        ),
      );
    });

    test('a wrapper without a session to register in is refused', () {
      expect(() => ArenaWriter().add(_box(1)), throwsArgumentError);
    });

    test('tryAdd leaves the arena as it was on a refusal', () {
      final writer = ArenaWriter(objects: HostObjects())
        ..add(const MontyInt(1));
      expect(
        () => writer.tryAdd(MontyList([_selfNested()])),
        throwsA(anything),
      );
      expect(writer.arena.nodes, hasLength(1));
      expect(writer.arena.nodeCount, 1);
    });

    test('a registered instance decodes to a proxy that recovers it', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final box = _box(1);
      final index = writer.add(box);
      final bytes = writer.arena.writeToBuffer();
      final reader = ArenaReader(
        pb.Arena.fromBuffer(bytes),
        hosts: objects.lookup,
      );
      final decoded = reader[index];
      expect(decoded, isA<MontyClassInstance>());
      expect(hostObjectOf(decoded), same(box));
      // An unregistered reader gives a plain proxy.
      final plain = ArenaReader(pb.Arena.fromBuffer(bytes))[index];
      expect(hostObjectOf(plain), isNull);
      expect(hostObjectOf(const MontyInt(1)), isNull);
    });
  });

  test(
    'a registered instance passed to a host function keeps its object',
    () async {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final box = _box(1);
      final index = writer.add(box);
      Object? seen;
      final host = HostAnswers(
        objects: objects,
        externals: {
          'f': (args, kwargs) {
            seen = hostObjectOf(onlyItem(args));

            return const MontyNone();
          },
        },
      );
      await host.call(
        pb.FunctionCall(
          functionName: 'f',
          callId: 1,
          args: [index],
          values: writer.arena,
        ),
      );
      expect(seen, same(box));
    },
  );
}

/// A MontyValue the writer cannot send: a list nested in itself.
MontyValue _selfNested() {
  final items = <MontyValue>[];
  final list = MontyList(items);
  items.add(list);

  return list;
}
