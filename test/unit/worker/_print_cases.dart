// Print sinks against upstream's outcomes: each case of _print_oracle.g.dart
// (pydantic-monty 1.1.0) run on a real pool with the same sink, a
// CollectStreams, a CollectString or a callback that throws, built from the
// case's description (tool/generate_print_oracle.py says what each means).
// Shared by the VM harness (test/integration/worker/pool_session_io_test.dart)
// and the Chrome one (pool_session_web_test.dart), so vm, dart2js and
// dart2wasm run the same cases.
import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/python_rules.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_print_oracle.g.dart';

/// Starts a pool with [options].
typedef StartPrintPool = Future<Monty> Function(PoolOptions options);

/// A throw of the host's own, which upstream sends as `Exception` with its
/// text: the oracle's `HostError`.
final class _HostTrouble implements Exception {
  const _HostTrouble(this.text);

  final String text;

  @override
  String toString() => text;
}

/// The sink [spec] describes: a collector, or a callback that throws. A
/// `monty` throw is the [MontyRuntimeError] of an earlier
/// `raise KeyError('k')` on another session of [pool].
Future<Object> _sink(List<Object?> spec, Monty pool) async {
  switch (spec) {
    case ['streams', final max]:
      return max == 'default'
          ? CollectStreams()
          : CollectStreams(maxBytes: max as int?);
    case ['string', final max]:
      return max == 'default'
          ? CollectString()
          : CollectString(maxBytes: max as int?);
    case ['raise', final List<Object?> exc]:
      final thrown = switch (exc) {
        ['typed', final String type, final String? message] =>
          ExternalException(type, message),
        ['plain', final String text] => _HostTrouble(text),
        ['json', final String msg, final String doc, final int pos] =>
          _jsonDecodeError(msg, doc, pos),
        ['monty'] => await _earlierError(pool),
        _ => throw StateError('unknown throw $exc'),
      };

      return (String stream, String text) => throw thrown;
  }
  throw StateError('unknown sink $spec');
}

/// `json.JSONDecodeError(msg, doc, pos)` as a host throws it: CPython's
/// message, line and column for [pos] in [doc], which is ASCII here.
ExternalException _jsonDecodeError(String msg, String doc, int pos) {
  final before = doc.substring(0, pos.clamp(0, doc.length));
  final lineno = '\n'.allMatches(before).length + 1;
  final colno = pos - before.lastIndexOf('\n');

  return ExternalException(
    'json.JSONDecodeError',
    '$msg: line $lineno column $colno (char $pos)',
    {
      'msg': MontyString(msg),
      'doc': MontyString(doc),
      'pos': MontyInt(pos),
      'lineno': MontyInt(lineno),
      'colno': MontyInt(colno),
    },
  );
}

/// The oracle's view of [e]'s inner exception: a JSON decode error with its
/// attributes, or the type's name.
String _innerText(MontyError e) {
  final inner = e.exception;
  if (inner.excType != 'json.JSONDecodeError') return inner.excType;
  final attributes = inner.attributes;
  final shown = [
    for (final name in const ['msg', 'doc', 'pos', 'lineno', 'colno'])
      '$name=${switch (attributes[name]) {
        MontyString(:final value) => pythonRepr(value),
        MontyInt(:final value) => '$value',
        final other => '$other',
      }}',
  ].join(', ');

  return 'json.JSONDecodeError($shown)';
}

Future<MontyError> _earlierError(Monty pool) async {
  final other = await pool.checkout();
  try {
    await other.feedRun('raise KeyError("k")', printCallback: _ignore);
  } on MontyRuntimeError catch (e) {
    return e;
  } finally {
    await other.close();
  }
  throw StateError('the earlier run did not raise');
}

void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// The oracle's text for [value]: the cases return ints and None only.
String _repr(MontyValue value) => switch (value) {
  MontyNone() => 'None',
  MontyInt(value: final n) => '$n',
  _ => throw StateError('unexpected value $value'),
};

String _describe(MontySnapshot snapshot) => switch (snapshot) {
  MontyComplete(:final output) => 'value: ${_repr(output)}',
  NameLookupSnapshot(:final variableName) => 'lookup $variableName',
  _ => throw StateError('unexpected snapshot $snapshot'),
};

String _errorText(Object e) => switch (e) {
  MontyRuntimeError() => 'MontyRuntimeError: ${e.display('type-msg')}',
  MontySyntaxError() => 'MontySyntaxError: ${e.display('type-msg')}',
  _ => '${e.runtimeType}: $e',
};

/// The oracle's view of [sink]: a collector's repr, or its size when that
/// is longer than the oracle shows (`SHOWN`); nothing for a callback.
String _collectorText(Object sink) {
  const shown = 400;
  final text = '$sink';
  switch (sink) {
    case CollectStreams(:final output):
      if (text.length <= shown) return text;
      final chars = output.fold(0, (n, e) => n + _pyLength(e.$2));

      return 'CollectStreams: ${output.length} entries, $chars chars';
    case CollectString(:final output):
      return text.length <= shown
          ? text
          : 'CollectString: ${_pyLength(output)} chars';
  }

  return '';
}

/// [s]'s length in code points, as Python's `len` counts.
int _pyLength(String s) => s.runes.length;

/// Every print-sink case, each its own test labelled with [label].
void printOracleTests(String label, StartPrintPool start) {
  test('the print oracle is complete ($label)', () {
    expect(printOracle.length, greaterThanOrEqualTo(38));
  });

  for (final MapEntry(key: id, value: (:sink, :steps)) in printOracle.entries) {
    test(
      'print sink $id matches upstream, step by step ($label)',
      () async {
        final pool = await start(const PoolOptions(maxProcesses: 2));
        try {
          final made = await _sink(sink, pool);
          // A collector serves as its `call`.
          final ProtoPrintCallback callback = switch (made) {
            final CollectStreams c => c.call,
            final CollectString c => c.call,
            final ProtoPrintCallback f => f,
            _ => throw StateError('not a sink: $made'),
          };
          final session = await pool.checkoutWith(
            const SessionConfig(printFlushInterval: Duration.zero),
          );
          MontySnapshot? snapshot;
          final actual = <String>[];
          try {
            for (final (:step, outcome: _) in steps) {
              String text;
              try {
                text = switch (step) {
                  ['run', final String code] =>
                    'value: ${_repr(
                      await session.feedRun(code, printCallback: callback),
                    )}',
                  ['bare', final String code] =>
                    'value: ${_repr(await session.feedRun(code))}',
                  ['start', final String code] => _describe(
                    snapshot = await session.feedStart(
                      code,
                      printCallback: callback,
                    ),
                  ),
                  ['resume', final int n] => switch (snapshot) {
                    final NameLookupSnapshot lookup => _describe(
                      snapshot = await lookup.resume(value: MontyInt(n)),
                    ),
                    _ => throw StateError('no lookup to resume: $snapshot'),
                  },
                  _ => throw StateError('unknown step $step'),
                };
              } on MontyError catch (e) {
                text = _errorText(e);
                if (sink case ['raise', ['json', ...]]) {
                  text += ' / ${_innerText(e)}';
                }
              }
              final shown = _collectorText(made);
              actual.add(shown.isEmpty ? text : '$text | $shown');
            }
          } finally {
            await session.close();
          }
          expect(actual, [for (final (step: _, :outcome) in steps) outcome]);
        } finally {
          await pool.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  }
}
