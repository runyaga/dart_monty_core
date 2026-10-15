import 'package:dart_monty_core/dart_monty_core.dart';

/// The external functions and name constants that `# call-external` fixtures
/// expect a host to provide, in the shape the web demo's conformance panel
/// uses ([conformanceDispatch]). The corpus runner uses its own port of
/// upstream's harness (`worker_fixture_host.dart`).
///
/// **This table is the fixtures' half of a contract.** A `# call-external`
/// fixture is not a test of the interpreter alone: it tests the host/sandbox
/// round trip, and it only runs if someone supplies `add_ints` and friends.
///
/// The dataclass methods (`sum`, `add`, `scale`, `describe`, `greeting`) are
/// not here: they are methods of the classes the `make_*` functions return,
/// and the session calls them with their receiver bound.
///
/// Dependency-light on purpose so it compiles for the browser.
const conformanceExtFns = {
  'add_ints',
  'concat_strings',
  'return_value',
  'get_list',
  'raise_error', // raise_error(excType, msg) → raises excType(msg)
  'make_point',
  'make_mutable_point',
  'make_user',
  'make_empty',
};

/// A host dataclass instance: its class name and its fields.
typedef _Fields = ({String className, Map<String, MontyValue> attrs});

int _int(_Fields self, String name) => (self.attrs[name]! as MontyInt).value;

_Fields _withXY(_Fields self, int x, int y) => (
  className: self.className,
  attrs: {'x': MontyInt(x), 'y': MontyInt(y)},
);

/// A fixture dataclass named [name]. Every one has the same members; a field
/// or method the instance lacks raises `AttributeError`.
HostClass<_Fields> _hostClass(String name) => HostClass(
  name,
  isDataclass: true,
  instance: (
    fields: <String, Object Function(_Fields self)>{
      for (final name in ['x', 'y', 'name', 'active'])
        name: (self) => self.attrs[name] ?? (throw _absent(self, name)),
    },
    properties: <String, Object Function(_Fields self)>{},
    methods:
        <
          String,
          Object Function(
            _Fields self,
            List<MontyValue> args,
            Map<String, MontyValue> kwargs,
          )
        >{
          // sum(self) → self.x + self.y
          'sum': (self, args, kwargs) =>
              MontyInt(_int(self, 'x') + _int(self, 'y')),
          // add(self, dx, dy) → a new instance with x + dx, y + dy
          'add': (self, args, kwargs) => _instance(
            _withXY(
              self,
              _int(self, 'x') + (args[0] as MontyInt).value,
              _int(self, 'y') + (args[1] as MontyInt).value,
            ),
          ),
          // scale(self, factor) → a new instance with x * factor, y * factor
          'scale': (self, args, kwargs) {
            final factor = (args.first as MontyInt).value;

            return _instance(
              _withXY(self, _int(self, 'x') * factor, _int(self, 'y') * factor),
            );
          },
          // describe(self, label) → '{label}({x}, {y})'
          'describe': (self, args, kwargs) {
            final label =
                (args.isNotEmpty ? args.first : kwargs['label'])!
                    as MontyString;

            return MontyString(
              '${label.value}(${_int(self, 'x')}, ${_int(self, 'y')})',
            );
          },
          // greeting(self: User) → 'Hello, {name}!'
          'greeting': (self, args, kwargs) {
            final name = (self.attrs['name']! as MontyString).value;

            return MontyString('Hello, $name!');
          },
        },
  ),
);

ExternalException _absent(_Fields self, String name) => ExternalException(
  'AttributeError',
  "'${self.className}' object has no attribute '$name'",
);

/// One class per name, so two instances of a class share its identity and
/// Point and MutablePoint, whose fields are the same, stay distinct classes.
final _classes = <String, ClassType<_Fields>>{};

ClassInstance<_Fields> _instance(_Fields fields) => ClassInstance(
  fields,
  classType: _classes.putIfAbsent(
    fields.className,
    () => ClassType(_hostClass(fields.className)),
  ),
  policies: (
    eagerAttrs: fields.attrs.keys.toList(),
    lazyAttrs: 'all',
    allowedMethods: 'all',
  ),
);

/// Answers a call to one of [conformanceExtFns]: a [MontyValue], or a host
/// object ([ClassInstance]) for the `make_*` functions.
///
/// Throws [StateError] for anything else, so a caller can report "this
/// fixture needs an external we do not model" instead of a false failure.
Object conformanceDispatch(
  String functionName,
  List<MontyValue> args,
  Map<String, MontyValue>? kwargs,
) => switch (functionName) {
  // add_ints(a: int, b: int) → int
  'add_ints' => MontyInt(
    (args.first as MontyInt).value + (args[1] as MontyInt).value,
  ),
  // concat_strings(a: str, b: str) → str
  'concat_strings' => MontyString(
    '${(args.first as MontyString).value}${(args[1] as MontyString).value}',
  ),
  // return_value(x: any) → x  (identity)
  'return_value' => args.first,
  // get_list() → [1, 2, 3]
  'get_list' => const MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
  // raise_error(exc_type: str, message: str) → raises exc_type(message)
  'raise_error' => throw ExternalException(
    (args.first as MontyString).value,
    (args[1] as MontyString).value,
  ),
  // make_point() → Point(x=1, y=2)
  'make_point' => _instance((
    className: 'Point',
    attrs: const {'x': MontyInt(1), 'y': MontyInt(2)},
  )),
  // make_mutable_point() → MutablePoint(x=1, y=2)
  'make_mutable_point' => _instance((
    className: 'MutablePoint',
    attrs: const {'x': MontyInt(1), 'y': MontyInt(2)},
  )),
  // make_user(name: str) → User(name=name, active=True)
  'make_user' => _instance((
    className: 'User',
    attrs: {'name': args.first as MontyString, 'active': const MontyBool(true)},
  )),
  // make_empty() → Empty() with no fields
  'make_empty' => _instance((className: 'Empty', attrs: const {})),
  _ => throw StateError('Unexpected external function: $functionName'),
};

/// Values the engine asks for by name. `# call-external` fixtures reference
/// these as bare globals, resolved through the name-lookup path.
const conformanceNameConstants = <String, MontyValue>{
  'CONST_INT': MontyInt(42),
  'CONST_STR': MontyString('hello'),
  'CONST_FLOAT': MontyFloat(3.14),
  'CONST_BOOL': MontyBool(true),
  'CONST_LIST': MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
  'CONST_NONE': MontyNone(),
};
