// Arena fixtures with upstream's verdict on each: one accepted and one
// rejected arena per rule of upstream's decoder (monty-proto 1.1.0), in its
// three stages. The expected messages of stages 1 and 2 (and the root check)
// are upstream's own text, recorded by decoding each fixture's `Complete`
// with monty-proto's `decode_frame` and `MontyObject::try_from`; those of
// stage 3 are CPython's, for the constructor upstream's decoder calls.
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';

/// One arena, the root to read, and upstream's verdict.
final class ArenaFixture {
  const ArenaFixture(this.name, this.nodes, {this.root, this.error});

  final String name;
  final List<pb.MontyNode> nodes;

  /// The root node; the last node when null.
  final int? root;

  /// Upstream's error message, or null when upstream accepts the arena.
  final String? error;

  /// The stage the error comes from: 3 when it is a Python exception's.
  bool get isPython => error?.contains('Error: ') ?? false;

  int get rootIndex => root ?? nodes.length - 1;

  /// The `Complete` message carrying this arena.
  pb.Complete get complete => pb.Complete(
    value: rootIndex,
    values: pb.Arena(nodeCount: nodes.length, nodes: nodes),
  );
}

pb.MontyNode n(Object? v) => switch (v) {
  null => pb.MontyNode(none: pb.Unit()),
  final bool b => pb.MontyNode(boolean: b),
  // Before int: on dart2js these doubles pass `is int` too.
  final double d when !d.isFinite || (d == 0 && d.isNegative) => floatNode(d),
  final int i => intNode(i),
  final double d => floatNode(d),
  final String s => pb.MontyNode(str: s),
  _ => throw ArgumentError.value(v),
};

pb.MontyNode list(List<int> items) =>
    pb.MontyNode(list: pb.Indexes(items: items));

pb.MontyNode tuple(List<int> items) =>
    pb.MontyNode(tuple: pb.Indexes(items: items));

pb.MontyNode set(List<int> items) =>
    pb.MontyNode(set: pb.Indexes(items: items));

pb.MontyNode frozen(List<int> items) =>
    pb.MontyNode(frozenSet: pb.Indexes(items: items));

pb.MontyNode dict(List<(int, int)> pairs) => pb.MontyNode(
  dict: pb.NodePairs(
    pairs: [for (final (k, v) in pairs) pb.NodePair(key: k, value: v)],
  ),
);

pb.NodePairs pairs(List<(int, int)> pairs) => pb.NodePairs(
  pairs: [for (final (k, v) in pairs) pb.NodePair(key: k, value: v)],
);

/// A 16-byte uuid whose bytes are all [b], or [length] bytes.
pb.Uuid uuid(int b, {int length = 16}) => pb.Uuid(data: List.filled(length, b));

pb.MontyNode classType(
  String name, {
  int origin = 2,
  pb.Uuid? id,
  pb.NodePairs? attrs,
  bool dataclass = false,
}) => pb.MontyNode(
  type: pb.Type(
    name: name,
    origin: origin,
    id: id,
    attrs: attrs,
    isDataclass: dataclass ? true : null,
  ),
);

pb.MontyNode builtinType(String name) =>
    pb.MontyNode(type: pb.Type(name: name, origin: 1));

pb.MontyNode instance(int classNode, {pb.Uuid? id, pb.NodePairs? attrs}) =>
    pb.MontyNode(
      classInstance: pb.ClassInstanceNode(
        classType: classNode,
        instanceId: id,
        attrs: attrs,
      ),
    );

pb.MontyNode date(int y, int m, int d) => pb.MontyNode(
  date: pb.Date(year: y, month: m, day: d),
);

pb.MontyNode datetime({
  int year = 2026,
  int month = 1,
  int day = 2,
  int hour = 3,
  int minute = 4,
  int second = 5,
  int microsecond = 6,
  int? offset,
  String? name,
}) => pb.MontyNode(
  datetime: pb.DateTime(
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
    second: second,
    microsecond: microsecond,
    offsetSeconds: offset,
    timezoneName: name,
  ),
);

pb.MontyNode time({
  int hour = 3,
  int minute = 4,
  int second = 5,
  int microsecond = 6,
  int? offset,
  String? name,
  int fold = 0,
}) => pb.MontyNode(
  time: pb.Time(
    hour: hour,
    minute: minute,
    second: second,
    microsecond: microsecond,
    offsetSeconds: offset,
    timezoneName: name,
    fold: fold,
  ),
);

pb.MontyNode delta(int days, int seconds, int microseconds) => pb.MontyNode(
  timedelta: pb.TimeDelta(
    days: days,
    seconds: seconds,
    microseconds: microseconds,
  ),
);

pb.MontyNode zone(int offset, [String? name]) => pb.MontyNode(
  timezone: pb.TimeZone(offsetSeconds: offset, name: name),
);

pb.MontyNode file(String mode, {String path = '/f'}) => pb.MontyNode(
  fileHandle: pb.FileHandle(path: path, mode: mode),
);

pb.MontyNode exception(String type, [String? arg]) => pb.MontyNode(
  exception: pb.Exception(excType: type, arg: arg),
);

pb.MontyNode namedTuple(String type, List<String> fields, List<int> values) =>
    pb.MontyNode(
      namedTuple: pb.NamedTupleNode(
        typeName: type,
        fieldNames: fields,
        values: values,
      ),
    );

pb.MontyNode complexNode({double? real, double? imag}) => pb.MontyNode(
  complex: pb.Complex(
    real: real == null ? null : doubleToBits(real),
    imag: imag == null ? null : doubleToBits(imag),
  ),
);

String _range(String field, Object v, String range) =>
    'invalid value for $field: $v is outside the range $range';

/// Every fixture: accepted ones have a null [ArenaFixture.error].
final List<ArenaFixture> arenaFixtures = [
  // --- stage 1: each node on its own -------------------------------------
  ArenaFixture('kind absent', [
    pb.MontyNode(),
  ], error: 'missing required field MontyNode.kind'),
  ArenaFixture('the reserved uuid arm', [
    pb.MontyNode(uuid: uuid(1)),
  ], error: 'missing required field MontyNode.kind'),
  ArenaFixture('complex, both parts', [
    // The sign of zero is the point.
    // ignore: prefer_int_literals
    complexNode(real: 1, imag: -0.0),
  ]),
  ArenaFixture('complex, both parts zero', [complexNode(real: 0, imag: 0)]),
  ArenaFixture('complex without real', [
    complexNode(imag: 1),
  ], error: 'missing required field Complex.real'),
  ArenaFixture('complex without imag', [
    complexNode(real: 1),
  ], error: 'missing required field Complex.imag'),
  ArenaFixture('builtin type int', [builtinType('int')]),
  ArenaFixture('builtin type ValueError', [builtinType('ValueError')]),
  ArenaFixture('builtin type datetime.date', [builtinType('datetime.date')]),
  ArenaFixture('type with no origin', [
    classType('int', origin: 0),
  ], error: 'invalid value for Type: origin must be specified'),
  ArenaFixture('type with origin 4', [
    classType('C', origin: 4, id: uuid(1)),
  ], error: 'invalid value for Type.origin: unknown origin 4'),
  ArenaFixture('type with origin -1', [
    classType('C', origin: -1, id: uuid(1)),
  ], error: 'invalid value for Type.origin: unknown origin -1'),
  ArenaFixture(
    'builtin type with an id',
    [classType('int', origin: 1, id: uuid(1))],
    error: 'invalid value for Type: a builtin type must not carry an id',
  ),
  ArenaFixture(
    'builtin type with empty attrs',
    [classType('int', origin: 1, attrs: pb.NodePairs())],
    error: 'invalid value for Type: a builtin type must not carry attrs',
  ),
  ArenaFixture('builtin type with an unknown name', [
    builtinType('Int'),
  ], error: 'unknown type name "Int"'),
  ArenaFixture('builtin type named with a quote', [
    builtinType('a"b\n'),
  ], error: r'unknown type name "a\"b\n"'),
  ArenaFixture('sandbox class without an id', [
    classType('C'),
  ], error: 'invalid value for Type: a class type must carry an id'),
  ArenaFixture(
    'host class with a 15-byte id',
    [classType('C', origin: 3, id: uuid(1, length: 15))],
    error: 'invalid value for Type.id: uuid must be 16 bytes, got 15',
  ),
  ArenaFixture(
    'sandbox class with an empty name, as an instance class',
    [classType('', id: uuid(1)), instance(0, id: uuid(2), attrs: pairs([]))],
  ),
  ArenaFixture(
    'instance without an id',
    [classType('C', id: uuid(1)), instance(0, attrs: pairs([]))],
    error: 'missing required field ClassInstanceNode.instance_id',
  ),
  ArenaFixture(
    'instance without attrs',
    [classType('C', id: uuid(1)), instance(0, id: uuid(2))],
    error: 'missing required field ClassInstanceNode.attrs',
  ),
  ArenaFixture(
    'instance with a 17-byte id',
    [
      classType('C', id: uuid(1)),
      instance(0, id: uuid(2, length: 17), attrs: pairs([])),
    ],
    error:
        'invalid value for ClassInstanceNode.instance_id: uuid must be 16 '
        'bytes, got 17',
  ),
  ArenaFixture('date 2000-02-29', [date(2000, 2, 29)]),
  ArenaFixture('date year 0', [
    date(0, 1, 1),
  ], error: _range('Date.year', 0, '1..=9999')),
  ArenaFixture('date year 10000', [
    date(10000, 1, 1),
  ], error: _range('Date.year', 10000, '1..=9999')),
  ArenaFixture('date month 13', [
    date(2026, 13, 1),
  ], error: _range('Date.month', 13, '1..=12')),
  ArenaFixture('date 1900-02-29', [
    date(1900, 2, 29),
  ], error: _range('Date.day', 29, '1..=28')),
  ArenaFixture('date day 0', [
    date(2026, 4, 0),
  ], error: _range('Date.day', 0, '1..=30')),
  ArenaFixture('aware datetime with a name', [
    datetime(offset: 3600, name: 'CET'),
  ]),
  ArenaFixture(
    'datetime name without offset',
    [datetime(name: 'X')],
    error:
        'invalid value for DateTime.timezone_name: timezone_name '
        'requires offset_seconds',
  ),
  ArenaFixture('datetime hour 24', [
    datetime(hour: 24),
  ], error: _range('DateTime.hour', 24, '0..=23')),
  ArenaFixture('datetime second 60', [
    datetime(second: 60),
  ], error: _range('DateTime.second', 60, '0..=59')),
  ArenaFixture(
    'datetime microsecond 10^6',
    [datetime(microsecond: 1000000)],
    error:
        'invalid value for DateTime.microsecond: 1000000 exceeds maximum '
        '999999',
  ),
  ArenaFixture('datetime offset 86400', [
    datetime(offset: 86400),
  ], error: _range('DateTime.offset_seconds', 86400, '-86399..=86399')),
  ArenaFixture('datetime month 0 before hour 99', [
    datetime(month: 0, hour: 99),
  ], error: _range('DateTime.month', 0, '1..=12')),
  ArenaFixture('time with fold 1 and an empty zone name', [
    time(offset: 0, name: '', fold: 1),
  ]),
  ArenaFixture(
    'time name without offset',
    [time(name: 'X')],
    error:
        'invalid value for Time.timezone_name: timezone_name requires '
        'offset_seconds',
  ),
  ArenaFixture('time minute 60', [
    time(minute: 60),
  ], error: _range('Time.minute', 60, '0..=59')),
  ArenaFixture('time offset -86400', [
    time(offset: -86400),
  ], error: _range('Time.offset_seconds', -86400, '-86399..=86399')),
  ArenaFixture('time fold 2', [
    time(fold: 2),
  ], error: _range('Time.fold', 2, '0..=1')),
  ArenaFixture('timedelta at the day limits', [
    delta(-999999999, 86399, 999999),
  ]),
  ArenaFixture(
    'timedelta seconds 86400',
    [delta(0, 86400, 0)],
    error:
        'invalid value for TimeDelta.seconds: 86400 is outside the '
        'normalized range 0..86400',
  ),
  ArenaFixture(
    'timedelta microseconds -1',
    [delta(0, 0, -1)],
    error:
        'invalid value for TimeDelta.microseconds: -1 is outside the '
        'normalized range 0..1000000',
  ),
  ArenaFixture('timezone with a name', [zone(-3600, 'X')]),
  ArenaFixture('timezone offset 86400', [
    zone(86400),
  ], error: _range('TimeZone.offset_seconds', 86400, '-86399..=86399')),
  ArenaFixture('exception json.JSONDecodeError', [
    exception('json.JSONDecodeError', 'x'),
  ]),
  ArenaFixture('exception of an unknown type', [
    exception('valueerror'),
  ], error: 'unknown exception type "valueerror"'),
  ArenaFixture('builtin function object.__setattr__', [
    pb.MontyNode(builtinFunction: 'object.__setattr__'),
  ]),
  // Upstream formats a node's message into 512 bytes; a longer one is
  // replaced. The message here is the name plus 27 bytes.
  ArenaFixture('a builtin name whose message is 512 bytes', [
    pb.MontyNode(builtinFunction: 'x' * 485),
  ], error: 'unknown builtin function "${'x' * 485}"'),
  ArenaFixture('a builtin name whose message is 513 bytes', [
    pb.MontyNode(builtinFunction: 'x' * 486),
  ], error: 'invalid wire value (error message exceeds 512 bytes)'),
  // Rust's {:?} escapes a zero-width space and a combining mark; the
  // escapes count toward the 512 bytes (70 of them make 587).
  ArenaFixture('a builtin name with escaped characters', [
    pb.MontyNode(builtinFunction: 'a\u200Bb\u0301\u00a0 \u1160'),
  ], error: r'unknown builtin function "a\u{200b}b\u{301}\u{a0} \u{1160}"'),
  ArenaFixture('a builtin name of 70 zero-width spaces', [
    pb.MontyNode(builtinFunction: '\u200B' * 70),
  ], error: 'invalid wire value (error message exceeds 512 bytes)'),
  ArenaFixture('builtin function Len', [
    pb.MontyNode(builtinFunction: 'Len'),
  ], error: 'unknown builtin function "Len"'),
  ArenaFixture('file mode rt', [file('rt')]),
  ArenaFixture('file mode br', [file('br')]),
  for (final mode in ['', 'rw', 'r+', 'x', 'rbt', 'bb', 'tt', 'rr', 'b', 'U'])
    ArenaFixture('file mode "$mode"', [
      file(mode),
    ], error: 'invalid file mode "$mode"'),
  // --- stage 2: references -----------------------------------------------
  ArenaFixture(
    'a list holding itself',
    [
      list([0]),
    ],
    error:
        'invalid value for Arena: value node 0 references node 0, which '
        'is not below it',
  ),
  ArenaFixture(
    'a dict value above its holder',
    [
      n(1),
      dict([(0, 5)]),
    ],
    error:
        'invalid value for Arena: value node 1 references node 5, which '
        'is not below it',
  ),
  ArenaFixture(
    'a named tuple value above',
    [
      namedTuple('P', ['x'], [1]),
    ],
    error:
        'invalid value for Arena: value node 0 references node 1, which '
        'is not below it',
  ),
  ArenaFixture(
    'a class attr above',
    [
      classType('C', id: uuid(1), attrs: pairs([(1, 1)])),
    ],
    error:
        'invalid value for Arena: value node 0 references node 1, which '
        'is not below it',
  ),
  ArenaFixture(
    'an instance of a builtin type',
    [builtinType('int'), instance(0, id: uuid(2), attrs: pairs([]))],
    error:
        'invalid value for Arena: class instance node 1 does not point '
        'at a class type',
  ),
  ArenaFixture(
    'an instance of an int',
    [n(1), instance(0, id: uuid(2), attrs: pairs([]))],
    error:
        'invalid value for Arena: class instance node 1 does not point '
        'at a class type',
  ),
  ArenaFixture(
    'an instance of itself',
    [instance(0, id: uuid(2), attrs: pairs([]))],
    error:
        'invalid value for Arena: value node 0 references node 0, which '
        'is not below it',
  ),
  ArenaFixture(
    'a root past the end',
    [n(1)],
    root: 1,
    error:
        'invalid value for Arena: value root 1 is out of range for an '
        'arena of 1 nodes',
  ),
  ArenaFixture('an unreachable malformed node', [
    date(2026, 2, 30),
    n(1),
  ], error: _range('Date.day', 30, '1..=28')),
  ArenaFixture(
    'a node error before an earlier reference error',
    [
      list([5]),
      date(2026, 2, 30),
    ],
    root: 0,
    error: _range('Date.day', 30, '1..=28'),
  ),
  // --- stage 3: Python construction --------------------------------------
  ArenaFixture('a list as a dict key', [
    list([]),
    n(1),
    dict([(0, 1)]),
  ], error: "TypeError: unhashable type: 'list'"),
  ArenaFixture('a dict as a set member', [
    dict([]),
    set([0]),
  ], error: "TypeError: unhashable type: 'dict'"),
  ArenaFixture('a set in a frozenset', [
    set([]),
    frozen([0]),
  ], error: "TypeError: unhashable type: 'set'"),
  ArenaFixture('a tuple holding a list, as a key', [
    n(1),
    list([]),
    tuple([0, 1]),
    dict([(2, 0)]),
  ], error: "TypeError: unhashable type: 'list'"),
  ArenaFixture('a tuple holding a set before a list, as a member', [
    set([]),
    list([]),
    tuple([0, 1]),
    set([2]),
  ], error: "TypeError: unhashable type: 'set'"),
  ArenaFixture('a class proxy as a set member', [
    classType('C', id: uuid(1)),
    instance(0, id: uuid(2), attrs: pairs([])),
    set([1]),
  ], error: "TypeError: unhashable type: 'MontyClassProxy'"),
  ArenaFixture('a class type proxy as a dict key', [
    classType('C', id: uuid(1)),
    n(1),
    dict([(0, 1)]),
  ], error: "TypeError: unhashable type: 'MontyClassTypeProxy'"),
  ArenaFixture('an unreachable unhashable key', [
    list([]),
    set([0]),
    n(1),
  ], error: "TypeError: unhashable type: 'list'"),
  ArenaFixture('a named tuple os.stat_result', [
    n(1),
    namedTuple('os.stat_result', ['st_mode'], [0]),
  ]),
  ArenaFixture('a named tuple with no fields', [namedTuple('E', [], [])]),
  ArenaFixture(
    'a named tuple named 1x',
    [namedTuple('1x', [], [])],
    error:
        'ValueError: Type names and field names must be valid '
        "identifiers: '1x'",
  ),
  ArenaFixture(
    'a named tuple with an empty name',
    [namedTuple('', [], [])],
    error:
        'ValueError: Type names and field names must be valid '
        "identifiers: ''",
  ),
  ArenaFixture(
    'a named tuple named a.',
    [namedTuple('a.', [], [])],
    error:
        'ValueError: Type names and field names must be valid '
        "identifiers: ''",
  ),
  ArenaFixture(
    'a named tuple with a keyword field',
    [
      n(1),
      namedTuple('P', ['class'], [0]),
    ],
    error:
        'ValueError: Type names and field names cannot be a keyword: '
        "'class'",
  ),
  ArenaFixture(
    'a named tuple with an underscore field',
    [
      n(1),
      namedTuple('P', ['_x'], [0]),
    ],
    error:
        'ValueError: Field names cannot start with an underscore: '
        "'_x'",
  ),
  ArenaFixture('a named tuple with a repeated field', [
    n(1),
    namedTuple('P', ['x', 'x'], [0, 0]),
  ], error: "ValueError: Encountered duplicate field name: 'x'"),
  ArenaFixture('a named tuple one value short', [
    n(1),
    namedTuple('P', ['x', 'y'], [0]),
  ], error: 'TypeError: Expected 2 arguments, got 1'),
  ArenaFixture(
    'a timedelta of 10^9 days',
    [delta(1000000000, 0, 0)],
    error:
        'OverflowError: days=1000000000; must have magnitude <= '
        '999999999',
  ),
  ArenaFixture(
    'a timedelta of -10^9 days',
    [delta(-1000000000, 0, 0)],
    error:
        'OverflowError: days=-1000000000; must have magnitude <= '
        '999999999',
  ),
];
