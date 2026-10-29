// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 15 — a host module Python can import
//
// The host builds a module — an ExternalModule of values, host functions and
// one nested module — and hands it to the session as `externalModules`.
// Python imports it by name, reads its public attributes, and calls the host
// functions in it. The boundary holds in both directions: the sandbox sees
// the public attributes only, the module is not callable, it cannot be
// assigned to, and a private name reaches no host code at all. A host
// function raises a Python exception the script catches by its own name.
//
// Covers: ExternalModule, externalModules on checkout, submodules, the
//         module boundary.
//
// Run: dart run example/15_host_module.dart

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

/// The id the module carries: a uuid, as every module's is.
const String _toolsId = '0f6f1f5c-2f0a-4a3e-9c1b-8d2e5a7b4c11';

/// The name the forged host function carries: a path no module holds, so
/// the call reaches no host code.
const String _forgedName =
    'tools.sub.deep.deep.deep.deep.deep.deep.deep.deep._hidden';

/// One feed: the name of the check it serves, the code it runs, and the
/// inputs it binds before the code runs.
typedef _Feed = ({String name, String code, Map<String, MontyValue> inputs});

Future<void> main() async {
  final failures = <String>[];
  var hiddenCalls = 0;
  int countHiddenCall() => ++hiddenCalls;

  final tools = _toolsModule(countHiddenCall);

  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      final outcomes = await _runFeeds(session, countHiddenCall);

      _checkCalls(failures, outcomes);
      _checkModule(failures, outcomes, tools);
      _checkBoundary(failures, outcomes);
      _checkNames(failures, outcomes);
      _checkException(failures, outcomes);
      _checkHidden(failures, hiddenCalls);
    }, externalModules: {'tools': tools}),
  );

  if (failures.isNotEmpty) {
    exitCode = 1;

    return;
  }

  print('DEMO OK host_module');
}

/// The module the sandbox imports: a value, two host functions, a nested
/// module, and one private host function the sandbox never sees.
ExternalModule _toolsModule(int Function() countHiddenCall) => ExternalModule({
  'VERSION': 3,
  'add': MontyHostFunction('add', (arguments, keywords) {
    if (arguments case [final MontyInt left, final MontyInt right]) {
      return MontyInt(left.value + right.value);
    }

    throw ExternalException('TypeError', 'add() takes two integers');
  }),
  'explode': MontyHostFunction('explode', (arguments, keywords) {
    if (arguments case [final MontyString message]) {
      throw ExternalException('ValueError', message.value);
    }

    throw ExternalException('TypeError', 'explode() takes a string');
  }),
  'sub': ExternalModule({
    'TAG': 'nested',
    'double': MontyHostFunction('double', (arguments, keywords) {
      if (arguments case [final MontyInt value]) {
        return MontyInt(value.value * 2);
      }

      throw ExternalException('TypeError', 'double() takes an integer');
    }),
  }),
  '_hidden': MontyHostFunction('_hidden', (arguments, keywords) {
    return MontyInt(countHiddenCall());
  }),
}, id: _toolsId);

/// The feeds, in the order the session runs them.
List<_Feed> _feeds(int Function() countHiddenCall) => [
  _feed(
    'import-and-dotted-calls',
    'import tools\n'
        'import tools.sub as s\n'
        'from tools import add, VERSION\n'
        'from tools.sub import double\n'
        '[VERSION, add(2, 3), tools.sub.double(21), double(50), s.TAG, '
        'tools.VERSION]\n',
  ),
  _feed('module-id-round-trip', 'import tools\ntools'),
  _feed('module-assignment-refused', 'import tools\ntools.VERSION = 4'),
  _feed('module-not-callable', 'import tools\ntools()'),
  _feed('missing-attribute', 'import tools\ntools.nope()'),
  _feed('private-attribute-refused', 'import tools\ntools._hidden()'),
  _feed('unknown-module', 'import nope'),
  _feed('unknown-submodule', 'import tools.nope'),
  _feed(
    'forged-name-reaches-nothing',
    'probe()',
    inputs: {
      'probe': MontyHostFunction(_forgedName, (arguments, keywords) {
        return MontyInt(countHiddenCall());
      }),
    },
  ),
  _feed(
    'host-exception-by-name',
    'import tools\n'
        'try:\n'
        "    tools.explode('bad input')\n"
        "    out = 'no error'\n"
        'except ValueError as e:\n'
        "    out = f'caught ValueError: {e}'\n"
        'out\n',
  ),
];

/// One feed: its name, the code it runs, and the inputs it binds.
_Feed _feed(
  String name,
  String code, {
  Map<String, MontyValue> inputs = const {},
}) => (name: name, code: code, inputs: inputs);

/// Runs the feeds, in order, and keeps what each of them answered.
Future<Map<String, Object>> _runFeeds(
  MontySession session,
  int Function() countHiddenCall,
) async {
  final outcomes = <String, Object>{};
  for (final feed in _feeds(countHiddenCall)) {
    outcomes[feed.name] = await _runFeed(session, feed);
  }

  return outcomes;
}

/// The outcome of one feed: the value it returned, or the error it raised.
Future<Object> _runFeed(MontySession session, _Feed feed) async {
  try {
    return await session.feedRun(feed.code, inputs: feed.inputs);
  } on Object catch (error) {
    return error;
  }
}

/// The check: the imports, the dotted calls and the values they give.
void _checkCalls(List<String> failures, Map<String, Object> outcomes) {
  final outcome = outcomes['import-and-dotted-calls'];
  if (outcome is! MontyValue) {
    _fail(failures, 'import-and-dotted-calls', 'the feed raised $outcome');

    return;
  }
  const expected = MontyList([
    MontyInt(3),
    MontyInt(5),
    MontyInt(42),
    MontyInt(100),
    MontyString('nested'),
    MontyInt(3),
  ]);
  if (outcome != expected) {
    _fail(
      failures,
      'import-and-dotted-calls',
      'got $outcome, wanted $expected',
    );

    return;
  }

  _pass('import-and-dotted-calls');
}

/// The checks: the module the import binds, its id, and its attributes.
void _checkModule(
  List<String> failures,
  Map<String, Object> outcomes,
  ExternalModule tools,
) {
  final outcome = outcomes['module-id-round-trip'];
  if (outcome is! ExternalModule) {
    _fail(failures, 'module-id-round-trip', 'the feed returned $outcome');

    return;
  }
  if (outcome.id != _toolsId) {
    _fail(failures, 'module-id-round-trip', 'the id was ${outcome.id}');

    return;
  }

  _pass('module-id-round-trip');

  const expected = ['VERSION', 'add', 'explode', 'sub'];
  final keys = outcome.publicAttrs.keys.toList();
  if (!_sameNames(keys, expected)) {
    _fail(failures, 'public-attrs-exclude-private', 'the keys were $keys');

    return;
  }

  final own = tools.publicAttrs.keys.toList();
  if (!_sameNames(own, expected)) {
    _fail(failures, 'public-attrs-exclude-private', 'the keys were $own');

    return;
  }

  _pass('public-attrs-exclude-private');
}

/// The checks: what the sandbox may not do with the module.
void _checkBoundary(List<String> failures, Map<String, Object> outcomes) {
  _checkError(
    failures,
    'module-assignment-refused',
    outcomes['module-assignment-refused'],
    'AttributeError',
    "'module' object has no attribute 'VERSION' and no __dict__ for setting "
        'new attributes',
  );
  _checkError(
    failures,
    'module-not-callable',
    outcomes['module-not-callable'],
    'TypeError',
    "'module' object is not callable",
  );
  _checkError(
    failures,
    'missing-attribute',
    outcomes['missing-attribute'],
    'AttributeError',
    "module 'tools' has no attribute 'nope'",
  );
  _checkError(
    failures,
    'private-attribute-refused',
    outcomes['private-attribute-refused'],
    'AttributeError',
    "module 'tools' has no attribute '_hidden'",
  );
}

/// The checks: the modules that are not there, and the name that is forged.
void _checkNames(List<String> failures, Map<String, Object> outcomes) {
  _checkError(
    failures,
    'unknown-module',
    outcomes['unknown-module'],
    'ModuleNotFoundError',
    "No module named 'nope'",
  );
  _checkError(
    failures,
    'unknown-submodule',
    outcomes['unknown-submodule'],
    'ModuleNotFoundError',
    "No module named 'tools.nope'",
  );
  _checkError(
    failures,
    'forged-name-reaches-nothing',
    outcomes['forged-name-reaches-nothing'],
    'NameError',
    "name '$_forgedName' is not defined",
  );
}

/// The check: the host function's exception, caught by its name in Python.
void _checkException(List<String> failures, Map<String, Object> outcomes) {
  final outcome = outcomes['host-exception-by-name'];
  if (outcome is! MontyValue) {
    _fail(failures, 'host-exception-by-name', 'the feed raised $outcome');

    return;
  }
  if (outcome != const MontyString('caught ValueError: bad input')) {
    _fail(failures, 'host-exception-by-name', 'the feed returned $outcome');

    return;
  }

  _pass('host-exception-by-name');
}

/// The check: no private name reached the host function behind it.
void _checkHidden(List<String> failures, int hiddenCalls) {
  if (hiddenCalls != 0) {
    _fail(failures, 'hidden-never-called', 'the counter was $hiddenCalls');

    return;
  }

  _pass('hidden-never-called');
}

/// One error check: the exception's type and its whole message.
void _checkError(
  List<String> failures,
  String name,
  Object? outcome,
  String excType,
  String message,
) {
  if (outcome is! MontyRuntimeError) {
    _fail(failures, name, 'expected $excType, got $outcome');

    return;
  }
  final raised = outcome.exception.excType;
  if (raised != excType) {
    _fail(failures, name, 'expected $excType, got $raised');

    return;
  }
  final text = outcome.toString();
  if (text != '$excType: $message') {
    _fail(failures, name, 'the message was "$text"');

    return;
  }

  _pass(name);
}

/// Whether two lists of names hold the same names, in the same order.
bool _sameNames(List<String> names, List<String> expected) {
  if (names.length != expected.length) return false;

  final left = names.iterator;
  final right = expected.iterator;
  while (left.moveNext() && right.moveNext()) {
    if (left.current != right.current) return false;
  }

  return true;
}

/// Records a check that passed.
void _pass(String name) => print('PASS $name');

/// Records a failed check: the detail goes to stderr, never to stdout.
void _fail(List<String> failures, String name, String detail) {
  failures.add('$name: $detail');
  stderr.writeln('FAIL $name: $detail');
}
