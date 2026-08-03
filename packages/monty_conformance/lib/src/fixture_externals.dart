import 'package:dart_monty_core/dart_monty_core.dart';

/// The external functions and name constants that `# call-external` fixtures
/// expect a host to provide.
///
/// **This table is the fixtures' half of a contract.** A `# call-external`
/// fixture is not a test of the interpreter alone — it is a test of the
/// host↔sandbox round trip, and it only runs if someone supplies `add_ints`
/// and friends. That is why a demo without them shows `ext_call 0/36`.
///
/// **Every consumer must use this table — there are no local copies.** All
/// four harnesses read it: `oracle_ffi_ext_test.dart`, both WASM corpus
/// runners (`wasm_runner.dart`, `wasm_runner_wasm.dart`) and the browser demo.
///
/// Duplicating it has silently broken conformance twice. First the FFI oracle
/// modelled 4 functions while `wasm_runner.dart` modelled 15, so FFI asserted
/// fewer fixtures than the web. Then the WASM runners kept `typeId: 0` on
/// every dataclass after this table gave each class its own, so
/// `dataclass__basic.py` passed on FFI and failed on WASM (FB-10). A copy
/// does not stay a copy.
///
/// Dependency-light on purpose so it compiles for the browser.
const conformanceExtFns = {
  'add_ints',
  'concat_strings',
  'return_value',
  'get_list',
  'raise_error', // raise_error(excType, msg) → resumeWithException
  'make_point',
  'make_mutable_point',
  'make_user',
  'make_empty',
  // Dataclass method calls (self is arguments[0])
  'sum', // Point/MutablePoint.sum() → x + y
  'add', // Point.add(dx, dy) → new Point(x=x+dx, y=y+dy)
  'scale', // Point.scale(factor) → new Point(x=x*factor, y=y*factor)
  'describe', // Point.describe(label) → '{label}({x}, {y})'
  'greeting', // User.greeting() → 'Hello, {name}!'
};

/// Class identity for host-supplied dataclasses. `typeId` is what the engine
/// compares to decide whether two dataclasses are the same class, so each
/// class needs its own — sharing one makes distinct classes indistinguishable.
///
/// All four of these were `0`. `dataclass__basic.py` asserts
/// `point != mut_point` precisely because Point and MutablePoint hold
/// identical field names and values, and with a shared id they compared equal.
/// The values themselves are arbitrary; only their distinctness matters.
const _pointTypeId = 1;
const _mutablePointTypeId = 2;
const _userTypeId = 3;
const _emptyTypeId = 4;

/// Answers a call to one of [conformanceExtFns].
///
/// Throws [StateError] for anything else, so a caller can report "this
/// fixture needs an external we do not model" instead of a false failure.
Object? conformanceDispatch(
  String functionName,
  List<MontyValue> args,
  Map<String, MontyValue>? kwargs,
) => switch (functionName) {
  // add_ints(a: int, b: int) → int
  'add_ints' => (args.first.dartValue! as int) + (args[1].dartValue! as int),
  // concat_strings(a: str, b: str) → str
  'concat_strings' => '${args.first.dartValue}${args[1].dartValue}',
  // return_value(x: any) → x  (identity)
  'return_value' => args.first.dartValue,
  // get_list() → [1, 2, 3]
  'get_list' => [1, 2, 3],
  // make_point() → frozen Point(x=1, y=2)
  'make_point' => const MontyDataclass(
    name: 'Point',
    typeId: _pointTypeId,
    fieldNames: ['x', 'y'],
    attrs: {'x': MontyInt(1), 'y': MontyInt(2)},
    frozen: true,
  ),
  // make_mutable_point() → mutable MutablePoint(x=1, y=2)
  'make_mutable_point' => const MontyDataclass(
    name: 'MutablePoint',
    typeId: _mutablePointTypeId,
    fieldNames: ['x', 'y'],
    attrs: {'x': MontyInt(1), 'y': MontyInt(2)},
  ),
  // make_user(name: str) → frozen User(name=name, active=True)
  // Frozen so that hash(user) works (the fixture asserts hashability).
  'make_user' => MontyDataclass(
    name: 'User',
    typeId: _userTypeId,
    fieldNames: const ['name', 'active'],
    attrs: {
      'name': args.first as MontyString,
      'active': const MontyBool(true),
    },
    frozen: true,
  ),
  // make_empty() → mutable Empty() with no fields
  'make_empty' => const MontyDataclass(
    name: 'Empty',
    typeId: _emptyTypeId,
    fieldNames: [],
    attrs: {},
  ),
  // --- dataclass method calls (arguments[0] is self) ---

  // sum(self) → self.x + self.y
  'sum' => () {
    final self = args.first as MontyDataclass;
    return (self.attrs['x']! as MontyInt).value +
        (self.attrs['y']! as MontyInt).value;
  }(),

  // add(self, dx, dy) → new dataclass(x=self.x+dx, y=self.y+dy)
  'add' => () {
    final self = args.first as MontyDataclass;
    final dx = (args[1] as MontyInt).value;
    final dy = (args[2] as MontyInt).value;
    return MontyDataclass(
      name: self.name,
      typeId: self.typeId,
      fieldNames: const ['x', 'y'],
      attrs: {
        'x': MontyInt((self.attrs['x']! as MontyInt).value + dx),
        'y': MontyInt((self.attrs['y']! as MontyInt).value + dy),
      },
      frozen: self.frozen,
    );
  }(),

  // scale(self, factor) → new dataclass(x=self.x*factor, y=self.y*factor)
  'scale' => () {
    final self = args.first as MontyDataclass;
    final factor = (args[1] as MontyInt).value;
    return MontyDataclass(
      name: self.name,
      typeId: self.typeId,
      fieldNames: const ['x', 'y'],
      attrs: {
        'x': MontyInt((self.attrs['x']! as MontyInt).value * factor),
        'y': MontyInt((self.attrs['y']! as MontyInt).value * factor),
      },
      frozen: self.frozen,
    );
  }(),

  // describe(self, label) or describe(self, label=label)
  // → '{label}({self.x}, {self.y})'
  'describe' => () {
    final self = args.first as MontyDataclass;
    final labelValue =
        (args.length > 1 ? args[1] : kwargs?['label'])! as MontyString;
    final label = labelValue.value;
    final x = (self.attrs['x']! as MontyInt).value;
    final y = (self.attrs['y']! as MontyInt).value;
    return '$label($x, $y)';
  }(),

  // greeting(self: User) → 'Hello, {name}!'
  'greeting' => () {
    final self = args.first as MontyDataclass;
    final name = (self.attrs['name']! as MontyString).value;
    return 'Hello, $name!';
  }(),

  _ => throw StateError('Unexpected external function: $functionName'),
};

/// Values the engine asks for by name. `# call-external` fixtures reference
/// these as bare globals, resolved through the name-lookup path.
const conformanceNameConstants = <String, Object?>{
  'CONST_INT': 42,
  'CONST_STR': 'hello',
  'CONST_FLOAT': 3.14,
  'CONST_BOOL': true,
  'CONST_LIST': [1, 2, 3],
  'CONST_NONE': null,
};
