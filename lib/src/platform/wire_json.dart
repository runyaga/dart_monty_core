import 'dart:convert';

import 'package:dart_monty_core/src/platform/monty_value.dart';

/// A JSON string that provably came out of [MontyValue]'s encoder.
///
/// **This type exists to turn core#136 into a compile error.**
///
/// The bindings layer used to take `String valueJson`, which any caller could
/// satisfy with a raw `jsonEncode(hostValue)`. Three sites in the self-driven
/// drive loop did exactly that, so a host callback's return travelled to the
/// interpreter unwrapped — and a `{"__type": "filehandle", …}` map the
/// *sandbox* authored was read by the interpreter as a real file handle. Tier 1
/// (`2808edb`) fixed the Python → Dart direction and the strict decoder that
/// came with it, but nothing constrained Dart → Python, and every instrument in
/// the repo reads values *out* of Python, so three tiers, a 17-step gate and
/// green CI never saw it.
///
/// A test can only observe the sites it thought to visit; `resume('null')` at
/// the `resolve_futures` branch was a FOURTH unencoded site, on no audit's list
/// because it carries a literal rather than a `jsonEncode` call.
/// A nominal type visits all of them, because the only way to obtain a
/// [WireJson] is to ask this class to mint one.
///
/// Not exported from `dart_monty_core.dart` — `core_bindings` has zero export
/// hits, so this is an internal boundary, not a public API change. The public
/// surface still takes `Object?` and encodes on the caller's behalf.
///
/// **The guarantee is compile-time, not runtime.** An extension type is erased,
/// so at runtime a [WireJson] *is* its `String`, and `rawJson as WireJson`
/// compiles and succeeds. That is not a gap in the defence, because the threat
/// it defends against is a maintainer reaching for `jsonEncode` — the untrusted
/// party is the sandboxed Python, which cannot reach this type at all. Anyone
/// writing that cast has left the guardrail deliberately, which is the most a
/// zero-cost type can ask for. Do not read the type as a runtime validator.
extension type const WireJson._(String encoded) {
  /// Encodes a single host-supplied value.
  ///
  /// Delegates to [MontyValue.encodeForWire], which wraps host maps as
  /// `{"__type": "dict", "value": {…}}` **at every depth** — so a `__type` key
  /// sitting in ordinary host data (a parsed JSON body, a database row, an LLM
  /// tool payload) is already inert once it is routed through here. That is why
  /// this does not throw on encountering one: rejecting would reserve `__type`
  /// across all host data to close a hole that wrapping has already closed.
  factory WireJson.value(Object? value) =>
      WireJson._(MontyValue.encodeForWire(value));

  /// Frames the `callId -> value` map the futures path resolves with.
  ///
  /// The OUTER map is protocol framing, so it stays a bare JSON object; each
  /// VALUE goes through the encoder like any other. That rule was previously
  /// written out by hand in four places — correctly in three
  /// (`MontyRepl.resolveFutures`, `MontyFfi`, `MontyWasm`) and not at all in
  /// the drive loop. Having one implementation is the point.
  factory WireJson.callResults(Map<int, Object?> results) => WireJson._(
    jsonEncode(
      results.map(
        (k, v) => MapEntry(k.toString(), MontyValue.fromDart(v).toJson()),
      ),
    ),
  );

  /// Frames the `callId -> message` map accompanying [WireJson.callResults].
  ///
  /// These are error *messages*, not values — they become `RuntimeError` text
  /// in Python and never reach the value decoder. They are typed anyway so that
  /// `resolveFutures` cannot be called with a hand-built string in either
  /// position. A null or absent map frames as `{}`.
  factory WireJson.callErrors(Map<int, String>? errors) => WireJson._(
    jsonEncode(errors?.map((k, v) => MapEntry(k.toString(), v)) ?? const {}),
  );
}
