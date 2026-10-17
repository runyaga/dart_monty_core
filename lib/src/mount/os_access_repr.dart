part of 'os_access.dart';

/// Python's `repr` of a keyword dict, for upstream's assertion message.
String _dictRepr(Map<String, MontyValue> entries) {
  final repr = _OsAccessRepr();
  final items = [
    for (final MapEntry(:key, :value) in entries.entries)
      '${pythonRepr(key)}: ${repr.of(value)}',
  ];

  return '{${items.join(', ')}}';
}

/// Python's `repr` of a [MontyValue]. A container that holds itself shows
/// `[...]`, `(...)` or `{...}`. A kind this class does not print, such as a
/// date, shows its Dart type.
final class _OsAccessRepr {
  final Set<MontyValue> _open = Set.identity();

  String of(MontyValue arg) => switch (arg) {
    MontyNone() => 'None',
    MontyBool(:final value) => value ? 'True' : 'False',
    MontyInt(:final value) => '$value',
    MontyBigInt(:final value) => value.toString(),
    MontyFloat(:final value) => _floatRepr(value),
    MontyString(:final value) => pythonRepr(value),
    MontyBytes(:final value) => _bytesRepr(value),
    _ => _structured(arg),
  };

  String _structured(MontyValue arg) => switch (arg) {
    MontyComplex(:final real, :final imag) => _complexRepr(real, imag),
    MontyPath(:final value) => 'PurePosixPath(${pythonRepr(value)})',
    _ => _container(arg),
  };

  String _container(MontyValue arg) {
    if (!_open.add(arg)) return _marker(arg);
    try {
      return _items(arg);
    } finally {
      _open.remove(arg);
    }
  }

  String _marker(MontyValue arg) => switch (arg) {
    MontyDict() => '{...}',
    MontyTuple() => '(...)',
    _ => '[...]',
  };

  String _items(MontyValue arg) => switch (arg) {
    MontyList(:final items) => '[${_join(items)}]',
    MontyTuple(:final items) =>
      '(${_join(items)}${items.length == 1 ? ',' : ''})',
    MontyDict(:final pairs) =>
      '{${pairs.map((p) => '${of(p.$1)}: ${of(p.$2)}').join(', ')}}',
    _ => _sets(arg),
  };

  String _sets(MontyValue arg) => switch (arg) {
    MontySet(:final items) => items.isEmpty ? 'set()' : '{${_join(items)}}',
    MontyFrozenSet(:final items) =>
      items.isEmpty ? 'frozenset()' : 'frozenset({${_join(items)}})',
    _ => '<${arg.runtimeType}>',
  };

  String _join(List<MontyValue> items) => items.map(of).join(', ');
}

/// A float as Python prints it: the shortest digits, in exponent form below
/// 1e-4 and from 1e16.
String _floatRepr(double value) {
  if (value.isNaN) return 'nan';
  if (value.isInfinite) return value.isNegative ? '-inf' : 'inf';
  final parts = value.abs().toStringAsExponential().split('e');
  final exponent = int.parse(parts.lastOrNull ?? '0');
  if (exponent >= -4 && exponent < 16) return exactDoubleText(value);
  final mantissa = (parts.firstOrNull ?? '').replaceFirst(RegExp(r'\.0$'), '');
  final sign = value.isNegative ? '-' : '';
  final digits = exponent.abs().toString().padLeft(2, '0');

  return '$sign${mantissa}e${exponent < 0 ? '-' : '+'}$digits';
}

/// Bytes as Python prints them: `b'...'`, a double quote only when the
/// content holds a single quote and no double quote.
String _bytesRepr(List<int> bytes) {
  final quote = bytes.contains(39) && !bytes.contains(34) ? 34 : 39;
  final text = StringBuffer('b${String.fromCharCode(quote)}');
  for (final byte in bytes) {
    text.write(switch (byte) {
      92 => r'\\',
      9 => r'\t',
      10 => r'\n',
      13 => r'\r',
      _ when byte == quote => '\\${String.fromCharCode(byte)}',
      >= 32 && <= 126 => String.fromCharCode(byte),
      _ => '\\x${byte.toRadixString(16).padLeft(2, '0')}',
    });
  }
  text.write(String.fromCharCode(quote));

  return text.toString();
}

/// A complex number as Python prints it: `2j`, `(1+2j)`, `(1-0.5j)`.
String _complexRepr(double real, double imag) {
  final imaginary = _floatRepr(imag).replaceFirst(RegExp(r'\.0$'), '');
  if (real == 0 && !real.isNegative) return '${imaginary}j';
  final realText = _floatRepr(real).replaceFirst(RegExp(r'\.0$'), '');
  final sign = imaginary.startsWith('-') ? '' : '+';

  return '($realText$sign${imaginary}j)';
}
