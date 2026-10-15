// Host objects (host_objects.dart): the wrappers' policies, the per-session
// registry's invariants, the member guard ahead of any host code, and the
// writer's and reader's handling of the wrappers.
// Pure Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart';
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
  instance: (
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

/// The wrappers' policies, as a record.
typedef _Policies = ({
  Object? eagerAttrs,
  Object? lazyAttrs,
  Object? allowedMethods,
});

const _Policies _all = (
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

ClassInstance<_Box> _box(int id, {_Box? value, _Policies policies = _all}) =>
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
  instance: (
    fields: const {},
    properties: {
      'boom': (b) => throw const ExternalException('KeyError', 'boom'),
    },
    methods: const {},
  ),
);

/// A class with an async method.
final HostClass<_Box> _slow = HostClass(
  'Box',
  instance: (
    fields: const {},
    properties: const {},
    methods: {
      'later': (b, args, kwargs) => Future.value(const MontyInt(5)),
    },
  ),
);

/// A class with a class constant.
final HostClass<_Box> _constClass = HostClass(
  'Box',
  attributes: {'KIND': () => const MontyString('box')},
  methods: {'describe': (args, kwargs) => const MontyString('a box')},
);

/// A class with a callable field and a plain one.
final HostClass<_Box> _callableField = HostClass(
  'Box',
  instance: (
    fields: {
      'callback': (b) =>
          (List<MontyValue> args, Map<String, MontyValue> kw) =>
              const MontyInt(42),
      'number': (b) => const MontyInt(7),
    },
    properties: const {},
    methods: const {},
  ),
);

/// A class with a plain constant and one holding a function.
final HostClass<_Box> _callableConstant = HostClass(
  'Box',
  attributes: {
    'KIND': () => const MontyString('box'),
    'twice': () =>
        (List<MontyValue> args, Map<String, MontyValue> kw) =>
            const MontyInt(2),
  },
);

/// A class whose method `run` is shadowed by an instance field.
final HostClass<_Box> _shadowedMethod = HostClass(
  'Box',
  instance: (
    fields: {'run': (b) => const MontyInt(7)},
    properties: const {},
    methods: {'run': (b, args, kwargs) => const MontyInt(1)},
  ),
);

/// A class whose constant is a class, which has no value class yet.
final HostClass<_Box> _withClassConstant = HostClass(
  'Holder',
  attributes: {'OTHER': () => ClassType(_constClass)},
);

/// A class whose one field is a class.
final HostClass<_Box> _withClassField = HostClass(
  'Box',
  instance: (
    fields: {'kind': (b) => ClassType(_constClass)},
    properties: const {},
    methods: const {},
  ),
);

/// A class whose field reads are recorded in [order].
HostClass<_Box> _orderClass(List<String> order) => HostClass(
  'Box',
  instance: (
    fields: {
      for (final name in ['a', 'b'])
        name: (b) {
          order.add('read $name');

          return const MontyNone();
        },
    },
    properties: const {},
    methods: const {},
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
          policies: const (
            eagerAttrs: null,
            lazyAttrs: 'n',
            allowedMethods: null,
          ),
        ),
        _argumentError(
          "lazy_attrs must be 'all', None or a set of names, got 'n'",
        ),
      );
      expect(
        () => ClassType(
          _boxClass,
          instancePolicies: const (
            eagerAttrs: 'x',
            lazyAttrs: null,
            allowedMethods: null,
          ),
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

  // Divergence host-wrapper-identity-eq. Upstream's wrappers are
  // dataclasses (class_instance.py:39, 164, 216): two wrappers with equal
  // fields compare equal, and hash() raises TypeError ("unhashable type").
  // Dart cannot make an object unhashable, so `==` and `hashCode` are
  // identity. Python's answers below are pydantic-monty 1.1.0's, run on the
  // same pairs.
  group('recorded divergence host-wrapper-identity-eq', () {
    final box = _Box(1);
    final typeId = _id(100);
    final instanceId = _id(1);
    final type = ClassType(_boxClass, id: typeId);
    final twinType = ClassType(_boxClass, id: typeId);
    final instance = ClassInstance(box, classType: type, id: instanceId);
    final twin = ClassInstance(box, classType: type, id: instanceId);

    // (description, Dart's answer, Python's answer)
    final cases = [
      ('two instance wrappers with equal fields', instance == twin, true),
      ('two class wrappers with equal fields', type == twinType, true),
    ];
    for (final (what, dart, python) in cases) {
      test('$what: Dart $dart, Python $python', () {
        expect(dart, isNot(python), reason: 'listed as a divergence');
        expect(dart, isFalse);
      });
    }

    test('a wrapper equals itself, and its hash is its identity hash', () {
      for (final w in <Object>[instance, type]) {
        expect(w == w, isTrue);
        expect(w.hashCode, identityHashCode(w));
      }
    });

    test('equal-field wrappers are two keys in a set', () {
      expect({instance, twin, type, twinType}, hasLength(4));
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
      final closed = _box(
        1,
        value: box,
        policies: (eagerAttrs: null, lazyAttrs: null, allowedMethods: null),
      );
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

  group('wrapper semantics', () {
    test('a policy is copied: a later change to the list exposes nothing', () {
      final allowed = ['n'];
      final box = ClassInstance(
        _Box(1),
        classType: ClassType(_boxClass),
        policies: (
          eagerAttrs: null,
          lazyAttrs: allowed,
          allowedMethods: allowed,
        ),
      );
      allowed.add('bump');
      expect(
        () => box.callMethod('bump', const [], const {}),
        throwsA(isA<ExternalException>()),
      );
    });

    test('an instance reads its class constants, as getattr does', () {
      final box = ClassInstance(
        _Box(1),
        classType: ClassType(_constClass),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: 'all',
          allowedMethods: null,
        ),
      );
      expect(box.lookupLazyAttr('KIND'), const MontyString('box'));
    });

    test('a name listed twice is read and converted twice', () {
      var calls = 0;
      final attrs = ClassInstance(
        _Box(1),
        classType: ClassType(_boxClass),
        policies: const (
          eagerAttrs: ['n', 'n'],
          lazyAttrs: null,
          allowedMethods: null,
        ),
        convertValue: (name, value) => MontyInt(++calls),
      ).eagerAttributes();
      expect(attrs, {'n': const MontyInt(2)});
    });

    test('an instance reaches its class methods, as getattr does', () async {
      final box = ClassInstance(
        _Box(1),
        classType: ClassType(_constClass),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: 'all',
        ),
      );
      expect(
        await box.callMethod('describe', const [], const {}),
        const MontyString('a box'),
      );
    });

    test('an explicit grant calls what the attribute holds', () async {
      final granted = ClassInstance(
        _Box(1),
        classType: ClassType(_callableField),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: ['callback', 'number'],
        ),
      );
      expect(
        await granted.callMethod('callback', const [], const {}),
        const MontyInt(42),
      );
      expect(
        () => granted.callMethod('number', const [], const {}),
        throwsA(
          isA<ExternalException>().having(
            (e) => e.message,
            'message',
            "'int' object is not callable",
          ),
        ),
      );
      // Read as an attribute it is a function, named after the attribute.
      final read = ClassInstance(
        _Box(1),
        classType: ClassType(_callableField),
        policies: const (
          eagerAttrs: 'all',
          lazyAttrs: 'all',
          allowedMethods: null,
        ),
      );
      expect(
        read.eagerAttributes()['callback'],
        isA<BoundMethod>().having((m) => m.name, 'name', 'callback'),
      );
      expect(read.lookupLazyAttr('callback'), isA<BoundMethod>());
      expect(
        () => ArenaWriter(objects: HostObjects()).add(read),
        returnsNormally,
      );
      // Under 'all' only the class's methods qualify.
      final all = ClassInstance(
        _Box(1),
        classType: ClassType(_callableField),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: 'all',
        ),
      );
      expect(
        () => all.callMethod('callback', const [], const {}),
        throwsA(isA<ExternalException>()),
      );
    });

    test('the instance attribute wins over a method of the same name', () {
      final shadowed = ClassInstance(
        _Box(1),
        classType: ClassType(_shadowedMethod),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: 'all',
        ),
      );
      expect(
        () => shadowed.callMethod('run', const [], const {}),
        throwsA(
          isA<ExternalException>().having(
            (e) => e.message,
            'message',
            "'int' object is not callable",
          ),
        ),
      );
    });

    test('a method read as an attribute reaches the hook', () {
      final read = ClassInstance(
        _Box(1),
        classType: ClassType(_boxClass),
        policies: const (
          eagerAttrs: ['bump'],
          lazyAttrs: ['bump'],
          allowedMethods: null,
        ),
        convertValue: (name, value) =>
            value is BoundMethod ? const MontyString('callable') : value,
      );
      expect(read.eagerAttributes(), {'bump': const MontyString('callable')});
      expect(read.lookupLazyAttr('bump'), const MontyString('callable'));
      final type = ClassType(
        _constClass,
        policies: const (
          eagerAttrs: null,
          lazyAttrs: ['describe'],
          allowedMethods: null,
        ),
        convertValue: (name, value) =>
            value is BoundMethod ? const MontyString('classmethod') : value,
      );
      expect(type.lookupLazyAttr('describe'), const MontyString('classmethod'));
      // An instance method read from the class is a function too.
      final plain = ClassType(
        _boxClass,
        policies: const (
          eagerAttrs: ['bump'],
          lazyAttrs: ['bump'],
          allowedMethods: null,
        ),
      );
      expect(
        plain.eagerAttributes()['bump'],
        isA<BoundMethod>().having((m) => m.name, 'name', 'bump'),
      );
      expect(plain.lookupLazyAttr('bump'), isA<BoundMethod>());
      expect(
        () => (plain.lookupLazyAttr('bump') as BoundMethod).function(
          const [],
          const {},
        ),
        throwsA(isA<ExternalException>()),
      );
    });

    test('a method read without a hook crosses as a function', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final index = writer.add(
        ClassInstance(
          _Box(1),
          classType: ClassType(_boxClass),
          policies: const (
            eagerAttrs: ['bump'],
            lazyAttrs: null,
            allowedMethods: null,
          ),
        ),
      );
      final nodes = writer.arena.nodes;
      final value = itemAt(
        nodes,
        onlyItem(itemAt(nodes, index).classInstance.attrs.pairs).value,
      );
      expect(value.function.name, 'bump');
      // Lazily, through the session's answer.
      writer.add(
        _box(
          5,
          policies: const (
            eagerAttrs: null,
            lazyAttrs: ['bump'],
            allowedMethods: null,
          ),
        ),
      );
      final lookup = HostAnswers(
        objects: objects,
      ).lookup('bump', objectId: _id(5)).resumeNameLookup;
      expect(
        itemAt(lookup.values.nodes, lookup.value).function.name,
        'bump',
      );
    });

    test('a class constant holding a function', () {
      // Read through an instance, it is a function.
      final box = ClassInstance(
        _Box(1),
        classType: ClassType(_callableConstant),
        policies: const (
          eagerAttrs: ['twice'],
          lazyAttrs: 'all',
          allowedMethods: null,
        ),
      );
      final aFunction = isA<BoundMethod>();
      expect(box.eagerAttributes()['twice'], aFunction);
      expect(box.lookupLazyAttr('twice'), aFunction);
      // The class's eager 'all' skips it; a listed name reads it.
      final all = ClassType(
        _callableConstant,
        policies: const (
          eagerAttrs: 'all',
          lazyAttrs: null,
          allowedMethods: null,
        ),
      );
      expect(all.eagerAttributes().keys, ['KIND']);
      final listed = ClassType(
        _callableConstant,
        policies: const (
          eagerAttrs: ['twice'],
          lazyAttrs: null,
          allowedMethods: null,
        ),
      );
      expect(listed.eagerAttributes()['twice'], aFunction);
    });

    test('a class serves its constants lazily', () {
      final type = ClassType(
        _constClass,
        policies: const (
          eagerAttrs: null,
          lazyAttrs: ['KIND'],
          allowedMethods: null,
        ),
      );
      expect(type.lookupLazyAttr('KIND'), const MontyString('box'));
      expect(
        () => type.lookupLazyAttr('OTHER'),
        throwsA(isA<ExternalException>()),
      );
    });

    test('eager attributes are all read before the hook runs', () {
      final order = <String>[];
      ClassInstance(
        _Box(1),
        classType: ClassType(_orderClass(order)),
        policies: const (
          eagerAttrs: ['a', 'b'],
          lazyAttrs: null,
          allowedMethods: null,
        ),
        convertValue: (name, value) {
          order.add('convert $name');

          return value;
        },
      ).eagerAttributes();
      expect(order, ['read a', 'read b', 'convert a', 'convert b']);
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
      final box = _box(
        1,
        policies: (eagerAttrs: null, lazyAttrs: null, allowedMethods: null),
      );
      final other = _box(
        2,
        policies: (eagerAttrs: null, lazyAttrs: null, allowedMethods: null),
      );
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
      // The child is emitted and remembered before the refusal.
      const child = MontyList([MontyInt(2)]);
      expect(
        () => writer.tryAdd(MontyList([child, _selfNested()])),
        throwsA(anything),
      );
      final nodes = writer.arena.nodes;
      expect(nodes, hasLength(1));
      expect(writer.arena.nodeCount, 1);
      // Written again, the child is a fresh, valid node.
      final again = writer.add(child);
      expect(again, lessThan(nodes.length));
      expect(ArenaReader(writer.arena)[again], child);
    });

    test('two nodes for one registered object are one object and one key', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final box = _box(
        1,
        policies: (eagerAttrs: null, lazyAttrs: null, allowedMethods: null),
      );
      final first = writer.add(box);
      // A second node with the same instance id, as a worker could send.
      final arena = writer.arena;
      final nodes = arena.nodes;
      final second = nodes.length;
      nodes.add(itemAt(nodes, first).deepCopy());
      nodes.add(pb.MontyNode(set: pb.Indexes(items: [first, second])));
      arena.nodeCount = nodes.length;
      final reader = ArenaReader(arena, hosts: objects.lookup);
      expect(identical(reader[first], reader[second]), isTrue);
      final members = (reader[second + 1] as MontySet).items;
      expect(members, hasLength(1));
    });

    test('two wrappers of one object decode as one object and one key', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final shared = _Box(1);
      final a = writer.add(_box(1, value: shared));
      final b = writer.add(_box(2, value: shared));
      final arena = writer.arena;
      final nodes = arena.nodes
        ..add(pb.MontyNode(set: pb.Indexes(items: [a, b])));
      arena.nodeCount = nodes.length;
      final reader = ArenaReader(arena, hosts: objects.lookup);
      expect((reader[nodes.length - 1] as MontySet).items, hasLength(1));
    });

    test('a registered instance decodes whatever its attributes hold', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      // A class as an attribute value: a ClassType, which decodes too.
      final box = ClassInstance(
        _Box(1),
        classType: ClassType(_withClassField),
        id: _id(9),
        policies: const (
          eagerAttrs: 'all',
          lazyAttrs: null,
          allowedMethods: null,
        ),
      );
      final index = writer.add(box);
      final decoded = ArenaReader(writer.arena, hosts: objects.lookup)[index];
      expect(decoded, same(box));
      // Unregistered, the instance is a proxy and its class attribute a
      // class type proxy.
      final plain = ArenaReader(writer.arena)[index] as MontyClassProxy;
      expect(plain.attrs.values.whereType<MontyClassTypeProxy>(), hasLength(1));
    });

    test('an os.getenv default resolves a registered object', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final box = _box(1);
      final index = writer.add(box);
      final (_, args, _) = osCallParts(
        pb.OsCall(
          getenv: pb.OsCall_Getenv(key: 'K', default_2: index),
          values: writer.arena,
        ),
        hosts: objects.lookup,
      );
      expect(itemAt(args, 1), same(box));
    });

    test('an instance inside itself is a cycle', () {
      late final ClassInstance<_Box> looped;
      looped = ClassInstance(
        _Box(1),
        classType: ClassType(
          HostClass(
            'Box',
            instance: (
              fields: {'me': (b) => looped},
              properties: const {},
              methods: const {},
            ),
          ),
        ),
        policies: const (
          eagerAttrs: 'all',
          lazyAttrs: null,
          allowedMethods: null,
        ),
      );
      expect(
        () => ArenaWriter(objects: HostObjects()).add(looped),
        throwsA(
          isA<PythonRefusal>().having(
            (e) => e.text,
            'text',
            'Circular reference detected',
          ),
        ),
      );
    });

    test('a registered instance decodes whatever its class holds', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final box = ClassInstance(
        _Box(1),
        classType: ClassType(
          _withClassConstant,
          policies: const (
            eagerAttrs: 'all',
            lazyAttrs: null,
            allowedMethods: null,
          ),
        ),
      );
      final index = writer.add(box);
      final decoded = ArenaReader(writer.arena, hosts: objects.lookup)[index];
      expect(decoded, same(box));
      final plain = ArenaReader(writer.arena)[index] as MontyClassProxy;
      expect(plain.classType.name, 'Holder');
    });

    test('each future answer is its own encoding: the last policy wins', () {
      final objects = HostObjects();
      final box = _Box(1);
      final closed = _box(
        1,
        value: box,
        policies: (eagerAttrs: null, lazyAttrs: null, allowedMethods: null),
      );
      final open = _box(1, value: box);
      futuresRequest([
        (1, ExternalAnswer.value(closed)),
        (2, ExternalAnswer.value(open)),
        (3, ExternalAnswer.value(closed)),
      ], objects: objects);
      expect(objects[_one], same(closed));
    });

    test('a refused instance registers neither it nor its class', () {
      final objects = HostObjects();
      final failing = ClassInstance(
        _Box(1),
        classType: ClassType(_boxClass, id: _id(7)),
        id: _id(8),
        policies: const (
          eagerAttrs: ['absent'],
          lazyAttrs: null,
          allowedMethods: null,
        ),
      );
      expect(
        () => ArenaWriter(objects: objects).add(failing),
        throwsA(
          isA<PythonRefusal>().having(
            (e) => e.excType,
            'excType',
            'AttributeError',
          ),
        ),
      );
      expect(objects[_id(7)], isNull);
      expect(objects[_id(8)], isNull);
    });

    test('a registered class sent as a value decodes to its wrapper', () {
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final type = ClassType(_boxClass);
      final index = writer.add(type);
      final decoded = ArenaReader(writer.arena, hosts: objects.lookup)[index];
      expect(decoded, same(type));
      // Unregistered (a restored session), a class type proxy keeping the id.
      final plain = ArenaReader(writer.arena)[index] as MontyClassTypeProxy;
      expect(plain.id, type.id);
      expect(plain.hostDefined, isTrue);
      expect(plain.name, 'Box');
    });

    test('a registered instance decodes to its wrapper', () {
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
      expect(decoded, isA<ClassInstance<Object>>());
      expect(decoded, same(box));
      expect(decoded.dartValue, same(box.value));
      // An unregistered reader gives a plain proxy with the wrapper's id.
      final plain = ArenaReader(pb.Arena.fromBuffer(bytes))[index];
      expect((plain as MontyClassProxy).instanceId, box.id);
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
            seen = onlyItem(args);

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
