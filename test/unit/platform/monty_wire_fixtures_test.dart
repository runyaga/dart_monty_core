// INDEPENDENTLY AUTHORED wire fixtures.
//
// Every other serialization test in this package round-trips through the
// package's OWN encoder: `fromJson(v.toJson())`. That structurally cannot catch
// the failure that matters most here -- an encoder and a decoder which agree on
// the SAME WRONG FORMAT pass every round trip and still break against Rust.
// A round trip tests self-consistency; it says nothing about the contract.
//
// So these literals are not written by Dart. Each was harvested from the REAL
// RUST ENCODER by running Python through the oracle binary:
//
//     podman exec -i dmc-build bash -lc \
//       'cd /work/dart_monty_core && printf %s "<the python>" > /tmp/o.py &&
//        ./native/target/release/oracle < /tmp/o.py'
//
// and taking the `value` field verbatim. The Python that produced each one is
// recorded beside it, so any fixture can be re-derived rather than trusted.
//
// Asserted in BOTH directions, because they fail differently:
//   DECODE  Rust's bytes -> the MontyValue we claim they mean.
//   ENCODE  our MontyValue -> byte-comparable to what Rust emits.
// Decode-only would let the encoder drift; encode-only would let the decoder.
//
// Harvested 2026-09-15 against monty v0.0.23 (tool/fixture-corpus.json).
//
// NOT covered here, stated so the count is not mistaken for the hierarchy:
//   - MontyOpaque -- no single Python expression produces one; it is what the
//     encoder falls back to.
//   - MontyFileHandle -- NOT unharvestable, and the earlier note here said so
//     only because it stopped at "the oracle returned null". The real reason,
//     from the oracle's `error` field:
//         NotImplementedError: OS function 'open' not implemented with
//         standard execution
//     The oracle runs with NO OS handler, so `open()` raises before any value
//     exists. A filehandle IS emittable through a mounted-OS-handler path --
//     see test/integration/ffi_mount_dir_test.dart -- which is where this row
//     has to be harvested from. Left out rather than hand-written, because a
//     Dart-authored literal would defeat the entire point of this file.
//
// A HARVESTING TRAP, recorded because it nearly produced a silent wrong
// fixture. The harvest read only the oracle's `value` field. On an exception
// the oracle emits `"value": null` PLUS an `error` object -- and `null` is
// also the legitimate literal for MontyNone, so the two are indistinguishable
// from `value` alone. Every fixture above was re-harvested 2026-09-15 with the
// `error` field checked: 24 of 24 clean. Any future harvest must check
// `error`, not just read `value`.
//   - MontyDataclass -- harvested, but it does NOT arrive as itself: a Python
//     dataclass comes over as `class_instance` with `is_dataclass: true`, so
//     that fixture decodes to a MontyClassInstance. No wire shape produces a
//     MontyDataclass from the current engine, and the wire carries no `frozen`
//     field at all -- so MontyDataclass.frozen has no wire source.
//
// A PREVIOUS VERSION OF THIS NOTE WAS WRONG and is corrected rather than
// quietly dropped: it claimed MontyClassInstance was unharvestable because
// Rust emits a fresh `id` and `instance_id` UUID per run. The ids are ordinary
// STRINGS in the literal, and a fixture pins the bytes it was harvested from
// -- it never re-harvests, so per-run variation is irrelevant. Both rows now
// exist.
@TestOn('vm || browser')
library;

import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_hierarchy_registry.dart';

/// Canonical JSON: key order is not part of the contract, so compare sorted.
///
/// Lists are NOT sorted -- a dict's `entries` shape is a list, and its order is
/// Python insertion order, which IS part of the contract.
String _canon(Object? o) {
  if (o is Map) {
    final keys = o.keys.map((k) => k as String).toList()..sort();
    final body = keys.map((k) => '${json.encode(k)}:${_canon(o[k])}').join(',');

    return '{$body}';
  }
  if (o is List) return '[${o.map(_canon).join(',')}]';

  return json.encode(o);
}

void main() {
  group('wire fixtures authored by Rust, not by us', () {
    wireFixtures.forEach((name, f) {
      test('$name: Rust bytes DECODE to the value we claim', () {
        final decoded = MontyValue.fromJson(json.decode(f.json));
        expect(decoded, f.value, reason: 'produced by: ${f.python}');

        // `==` ALONE IS NOT ENOUGH HERE, and that is the whole point of this
        // second assertion. Every MontyValue `==` deliberately matches PYTHON
        // semantics, so it compares an EQUIVALENCE CLASS, not a value:
        //   MontyFloat(-0.0) == MontyFloat(0.0)   is true (Python agrees)
        //   MontyDict / MontySet compare order-insensitively, by design
        // so a decoder that dropped the sign of -0.0, or reordered a dict,
        // satisfies the line above. MEASURED: making the decoder lose the sign
        // (`double.tryParse(s)?.abs()` in _taggedFloatFromMap) left the
        // equality assertion GREEN and the 131-test matrix GREEN.
        //
        // Re-encoding and comparing the TEXT is representation-sensitive, so it
        // sees what `==` is built to ignore -- and it closes this for all 24
        // fixtures at once rather than one hand-written probe per hazard.
        expect(
          _canon(decoded.toJson()),
          _canon(json.decode(f.json)),
          reason:
              'decoded to an EQUAL value that re-encodes differently: a '
              'representation was lost that `==` is defined not to see.\n'
              'produced by: ${f.python}',
        );
      });

      test('$name: our value ENCODES to what Rust emits', () {
        expect(
          _canon(f.value.toJson()),
          _canon(json.decode(f.json)),
          reason:
              'our encoder disagrees with the Rust encoder.\n'
              'produced by: ${f.python}',
        );
      });
    });

    test('the fixtures are not silently empty', () {
      // A table-driven suite whose table is empty reports success. This repo
      // has paid for that shape before.
      expect(wireFixtures.length, greaterThanOrEqualTo(24));
    });
  });
}
