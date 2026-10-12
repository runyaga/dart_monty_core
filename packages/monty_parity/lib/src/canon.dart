/// Canonical value and outcome forms shared by the parity runners (pure Dart,
/// web-safe). They mirror tool/parity/oracle/run_cases.py.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Canonical float: `bits` (IEEE-754 big-endian hex) is compared, `v` is
/// display.
Map<String, Object?> canonFloat(double x) {
  final bd = ByteData(8)..setFloat64(0, x);
  final sb = StringBuffer();
  for (var i = 0; i < 8; i++) {
    sb.write(bd.getUint8(i).toRadixString(16).padLeft(2, '0'));
  }
  return {'t': 'float', 'v': _floatText(x), 'bits': sb.toString()};
}

String _floatText(double x) {
  if (x.isNaN) return 'nan';
  if (x.isInfinite) return x > 0 ? 'inf' : '-inf';
  if (x == 0) return x.isNegative ? '-0.0' : '0.0';
  final s = x.toString();
  return s.contains('.') || s.contains('e') ? s : '$s.0';
}

/// Decodes a float canonical (prefers `bits`).
double decodeFloat(Map<String, Object?> c) {
  final bits = c['bits'] as String?;
  if (bits != null) {
    final bd = ByteData(8);
    for (var i = 0; i < 8; i++) {
      bd.setUint8(i, int.parse(bits.substring(i * 2, i * 2 + 2), radix: 16));
    }
    return bd.getFloat64(0);
  }
  final v = c['v']! as String;
  return switch (v) {
    'nan' => double.nan,
    'inf' => double.infinity,
    '-inf' => double.negativeInfinity,
    _ => double.parse(v),
  };
}

/// Lower-case hex of [bytes].
String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The bytes [hex] encodes.
List<int> bytesOfHex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

/// Sorts set items by their JSON text (cosmetic; the diff re-normalises).
List<Object?> sortedItems(List<Object?> items) =>
    [...items]..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));

/// Merges adjacent same-stream print segments.
List<Map<String, String>> mergePrints(List<(String, String)> raw) {
  final out = <Map<String, String>>[];
  for (final (stream, text) in raw) {
    if (out.isNotEmpty && out.last['stream'] == stream) {
      out.last['text'] = out.last['text']! + text;
    } else {
      out.add({'stream': stream, 'text': text});
    }
  }
  return out;
}

/// A fresh step record.
Map<String, Object?> newStep() => {
  'value': null,
  'exception': null,
  'prints': <Object?>[],
  'os_calls': <Object?>[],
  'ext_calls': <Object?>[],
  'name_lookups': <Object?>[],
  'host_calls': <Object?>[],
  'usage': null,
};

/// Per-name, per-call-order scripted responses.
class Script {
  /// The scripted answers of case [case_].
  Script(Map<String, Object?> case_)
    : externals =
          (case_['externals'] as Map?)?.cast<String, Object?>() ?? const {},
      os = (case_['os'] as Map?)?.cast<String, Object?>() ?? const {};

  /// Answers for external functions, by name.
  final Map<String, Object?> externals;

  /// Answers for OS calls, by operation name.
  final Map<String, Object?> os;

  final _used = <String, int>{};

  /// The next scripted answer for [name] (`{'return': c}` / `{'raise': {...}}`), or null.
  Map<String, Object?>? next(String name, {required bool isOs}) {
    final key = '${isOs ? 'os' : 'ext'}:$name';
    final i = _used[key] ?? 0;
    _used[key] = i + 1;
    final list = (isOs ? os : externals)[name] as List?;
    if (list == null || i >= list.length) return null;
    return (list[i] as Map).cast<String, Object?>();
  }
}

/// Outcome skeleton.
Map<String, Object?> newOutcome(String caseId, String engine, String backend) =>
    {
      'case': caseId,
      'engine': engine,
      'backend': backend,
      'engine_version': null,
      'steps': <Object?>[],
      'unsupported': <String, Object?>{},
      'notes': <String, Object?>{},
      'runner_error': null,
    };

/// Marker prefix for outcomes printed by browser runs (`dart test -p chrome`).
const outcomeMarker = 'PARITY_OUTCOME ';

/// Marker prefix for probe outcomes printed by browser runs.
const probeMarker = 'PARITY_PROBE ';

/// ISO-8601 parts as written (no local-time conversion): y, m, d, h, mi, s,
/// us, offsetSeconds (null = naive).
({int y, int m, int d, int h, int mi, int s, int us, int? off}) isoParts(
  String iso,
) {
  final r = RegExp(
    r'^(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d)(?:\.(\d{1,6}))?)?)?(Z|[+-]\d\d:\d\d)?$',
  ).firstMatch(iso);
  if (r == null) throw FormatException('bad iso $iso');
  int g(int i) => r.group(i) == null ? 0 : int.parse(r.group(i)!);
  final frac = r.group(7);
  final us = frac == null ? 0 : int.parse(frac.padRight(6, '0'));
  int? off;
  final z = r.group(8);
  if (z == 'Z') {
    off = 0;
  } else if (z != null) {
    final sign = z[0] == '-' ? -1 : 1;
    off =
        sign *
        (int.parse(z.substring(1, 3)) * 3600 +
            int.parse(z.substring(4, 6)) * 60);
  }
  return (
    y: g(1),
    m: g(2),
    d: g(3),
    h: g(4),
    mi: g(5),
    s: g(6),
    us: us,
    off: off,
  );
}
