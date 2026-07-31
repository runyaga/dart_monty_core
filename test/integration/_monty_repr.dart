// A CPython-style `repr()` renderer for MontyValue.
//
// This exists to break a circularity (core#129, core#130).
//
// The oracle conformance suite compares `MontyFfi` against the `oracle` binary,
// which links the same Rust crate and shares `convert.rs` with the FFI shim via
// `#[path = "../convert.rs"]`. Both sides of that comparison use the same
// encoder, so the suite is structurally unable to detect a bug *inside*
// `convert.rs` — which is exactly how dict-ordering and Ellipsis collapse
// survived 1062 "passing" fixtures.
//
// monty computes `repr()` in Rust, upstream, on the interpreter's own value
// model — before anything of ours touches it. So:
//
//     monty's repr(expr)          <- upstream, independent
//     render(decode(run(expr)))   <- our encoder + decoder + this renderer
//
// If those disagree, our value pipeline lost something. Concretely: when
// `convert.rs` sorted dict keys, monty's repr said `{'b': 1, 'a': 2}` while our
// side rendered `{'a': 2, 'b': 1}` — an immediate, unambiguous red.
//
// This renderer is deliberately hand-written rather than derived from anything
// in `lib/`. If it shared code with the encoder it would reintroduce the very
// circularity it exists to break.
import 'package:dart_monty_core/dart_monty_core.dart';

/// Renders [v] the way CPython's `repr()` would, matching monty's output.
String montyRepr(MontyValue v) => switch (v) {
  MontyNone() => 'None',
  MontyEllipsis() => 'Ellipsis',
  MontyBool(:final value) => value ? 'True' : 'False',
  // An int and a bigint render identically — CPython prints bare digits for
  // both, and the only difference is which side of i64 the value falls on.
  // Bound through `dartValue` rather than each variant's `value` field because
  // the two are `int` and `BigInt`, which an or-pattern cannot unify.
  MontyInt() || MontyBigInt() => '${v.dartValue}',
  MontyFloat(:final value) => _floatRepr(value),
  MontyString(:final value) => _strRepr(value),
  MontyBytes(:final value) => _bytesRepr(value),
  MontyList(:final items) => '[${items.map(montyRepr).join(', ')}]',
  // A 1-tuple keeps its trailing comma: `(1,)`, not `(1)`. The list pattern
  // binds the single element only when there IS exactly one, so this needs no
  // length check and no potentially-throwing .first/.single.
  MontyTuple(items: [final only]) => '(${montyRepr(only)},)',
  MontyTuple(:final items) => '(${items.map(montyRepr).join(', ')})',
  // The empty set has no literal form, so CPython prints `set()`.
  MontySet(:final items) =>
    items.isEmpty ? 'set()' : '{${items.map(montyRepr).join(', ')}}',
  MontyFrozenSet(:final items) =>
    'frozenset({${items.map(montyRepr).join(', ')}})',
  MontyDict(:final entries) => _dictRepr(entries),
  // ---- Tier 2 variants ----------------------------------------------------
  // Each rendering was MEASURED against monty's own repr(), not guessed:
  //   repr(2**63)              = 9223372036854775808  (with MontyInt, above)
  //   repr(ValueError("boom")) = ValueError('boom')
  //   repr(int)               = <class 'int'>
  //   repr(abs)               = <built-in function abs>
  MontyExceptionValue(:final excType, :final message) =>
    message == null ? '$excType()' : '$excType(${_strRepr(message)})',
  // The wire carries the NAME for a type and a builtin, and CPython's repr
  // wraps it. For `repr` and `cycle` the text already IS the rendering.
  MontyOpaque(kind: MontyOpaqueKind.type, :final text) => "<class '$text'>",
  MontyOpaque(kind: MontyOpaqueKind.builtin, :final text) =>
    '<built-in function $text>',
  MontyOpaque(:final text) => text,
  // Non-string-key dicts (the `entries` envelope, Tier 1). CPython renders them
  // exactly like any other dict — `{1: 'a'}` — so the keys go through the same
  // renderer as the values rather than being stringified.
  MontyPairsDict(:final pairs) => '{${_pairsRepr(pairs)}}',
  // Rendered so the differential can SEE a forged type. monty reports
  // `{"__type":"path","value":"x"}` as a dict; if our pipeline decodes it to a
  // MontyPath, the strings differ and the test goes red — which is how the
  // forgery in core#136 becomes visible to an instrument rather than to a
  // hand-written probe. CPython renders a path as `PosixPath('…')`.
  MontyPath(:final value) => "PosixPath('$value')",
  // Types this renderer does not model. Returning a sentinel rather than
  // throwing keeps the differential test able to report "unsupported" as a
  // skip instead of dying.
  _ => '<unsupported:${v.runtimeType}>',
};

String _dictRepr(Map<String, MontyValue> entries) {
  final parts = entries.entries.map(
    (e) => '${_strRepr(e.key)}: ${montyRepr(e.value)}',
  );

  return '{${parts.join(', ')}}';
}

/// `4.0`, `inf`, `-0.0`, `1e+100`, `0.30000000000000004`.
String _floatRepr(double d) {
  if (d.isNaN) return 'nan';
  if (d.isInfinite) return d > 0 ? 'inf' : '-inf';
  if (d == 0) return d.isNegative ? '-0.0' : '0.0';

  final s = d.toString();
  // Dart and CPython agree on `1e+100` and `1.0`.
  // Dart can print `1e100` without the `+`, which CPython always includes.
  if (s.contains('e') && !s.contains('e+') && !s.contains('e-')) {
    return s.replaceFirst('e', 'e+');
  }

  return s;
}

/// CPython prefers single quotes, and switches to double quotes when the string
/// contains a single quote but no double quote: `"it's"`.
String _strRepr(String s) {
  if (s.contains("'") && !s.contains('"')) return '"$s"';

  return "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
}

String _bytesRepr(List<int> bytes) {
  final buf = StringBuffer("b'");
  for (final b in bytes) {
    if (b == 0x27) {
      buf.write(r"\'");
    } else if (b == 0x5c) {
      buf.write(r'\\');
    } else if (b >= 0x20 && b < 0x7f) {
      buf.writeCharCode(b);
    } else if (b == 0x0a) {
      buf.write(r'\n');
    } else if (b == 0x0d) {
      buf.write(r'\r');
    } else if (b == 0x09) {
      buf.write(r'\t');
    } else {
      buf.write('\\x${b.toRadixString(16).padLeft(2, '0')}');
    }
  }
  buf.write("'");

  return buf.toString();
}

/// Renders `(key, value)` pairs the way CPython renders a dict body.
String _pairsRepr(List<(MontyValue, MontyValue)> pairs) =>
    pairs.map((p) => '${montyRepr(p.$1)}: ${montyRepr(p.$2)}').join(', ');
