/// Upstream's per-node rules for a monty-proto `MontyNode`.
///
/// [checkNode] is the first of upstream's three validation stages: each node
/// on its own, as `node_from_proto` checks it once its protobuf merge has
/// finished (monty-proto 1.1.0, `src/wire.rs`). It rejects exactly what that
/// function rejects, with the same message text, and nothing more. The other
/// two stages (references between nodes, then the Python objects built from
/// them) are in `arena_reader.dart`.
///
/// The name sets below are upstream's at the pinned commit: the strings
/// `MontyType::from_type_name`, `BuiltinsFunctions::from_str` and
/// `ExcType::from_str` accept. The worker validates the same names, so the
/// round-trip tests through the real worker catch a set that falls behind.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

/// `TypeOrigin`'s numbers; the generator declares `Type.origin` as `int32`,
/// so the raw number arrives even when it names no origin.
const int originUnspecified = 0;

/// A builtin type: `int`, `ValueError`.
const int originBuiltin = 1;

/// A class defined in the sandbox.
const int originSandbox = 2;

/// A class defined by the host.
const int originHost = 3;

/// The smallest UTC offset `datetime.timezone` accepts, in seconds.
const int minOffsetSeconds = -86399;

/// The largest UTC offset `datetime.timezone` accepts, in seconds.
const int maxOffsetSeconds = 86399;

/// Checks [node] as upstream's `node_from_proto` does.
///
/// Throws [FormatException] carrying upstream's message for the first rule
/// [node] breaks.
void checkNode(pb.MontyNode node) => switch (node.whichKind()) {
  // The schema reserves the uuid arm; upstream rejects it as absent.
  pb.MontyNode_Kind.notSet || pb.MontyNode_Kind.uuid => _missing(
    'MontyNode.kind',
  ),
  final kind => _checks[kind]?.call(node),
};

/// Whether [checkNode] has a rule for a node of [kind]. A node of any other
/// kind passes [checkNode] whatever it holds.
bool checksKind(pb.MontyNode_Kind kind) =>
    kind == pb.MontyNode_Kind.notSet ||
    kind == pb.MontyNode_Kind.uuid ||
    _checks.containsKey(kind);

/// The kinds upstream checks; the others it converts as they are.
final Map<pb.MontyNode_Kind, void Function(pb.MontyNode)> _checks = {
  pb.MontyNode_Kind.complex: (n) => _checkComplex(n.complex),
  pb.MontyNode_Kind.type: (n) => _checkType(n.type),
  pb.MontyNode_Kind.classInstance: (n) => _checkInstance(n.classInstance),
  pb.MontyNode_Kind.date: (n) =>
      checkDate(n.date.year, n.date.month, n.date.day, 'Date'),
  pb.MontyNode_Kind.datetime: (n) => _checkDateTime(n.datetime),
  pb.MontyNode_Kind.time: (n) => _checkTime(n.time),
  pb.MontyNode_Kind.timedelta: (n) => _checkTimedelta(n.timedelta),
  pb.MontyNode_Kind.timezone: (n) =>
      checkOffset(n.timezone.offsetSeconds, 'TimeZone.offset_seconds'),
  pb.MontyNode_Kind.exception: (n) =>
      _known(exceptionTypeNames, n.exception.excType, 'exception type'),
  pb.MontyNode_Kind.builtinFunction: (n) =>
      _known(builtinFunctionNames, n.builtinFunction, 'builtin function'),
  pb.MontyNode_Kind.fileHandle: (n) => _checkMode(n.fileHandle.mode),
};

void _checkComplex(pb.Complex c) {
  if (!c.hasReal()) _missing('Complex.real');
  if (!c.hasImag()) _missing('Complex.imag');
}

void _checkInstance(pb.ClassInstanceNode instance) {
  if (!instance.hasInstanceId()) _missing('ClassInstanceNode.instance_id');
  if (!instance.hasAttrs()) _missing('ClassInstanceNode.attrs');
  _checkUuid(instance.instanceId, 'ClassInstanceNode.instance_id');
}

void _checkDateTime(pb.DateTime d) {
  checkZoneName(
    hasOffset: d.hasOffsetSeconds(),
    hasName: d.hasTimezoneName(),
    message: 'DateTime',
  );
  checkDate(d.year, d.month, d.day, 'DateTime');
  checkClock(d.hour, d.minute, d.second, d.microsecond, 'DateTime');
  if (d.hasOffsetSeconds()) {
    checkOffset(d.offsetSeconds, 'DateTime.offset_seconds');
  }
}

void _checkTime(pb.Time t) {
  checkZoneName(
    hasOffset: t.hasOffsetSeconds(),
    hasName: t.hasTimezoneName(),
    message: 'Time',
  );
  checkClock(t.hour, t.minute, t.second, t.microsecond, 'Time');
  if (t.hasOffsetSeconds()) {
    checkOffset(t.offsetSeconds, 'Time.offset_seconds');
  }
  checkFold(t.fold);
}

void _checkTimedelta(pb.TimeDelta td) {
  checkNormalized(td.seconds, 86400, 'TimeDelta.seconds');
  checkNormalized(td.microseconds, 1000000, 'TimeDelta.microseconds');
}

/// A zone name needs an offset.
void checkZoneName({
  required bool hasOffset,
  required bool hasName,
  required String message,
}) {
  if (!hasOffset && hasName) {
    invalidNode(
      'invalid value for $message.timezone_name: timezone_name requires '
      'offset_seconds',
    );
  }
}

/// A time's fold, 0 or 1.
void checkFold(int fold) => _ranged(fold, 0, 1, 'Time.fold');

void _known(Set<String> names, String name, String what) {
  if (!names.contains(name)) invalidNode('unknown $what ${rustDebug(name)}');
}

void _checkMode(String mode) {
  if (canonicalFileMode(mode) == null) {
    invalidNode('invalid file mode ${rustDebug(mode)}');
  }
}

/// Upstream's `type_to_node`: the origin first, then the fields it allows.
void _checkType(pb.Type type) {
  switch (type.origin) {
    case originUnspecified:
      invalidNode('invalid value for Type: origin must be specified');
    case originBuiltin:
      if (type.hasId()) {
        invalidNode(
          'invalid value for Type: a builtin type must not carry '
          'an id',
        );
      }
      if (type.hasAttrs()) {
        invalidNode(
          'invalid value for Type: a builtin type must not carry '
          'attrs',
        );
      }
      if (!builtinTypeNames.contains(type.name)) {
        invalidNode('unknown type name ${rustDebug(type.name)}');
      }
    case originSandbox || originHost:
      if (!type.hasId()) {
        invalidNode('invalid value for Type: a class type must carry an id');
      }
      _checkUuid(type.id, 'Type.id');
    default:
      invalidNode(
        'invalid value for Type.origin: unknown origin ${type.origin}',
      );
  }
}

void _checkUuid(pb.Uuid uuid, String field) {
  final length = uuid.data.length;
  if (length != 16) {
    invalidNode(
      'invalid value for $field: uuid must be 16 bytes, got $length',
    );
  }
}

/// Upstream's `date_fields`: year 1..=9999, month 1..=12, then the day for
/// that month. [message] names the fields, `Date` or `DateTime`.
void checkDate(int year, int month, int day, String message) {
  if (year < 1 || year > 9999) {
    invalidNode(
      'invalid value for $message.year: $year is outside the range 1..=9999',
    );
  }
  _ranged(month, 1, 12, '$message.month');
  _ranged(day, 1, daysInMonth(year, month), '$message.day');
}

/// The hour, minute, second and microsecond rules of a time or datetime.
void checkClock(
  int hour,
  int minute,
  int second,
  int microsecond,
  String message,
) {
  _ranged(hour, 0, 23, '$message.hour');
  _ranged(minute, 0, 59, '$message.minute');
  _ranged(second, 0, 59, '$message.second');
  if (microsecond > 999999) {
    invalidNode(
      'invalid value for $message.microsecond: $microsecond exceeds maximum '
      '999999',
    );
  }
}

/// Upstream's `timezone_offset`.
void checkOffset(int offset, String field) {
  if (offset < minOffsetSeconds || offset > maxOffsetSeconds) {
    invalidNode(
      'invalid value for $field: $offset is outside the range '
      '$minOffsetSeconds..=$maxOffsetSeconds',
    );
  }
}

/// Upstream's `normalized`: [value] in `0..max`, max excluded.
void checkNormalized(int value, int max, String field) {
  if (value < 0 || value >= max) {
    invalidNode(
      'invalid value for $field: $value is outside the normalized range '
      '0..$max',
    );
  }
}

/// Days in [month] of [year], proleptic Gregorian; [month] is 1..12.
int daysInMonth(int year, int month) => switch (month) {
  2 when year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
  2 => 28,
  4 || 6 || 9 || 11 => 30,
  _ => 31,
};

void _ranged(int value, int min, int max, String field) {
  if (value < min || value > max) {
    invalidNode(
      'invalid value for $field: $value is outside the range $min..=$max',
    );
  }
}

Never _missing(String field) => invalidNode('missing required field $field');

/// Throws the [FormatException] for a node upstream rejects.
///
/// Upstream formats the message into a 512-byte buffer and, when it does not
/// fit, reports that instead (`wire.rs`, `to_decode_err`).
Never invalidNode(String message) => throw FormatException(
  utf8.encode(message).length > 512
      ? 'invalid wire value (error message exceeds 512 bytes)'
      : message,
);

/// The canonical form of the `open()` [mode], or null when upstream's
/// `FileMode::from_str` rejects it.
///
/// Exactly one of `r`, `w`, `a`; at most one `b` and one `t`, not both; no
/// `x` or `+`; any order. `rt` becomes `r` and `br` becomes `rb`, as CPython
/// normalizes them.
String? canonicalFileMode(String mode) {
  final chars = mode.split('');
  int count(String c) => chars.where((x) => x == c).length;
  final action = [
    for (final a in const ['r', 'w', 'a'])
      if (chars.contains(a)) a,
  ].singleOrNull;
  final binary = count('b');
  final valid =
      action != null &&
      chars.every('rwabt'.contains) &&
      count(action) == 1 &&
      binary + count('t') <= 1;

  final suffix = binary == 1 ? 'b' : '';

  return valid ? '$action$suffix' : null;
}

/// [s] as Rust's `{:?}` renders a string: in double quotes, with `\\` and
/// `"` escaped, `\t`, `\n`, `\r` and `\0` named, and every character Rust
/// escapes written `\u{hex}`.
///
/// Rust escapes what its Unicode tables call unprintable or grapheme
/// extending. That is matched here by general category (controls, format,
/// line and paragraph separators, spaces other than U+0020, private use,
/// unassigned), the Grapheme_Extend property, and the four Hangul fillers;
/// measured against Rust over every code point, the only differences are
/// characters one side's Unicode version assigns and the other's does not.
String rustDebug(String s) {
  final out = StringBuffer('"');
  for (final c in s.runes) {
    out.write(_rustEscape(c));
  }
  out.write('"');

  return out.toString();
}

String _rustEscape(int c) => switch (c) {
  0x09 => r'\t',
  0x0a => r'\n',
  0x0d => r'\r',
  0x22 => r'\"',
  0x5c => r'\\',
  0x00 => r'\0',
  0x20 => ' ',
  _ when _rustEscaped.hasMatch(String.fromCharCode(c)) =>
    '\\u{${c.toRadixString(16)}}',
  _ => String.fromCharCode(c),
};

final RegExp _rustEscaped = RegExp(
  r'^[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Zs}\p{Co}\p{Cn}\p{Cs}\p{Grapheme_Extend}'
  r'\u115F\u1160\u3164\uFFA0]$',
  unicode: true,
);

/// The 16 bytes of [uuid] as a canonical lowercase uuid string.
String uuidString(List<int> uuid) {
  final hex = [
    for (final b in uuid) b.toRadixString(16).padLeft(2, '0'),
  ].join();

  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Every name `MontyType::from_type_name` accepts: the builtin types, then
/// the exception types.
final Set<String> builtinTypeNames = {
  ..._typeNames.split(' '),
  ...exceptionTypeNames,
};

/// Every name `ExcType::from_str` accepts.
final Set<String> exceptionTypeNames = _excNames.split(' ').toSet();

/// Every name `BuiltinsFunctions::from_str` accepts.
final Set<String> builtinFunctionNames = _functionNames.split(' ').toSet();

const String _typeNames =
    'ellipsis type NoneType bool int float complex range slice datetime.date '
    'datetime.datetime datetime.timedelta datetime.timezone str bytes list '
    'collections.deque list_iterator callable_iterator tuple namedtuple dict '
    'dict_keys dict_items dict_values set frozenset function '
    'builtin_function_or_method cell iterator coroutine module '
    '_io.TextIOWrapper _io.BufferedReader _io.BufferedWriter '
    '_io.BufferedRandom typing._SpecialForm PosixPath property re.Pattern '
    're.Match tuple_iterator str_ascii_iterator str_iterator bytes_iterator '
    'range_iterator dict_keyiterator dict_itemiterator dict_valueiterator '
    'set_iterator itertools.count itertools.repeat Field itertools.pairwise '
    'itertools.compress itertools.islice itertools.chain itertools.cycle '
    'NotImplementedType _DataclassParams itertools.takewhile '
    'itertools.dropwhile itertools.filterfalse itertools.starmap object '
    'datetime.time functools.partial itertools.accumulate itertools.batched '
    'itertools.zip_longest types.GenericAlias typing.Union '
    'itertools.combinations itertools.combinations_with_replacement '
    'itertools.permutations itertools.product itertools.groupby '
    'itertools._grouper itertools._tee itertools._tee_dataobject';

const String _excNames =
    'Exception BaseException SystemExit KeyboardInterrupt ArithmeticError '
    'OverflowError ZeroDivisionError LookupError IndexError KeyError '
    'RuntimeError NotImplementedError RecursionError AttributeError '
    'FrozenInstanceError NameError UnboundLocalError ValueError '
    'UnicodeDecodeError UnicodeEncodeError json.JSONDecodeError ImportError '
    'ModuleNotFoundError OSError FileNotFoundError FileExistsError '
    'IsADirectoryError NotADirectoryError PermissionError '
    'io.UnsupportedOperation TimeoutError AssertionError MemoryError '
    'StopIteration SyntaxError TypeError re.PatternError binascii.Error '
    'binascii.Incomplete';

const String _functionNames =
    'abs all any bin chr divmod enumerate filter getattr hasattr hash hex id '
    'isinstance len map max min next oct open ord pow print repr reversed '
    'round setattr sorted sum type zip object.__setattr__ format eval exec '
    'locals';
