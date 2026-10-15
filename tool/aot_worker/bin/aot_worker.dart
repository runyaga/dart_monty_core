// E0 case s10 through a self-relaunched worker, in a `dart build cli` app.
//
// Usage: aot_worker <s10_external_call.json>
//
// Built and run by CI's `test-aot` job. The app finds no worker executable
// (package URIs do not resolve in AOT), so the locator must pick
// SelfRelaunch: this executable, run again with the worker flag, serving
// monty-proto from the bundled worker library. The feed's value, prints and
// external calls must equal the outcome recorded from the pinned upstream.
// Exits 0 on a match and 1 otherwise.
//
// Imports core's internals on purpose: the worker has no public API yet.
import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';

Future<void> main(List<String> args) async {
  runMontyWorkerIfChild(args);

  if (args.length != 1) {
    stderr.writeln('usage: aot_worker <s10_external_call.json>');
    exit(2);
  }
  final testCase = _map(jsonDecode(File(args.single).readAsStringSync()));
  final expected = _map(testCase['expected']);
  final replies = [
    for (final reply in _list(_map(testCase['externals'])['fetch']))
      _fromCanon(_map(reply)['return']),
  ];

  final launch = await locateWorker();
  if (launch is! SelfRelaunch) {
    stderr.writeln('FAIL: the locator chose $launch, not SelfRelaunch');
    exit(1);
  }
  final channel = await ProcessChannel.spawn(launch);
  final failures = <String>[];
  try {
    final session = await ProtoSession.open(channel);
    final calls = <Object?>[];
    final result = await session.feed(
      testCase['code']! as String,
      externalLookup: {
        'fetch': (List<MontyValue> positional, Map<String, MontyValue> named) {
          calls.add({
            'name': 'fetch',
            'args': [for (final v in positional) _canon(v)],
            'kwargs': {for (final e in named.entries) e.key: _canon(e.value)},
          });

          return replies.removeAt(0);
        },
      },
    );
    final got = {
      'value': _canon(result.value),
      'prints': [
        for (final (stream, text) in result.prints) [stream, text],
      ],
      'ext_calls': calls,
    };
    final want = {
      'value': expected['value'],
      'prints': expected['prints'],
      'ext_calls': expected['ext_calls'],
    };
    stdout
      ..writeln('launch: $launch pid=${channel.pid} (parent pid=$pid)')
      ..writeln('got : ${jsonEncode(got)}')
      ..writeln('want: ${jsonEncode(want)}');
    if (jsonEncode(got) != jsonEncode(want)) failures.add('s10 diverges');

    // The same worker after a reset.
    await session.reset();
    final sum = await session.feed('1 + 1');
    stdout.writeln('after reset: 1 + 1 -> ${jsonEncode(_canon(sum.value))}');
    if (sum.value != const MontyInt(2)) failures.add('1 + 1 after reset');
  } finally {
    await channel.close();
  }
  final code = await channel.exitCode;
  stdout.writeln('worker exit: $code');
  if (code != 0) failures.add('worker exit code $code');
  if (ProcessChannel.live.isNotEmpty) failures.add('a worker is still live');

  stdout.writeln(
    failures.isEmpty
        ? '${testCase['case']}: MATCHES-UPSTREAM'
        : '${testCase['case']}: FAIL ${failures.join('; ')}',
  );
  exit(failures.isEmpty ? 0 : 1);
}

/// The parity suite's canonical form, for the value kinds s10 uses.
Map<String, Object?> _canon(MontyValue value) => switch (value) {
  MontyString(:final value) => {'t': 'str', 'v': value},
  MontyInt(:final value) => {'t': 'int', 'v': '$value'},
  _ => throw UnsupportedError('no canonical form here for $value'),
};

MontyValue _fromCanon(Object? json) => switch (_map(json)) {
  {'t': 'str', 'v': final String v} => MontyString(v),
  {'t': 'int', 'v': final String v} => MontyInt(int.parse(v)),
  final other => throw UnsupportedError('no value here for $other'),
};

Map<String, Object?> _map(Object? json) => json! as Map<String, Object?>;

List<Object?> _list(Object? json) => json! as List<Object?>;
