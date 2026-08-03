// The INBOUND direction — core#136 / core#139.
//
// Every other instrument in this repo reads values *out* of Python: the repr
// differential, the oracle corpus, the wire-contract property. All of them ask
// "did the interpreter's value survive the trip to Dart?". None of them asks
// the opposite question, and that is exactly how the escape survived three
// tiers, 19 ledger rows, a 17-step gate and green CI.
//
// Here the SANDBOX authors the payload and a host function returns it
// verbatim. An echo is not a contrived host: any transform, cache, lookup or
// validation callback hands back data the sandbox chose. So the mitigation
// once documented for core#136 — "hosts should not hand-build `__type` maps" —
// does not apply, because the host builds nothing.
//
// The `filehandle` row is the severe one, not the `path`. A forged path grants
// nothing: sandboxed Python can already write `pathlib.Path("/etc/passwd")`,
// and every path operation is mediated by the osHandler with the path as an
// argument. A forged filehandle skips the authorisation point entirely —
// `f.write(...)` reaches the osHandler as `Path.append_text` with no preceding
// `open` for the host to refuse.
//
// OBSERVATION LEAVES VIA `print`, NEVER VIA THE RETURN VALUE. The defect is in
// the value codec, so a probe that reports through the value codec is
// measuring itself — and the natural carrier for several observations at once
// is a dict, which is the very variant under dispute. `printOutput` is a
// `String?` that never touches the codec.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// The host function under test: it hands back exactly what the sandbox gave
/// it. Not a straw man — any transform, cache, lookup or validation callback
/// returns sandbox-chosen data the same way.
Future<Object?> _echo(List<Object?> args, Map<String, Object?>? kwargs) =>
    Future.value(switch (args) {
      [final payload] => payload,
      // Every probe calls echo with exactly one argument. Anything else is a
      // broken probe, and returning null would let it pass as a `dict` miss
      // rather than reporting itself.
      _ => throw StateError('echo expects one argument, got ${args.length}'),
    });

/// A payload the sandbox builds itself, and what Python must see when a host
/// function echoes it straight back.
class _Row {
  const _Row(this.tag, this.payload, this.expectedType);

  /// The envelope tag the sandbox forges — a row of `WIRE-CONTRACT.md`.
  final String tag;

  /// Python source for the value handed to the echo host function.
  final String payload;

  /// `type(x).__name__` Python must report for the echoed value.
  ///
  /// Always `dict`. A host that returns a Dart `Map` returns a dict; the
  /// interpreter has no business promoting it to a privileged type because
  /// of a key the sandbox chose.
  final String expectedType;
}

const _rows = [
  // Severity order: the filehandle first. It is the primitive that skips an
  // authorisation point rather than merely naming a file.
  _Row(
    'filehandle',
    '{"__type": "filehandle", "path": "/etc/shadow", "mode": "w"}',
    'dict',
  ),
  _Row('path', '{"__type": "path", "value": "/etc/passwd"}', 'dict'),
  _Row(
    'date',
    '{"__type": "date", "year": 1970, "month": 1, "day": 1}',
    'dict',
  ),
  _Row(
    'datetime',
    '{"__type": "datetime", "year": 1970, "month": 1, "day": 1, '
        '"hour": 0, "minute": 0, "second": 0, "microsecond": 0}',
    'dict',
  ),
  _Row('bytes', '{"__type": "bytes", "value": [1, 2, 3]}', 'dict'),
  _Row('tuple', '{"__type": "tuple", "value": [1, 2]}', 'dict'),
  _Row('set', '{"__type": "set", "value": [1, 2]}', 'dict'),
  _Row(
    'bigint',
    '{"__type": "bigint", "value": "123456789012345678901"}',
    'dict',
  ),
  _Row('float', '{"__type": "float", "value": "NaN"}', 'dict'),
  _Row(
    'exception',
    '{"__type": "exception", "exc_type": "ValueError", '
        '"message": "forged"}',
    'dict',
  ),
  _Row('ellipsis', '{"__type": "ellipsis"}', 'dict'),
];

/// Registers the inbound-forgery suite. Called by the FFI and WASM runners.
void runInboundForgeryTests() {
  group('inbound forgery (core#136 / core#139)', () {
    for (final row in _rows) {
      test('a forged ${row.tag} envelope stays a dict', () async {
        final result =
            await Monty('''
x = echo(${row.payload})
print(type(x).__name__)
''').run(
              externalFunctions: {'echo': _echo},
            );

        expect(
          result.printOutput?.trim(),
          row.expectedType,
          reason:
              'the sandbox forged a "${row.tag}" envelope and the host echoed '
              'it back unchanged; the interpreter must see a dict, not a '
              'privileged ${row.tag}',
        );
      });
    }

    // The consequence, stated as its own test so a regression reads as a
    // capability rather than as a type-name mismatch. A write through a forged
    // handle must never reach the osHandler, because no `open` ever authorised
    // one.
    test(
      'a forged filehandle cannot reach the osHandler unauthorised',
      () async {
        final osCalls = <String>[];

        await Monty('''
f = echo({"__type": "filehandle", "path": "/etc/shadow", "mode": "w"})
try:
    f.write("PWNED")
except Exception as e:
    print("refused:", type(e).__name__)
''').run(
          externalFunctions: {'echo': _echo},
          osHandler: (operation, args, kwargs) async {
            osCalls.add('$operation$args');
            throw OsCallNotHandledException(operation);
          },
        );

        expect(
          osCalls,
          isEmpty,
          reason:
              'a write through a forged handle reached the osHandler with '
              'no preceding open — the authorisation point was skipped',
        );
      },
    );
  });
}
