// The open() contract, shared by the VM and the browser runners.
//
// Expected behaviour: upstream monty v1.2.0's
// crates/monty/test_cases/open__fs.py — the newline section (newline_reads at
// :684, newline_writes at :706) and the iteration section at :722 — which
// pins CPython's own text-mode semantics.
//
// Every case is a Python program that asserts its own expectations and ends
// with 42. The Dart side only checks that the program ran to the end (its
// value is MontyInt(42)) and, where the contract is about bytes, that the
// host holds what the program wrote. No result is encoded into a string.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// The sandbox the shared open() cases run in.
abstract interface class OpenCaseRunner {
  /// Runs [code] in the sandbox and returns the value it evaluated to.
  Future<MontyValue> run(String code);

  /// The bytes the host holds at the mounted [path].
  List<int> hostBytes(String path);
}

/// The newline argument is validated after the open, as in CPython: a missing
/// file still raises FileNotFoundError, and a new write path still creates
/// the file before the ValueError.
Future<void> expectOpenNewline(OpenCaseRunner runner) async {
  await _expectRan(runner, _newlineProgram);
  expect(
    _hostBytes(runner, '/d/nl_created.txt'),
    isEmpty,
    reason: 'the illegal newline must still have created the file',
  );
}

/// Every newline mode reads what CPython reads, through `open()` and through
/// `Path.open()`.
Future<void> expectOpenReadMatrix(OpenCaseRunner runner) async {
  await _expectRan(runner, _readProgram());
}

/// Every newline mode writes what CPython writes, on the host as well as
/// through `Path.read_bytes()`.
Future<void> expectOpenWriteMatrix(OpenCaseRunner runner) async {
  await _expectRan(runner, _writeProgram());
  for (final mode in _writeModes) {
    final name = _writeNames[mode]!;
    expect(
      _hostBytes(runner, '/d/$name'),
      _writeBytes[mode],
      reason: 'the host must hold what the $mode newline wrote',
    );
  }
  expect(
    _hostBytes(runner, '/d/$_writePairName'),
    _writePairBytes,
    reason: 'the host must hold both CRLF writes',
  );
}

/// Iterating a text file keeps one shared position, whether the consumer is
/// a for loop, `next()`, or a consumer that cannot yield to the host.
Future<void> expectOpenIteration(OpenCaseRunner runner) async {
  await _expectRan(runner, _iterationProgram);
}

/// Runs [code] and fails the case when it raised.
///
/// A Python error that escapes the program is an assertion failure here, not
/// an exception thrown out of the test: the case reports what the program
/// raised and stops.
Future<void> _expectRan(OpenCaseRunner runner, String code) async {
  final outcome = await _attempt(runner, code);
  expect(
    outcome.failure,
    isNull,
    reason:
        'the open case must run to its end, but it raised: ${outcome.failure}',
  );
  expect(outcome.value, const MontyInt(42));
}

/// Runs [code] and keeps whatever it raised, so a case can report it.
Future<({MontyValue? value, Object? failure})> _attempt(
  OpenCaseRunner runner,
  String code,
) async {
  try {
    return (value: await runner.run(code), failure: null);
  } on Object catch (error) {
    return (value: null, failure: error);
  }
}

/// The bytes the host holds at [path], failing the case when the host does
/// not hold the file.
List<int> _hostBytes(OpenCaseRunner runner, String path) {
  List<int>? bytes;
  Object? failure;
  try {
    bytes = runner.hostBytes(path);
  } on Object catch (error) {
    failure = error;
  }
  expect(failure, isNull, reason: 'the host must hold $path');

  return bytes ?? const [];
}

/// The newline modes CPython accepts, in the order upstream pins them.
const _readModes = <String?>[null, '', '\n', '\r', '\r\n'];

/// The newline modes CPython accepts for a write, in the order upstream pins
/// them.
const _writeModes = <String?>[null, '', '\n', '\r', '\r\n'];

/// The two ways a text file is opened.
final _readOpenCalls = <String Function(String)>[
  (newline) => "open(root / 'nl.txt', newline=$newline)",
  (newline) => "root.joinpath('nl.txt').open(newline=$newline)",
];

/// What each newline mode reads from `b'a\nb\r\nc\rd'`.
final _readExpectations = <String?, _ReadExpectation>{
  null: const _ReadExpectation(
    lines: ['a\n', 'b\n', 'c\n', 'd'],
    first: 'a\n',
    rest: 'b\nc\nd',
    full: 'a\nb\nc\nd',
    sizedFirst: 'a\nb',
    sizedRest: '\nc\nd',
  ),
  '': const _ReadExpectation(
    lines: ['a\n', 'b\r\n', 'c\r', 'd'],
    first: 'a\n',
    rest: 'b\r\nc\rd',
    full: 'a\nb\r\nc\rd',
    sizedFirst: 'a\nb',
    sizedRest: '\r\nc\rd',
  ),
  '\n': const _ReadExpectation(
    lines: ['a\n', 'b\r\n', 'c\rd'],
    first: 'a\n',
    rest: 'b\r\nc\rd',
    full: 'a\nb\r\nc\rd',
    sizedFirst: 'a\nb',
    sizedRest: '\r\nc\rd',
  ),
  '\r': const _ReadExpectation(
    lines: ['a\nb\r', '\nc\r', 'd'],
    first: 'a\nb\r',
    rest: '\nc\rd',
    full: 'a\nb\r\nc\rd',
    sizedFirst: 'a\nb',
    sizedRest: '\r\nc\rd',
  ),
  '\r\n': const _ReadExpectation(
    lines: ['a\nb\r\n', 'c\rd'],
    first: 'a\nb\r\n',
    rest: 'c\rd',
    full: 'a\nb\r\nc\rd',
    sizedFirst: 'a\nb',
    sizedRest: '\r\nc\rd',
  ),
};

/// What each newline mode writes, as the bytes the host must hold.
final _writeBytes = <String?, List<int>>{
  null: _hexBytes('780a790d0a7a'),
  '': _hexBytes('780a790d0a7a'),
  '\n': _hexBytes('780a790d0a7a'),
  '\r': _hexBytes('780d790d0d7a'),
  '\r\n': _hexBytes('780d0a790d0d0a7a'),
};

/// The file each newline mode writes to; the names are distinct so the host
/// bytes of one mode never overwrite another's.
final _writeNames = <String?, String>{
  null: 'nl_none.txt',
  '': 'nl_empty.txt',
  '\n': 'nl_lf.txt',
  '\r': 'nl_cr.txt',
  '\r\n': 'nl_crlf.txt',
};

/// The file the two consecutive CRLF writes share.
const _writePairName = 'nl_crlf_pair.txt';

/// The bytes the two consecutive CRLF writes leave on the host.
final List<int> _writePairBytes = _hexBytes('6f6e650d0a74776f0d0a');

/// The reads a single newline mode performs.
final class _ReadExpectation {
  /// The lines a full read splits the file into.
  const _ReadExpectation({
    required this.lines,
    required this.first,
    required this.rest,
    required this.full,
    required this.sizedFirst,
    required this.sizedRest,
  });

  /// The lines a full read splits the file into.
  final List<String> lines;

  /// The first line of the file.
  final String first;

  /// Everything after the first line.
  final String rest;

  /// The whole file, as one read returns it.
  final String full;

  /// The sized read of three characters.
  final String sizedFirst;

  /// What follows the sized read.
  final String sizedRest;
}

/// The bytes [hex] spells, two characters per byte.
List<int> _hexBytes(String hex) {
  final bytes = <int>[];
  for (var index = 0; index < hex.length; index += 2) {
    bytes.add(int.parse(hex.substring(index, index + 2), radix: 16));
  }

  return bytes;
}

/// The Python literal for [newline]: `None`, or a quoted string.
String _pyNewline(String? newline) =>
    newline == null ? 'None' : _pyString(newline);

/// The Python literal for [value].
String _pyString(String value) {
  final literal = StringBuffer("'");
  for (final unit in value.codeUnits) {
    if (unit == 0x0a) {
      literal.write(r'\n');
    } else if (unit == 0x0d) {
      literal.write(r'\r');
    } else if (unit == 0x5c) {
      literal.write(r'\\');
    } else if (unit == 0x27) {
      literal.write(r"\'");
    } else {
      literal.writeCharCode(unit);
    }
  }
  literal.write("'");

  return literal.toString();
}

/// The Python literal for the list of [values].
String _pyStringList(List<String> values) =>
    '[${values.map(_pyString).join(', ')}]';

/// The Python literal for the bytes of [bytes].
String _pyBytes(List<int> bytes) {
  final literal = StringBuffer("b'");
  for (final unit in bytes) {
    if (unit == 0x0a) {
      literal.write(r'\n');
    } else if (unit == 0x0d) {
      literal.write(r'\r');
    } else if (unit == 0x5c) {
      literal.write(r'\\');
    } else if (unit == 0x27) {
      literal.write(r"\'");
    } else if (unit >= 0x20 && unit < 0x7f) {
      literal.writeCharCode(unit);
    } else {
      literal.write('\\x${unit.toRadixString(16).padLeft(2, '0')}');
    }
  }
  literal.write("'");

  return literal.toString();
}

/// The program that reads the file with every newline mode.
String _readProgram() {
  final program = [
    "root = Path('/d')",
    r"written = root.joinpath('nl.txt').write_bytes(b'a\nb\r\nc\rd')",
    'assert type(written) is int',
    'assert written == 8',
  ];
  for (final mode in _readModes) {
    final expectation = _readExpectations[mode]!;
    final newline = _pyNewline(mode);
    for (final open in _readOpenCalls) {
      final opened = open(newline);
      final lines = _pyStringList(expectation.lines);
      program.addAll([
        'with $opened as handle:',
        '    assert handle.read() == ${_pyString(expectation.full)}',
        'with $opened as handle:',
        '    assert handle.readlines() == $lines',
        'with $opened as handle:',
        '    assert handle.readline() == ${_pyString(expectation.first)}',
        '    assert handle.read() == ${_pyString(expectation.rest)}',
        'with $opened as handle:',
        '    assert [line for line in handle] == $lines',
        'with $opened as handle:',
        '    assert handle.read(3) == ${_pyString(expectation.sizedFirst)}',
        '    assert handle.read() == ${_pyString(expectation.sizedRest)}',
      ]);
    }
  }
  program.add('42');

  return program.join('\n');
}

/// The program that writes the file with every newline mode.
String _writeProgram() {
  final program = ["root = Path('/d')"];
  for (final mode in _writeModes) {
    final name = _writeNames[mode]!;
    final newline = _pyNewline(mode);
    program.addAll([
      "with open(root / '$name', 'w', newline=$newline) as writer:",
      r"    count = writer.write('x\ny\r\nz')",
      '    assert type(count) is int',
      '    assert count == 6',
      "data = root.joinpath('$name').read_bytes()",
      'assert type(data) is bytes',
      'assert data == ${_pyBytes(_writeBytes[mode]!)}',
    ]);
  }
  program.addAll([
    "with open(root / '$_writePairName', 'w', newline='\\r\\n') as writer:",
    r"    count = writer.write('one\n')",
    '    assert type(count) is int',
    '    assert count == 4',
    r"    count = writer.write('two\n')",
    '    assert type(count) is int',
    '    assert count == 4',
    "data = root.joinpath('$_writePairName').read_bytes()",
    'assert type(data) is bytes',
    'assert data == ${_pyBytes(_writePairBytes)}',
    '42',
  ]);

  return program.join('\n');
}

/// The program that checks the newline argument is validated after the open.
const _newlineProgram = r'''
root = Path('/d')
written = root.joinpath('nl.txt').write_bytes(b'a\nb\r\nc\rd')
assert type(written) is int
assert written == 8

# An existing file with an illegal newline raises ValueError.
kind = None
message = ''
try:
    open(root / 'nl.txt', newline='x')
except ValueError as exc:
    kind = 'ValueError'
    message = str(exc)
except TypeError as exc:
    kind = 'TypeError'
    message = str(exc)
except Exception as exc:
    kind = 'unexpected'
    message = str(exc)
assert kind == 'ValueError', 'expected ValueError, got ' + str(kind) + ': ' + message
assert message == 'illegal newline value: x'

# A missing file still raises FileNotFoundError: the newline is validated
# after the open.
kind = None
message = ''
try:
    open(root / 'nl_missing.txt', newline='x')
except FileNotFoundError as exc:
    kind = 'FileNotFoundError'
    message = str(exc)
except Exception as exc:
    kind = 'unexpected'
    message = str(exc)
assert kind == 'FileNotFoundError', 'expected FileNotFoundError, got ' + str(kind) + ': ' + message

# A new write path creates the file before the ValueError.
kind = None
message = ''
try:
    open(root / 'nl_created.txt', 'w', newline='x')
except ValueError as exc:
    kind = 'ValueError'
    message = str(exc)
except Exception as exc:
    kind = 'unexpected'
    message = str(exc)
assert kind == 'ValueError', 'expected ValueError, got ' + str(kind) + ': ' + message
assert message == 'illegal newline value: x'

# A binary mode takes no newline at all.
kind = None
message = ''
try:
    open(root / 'nl.txt', 'rb', newline='')
except ValueError as exc:
    kind = 'ValueError'
    message = str(exc)
except Exception as exc:
    kind = 'unexpected'
    message = str(exc)
assert kind == 'ValueError', 'expected ValueError, got ' + str(kind) + ': ' + message
assert message == "binary mode doesn't take a newline argument"

# A newline that is not a string is a TypeError.
kind = None
message = ''
try:
    open(root / 'nl.txt', newline=1)
except TypeError as exc:
    kind = 'TypeError'
    message = str(exc)
except Exception as exc:
    kind = 'unexpected'
    message = str(exc)
assert kind == 'TypeError', 'expected TypeError, got ' + str(kind) + ': ' + message
assert message == "open() argument 'newline' must be str or None, not int"

42
''';

/// The program that checks an iterated file keeps one shared position.
const _iterationProgram = r'''
root = Path('/d')
written = root.joinpath('iter.txt').write_text('first\nsecond\nthird')
assert type(written) is int
assert written == 18
empty = root.joinpath('iter_empty.txt').write_text('')
assert type(empty) is int
assert empty == 0
binary = root.joinpath('lines.bin').write_bytes(b'a\nb\nc')
assert type(binary) is int
assert binary == 5

# iter() hands back the file itself, and every read shares one position.
handle = open(root / 'iter.txt')
assert iter(handle) is handle
assert next(handle) == 'first\n'
assert handle.readline() == 'second\n'
assert next(handle) == 'third'
try:
    next(handle)
    assert False, 'expected StopIteration'
except StopIteration:
    pass
assert next(handle, 'done') == 'done'
handle.close()

# next() with a default loads an unread file first.
handle = open(root / 'iter.txt')
assert next(handle, 'done') == 'first\n'
handle.close()

# An empty file ends at once.
handle = open(root / 'iter_empty.txt')
assert next(handle, 'done') == 'done'
handle.close()
handle = open(root / 'iter_empty.txt')
try:
    next(handle)
    assert False, 'expected StopIteration'
except StopIteration:
    pass
handle.close()

# A for loop loads an unread file on its first step.
collected = []
with open(root / 'iter.txt') as handle:
    for line in handle:
        collected.append(line)
assert collected == ['first\n', 'second\n', 'third']

# A break keeps the shared position.
with open(root / 'iter.txt') as handle:
    for line in handle:
        break
    assert line == 'first\n'
    assert [line for line in handle] == ['second\n', 'third']
    assert [line for line in handle] == []
    assert handle.read() == ''
    handle.seek(0)
    assert list(handle) == ['first\n', 'second\n', 'third']

with open(root / 'iter.txt') as handle:
    assert [line.strip() for line in handle if line.startswith('s')] == ['second']

with open(root / 'iter.txt') as handle:
    assert handle.read(3) == 'fir'
    assert list(handle) == ['st\n', 'second\n', 'third']

with open(root / 'iter.txt') as handle:
    assert [handle.readline(), handle.readline()] == ['first\n', 'second\n']
    assert sorted(handle) == ['third']

# A binary file yields bytes.
collected = []
with open(root / 'lines.bin', 'rb') as handle:
    for line in handle:
        assert type(line) is bytes
        collected.append(line)
assert collected == [b'a\n', b'b\n', b'c']

with open(root / 'iter_empty.txt') as handle:
    for line in handle:
        assert False, 'an empty file must not yield a line'

# A consumer that cannot yield to the host sees an unread file as unloaded.
handle = open(root / 'iter.txt')
try:
    list(handle)
    assert False, 'expected NotImplementedError'
except NotImplementedError as exc:
    assert str(exc) == "iterating an unread _io.TextIOWrapper is only supported by 'for' loops and next(); call seek(0) first to load it"
handle.seek(0)
assert list(handle) == ['first\n', 'second\n', 'third']
handle.close()

# A generator expression is a for loop, so it loads the file.
with open(root / 'iter.txt') as handle:
    assert list(line.strip() for line in handle) == ['first', 'second', 'third']

# A closed file cannot be iterated.
handle = open(root / 'iter.txt')
handle.close()
try:
    iter(handle)
    assert False, 'expected ValueError'
except ValueError as exc:
    assert str(exc) == 'I/O operation on closed file.'
try:
    for line in handle:
        pass
    assert False, 'expected ValueError'
except ValueError as exc:
    assert str(exc) == 'I/O operation on closed file.'

# A write-only file is not readable.
writer = open(root / 'iter_w.txt', 'w')
assert iter(writer) is writer
kind = 'no error'
message = ''
try:
    next(writer)
except Exception as exc:
    kind = type(exc).__name__
    message = str(exc)
assert kind == 'UnsupportedOperation', 'expected UnsupportedOperation, got ' + kind
assert message == 'not readable'
kind = 'no error'
message = ''
try:
    for line in writer:
        pass
except Exception as exc:
    kind = type(exc).__name__
    message = str(exc)
assert kind == 'UnsupportedOperation', 'expected UnsupportedOperation, got ' + kind
assert message == 'not readable'
writer.close()

42
''';
