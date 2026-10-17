// E0 case s10 through a self-relaunched worker, in a `dart build cli` app.
//
// Usage: aot_worker <s10_external_call.json> | --diagnose
//
// Built and run by CI's `test-aot` job. The app finds no worker executable
// (package URIs do not resolve in AOT), so the locator must pick
// SelfRelaunch: this executable, run again with the worker flag, serving
// monty-proto from the bundled worker library. The feed's value, prints and
// external calls must equal the outcome recorded from the pinned upstream.
// The diagnostic mode verifies that the bundled worker library is available
// before this consumer reads its fixture or mounts an asset.
// Exits 0 on a match and 1 otherwise.
//
// Imports core's internals on purpose: the worker has no public API yet.
import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/mount/native_mount_service.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';

Future<void> main(List<String> args) async {
  runMontyWorkerIfChild(args);

  if (args case ['--diagnose']) await _diagnoseWorker();

  if (args.length != 1) {
    stderr.writeln('usage: aot_worker <s10_external_call.json> | --diagnose');
    exit(2);
  }

  await _runCase(
    args.singleOrNull ?? (throw StateError('expected one input file')),
  );
}

Future<void> _runCase(String casePath) async {
  _mountAssetSmoke();
  final testCase = _map(
    jsonDecode(File(casePath).readAsStringSync()),
  );
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
  final failures = await _runSession(
    channel,
    launch,
    testCase,
    expected,
    replies,
  );
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

Future<List<String>> _runSession(
  ProcessChannel channel,
  SelfRelaunch launch,
  Map<String, Object?> testCase,
  Map<String, Object?> expected,
  List<MontyValue> replies,
) async {
  final failures = <String>[];
  try {
    final session = await ProtoSession.open(channel);
    final calls = <Object?>[];
    final result = await session.feed(
      testCase['code']! as String,
      externalLookup: _externalLookup(calls, replies),
    );
    final got = _result(result.value, result.prints, calls);
    final want = _expectedResult(expected);
    stdout
      ..writeln('launch: $launch pid=${channel.pid} (parent pid=$pid)')
      ..writeln('got : ${jsonEncode(got)}')
      ..writeln('want: ${jsonEncode(want)}');
    if (jsonEncode(got) != jsonEncode(want)) failures.add('s10 diverges');

    await _checkReset(session, failures);
  } finally {
    await channel.close();
  }

  return failures;
}

Map<String, Object?> _result(
  MontyValue value,
  List<(String, String)> prints,
  List<Object?> calls,
) => {
  'value': _canon(value),
  'prints': [
    for (final (stream, text) in prints) [stream, text],
  ],
  'ext_calls': calls,
};

Map<String, Object?> _expectedResult(Map<String, Object?> expected) => {
  'value': expected['value'],
  'prints': expected['prints'],
  'ext_calls': expected['ext_calls'],
};

Future<void> _checkReset(ProtoSession session, List<String> failures) async {
  await session.reset();
  final result = await session.feed('1 + 1');
  stdout.writeln('after reset: 1 + 1 -> ${jsonEncode(_canon(result.value))}');
  if (result.value != const MontyInt(2)) failures.add('1 + 1 after reset');
}

Map<String, MontyHostFunction> _externalLookup(
  List<Object?> calls,
  List<MontyValue> replies,
) => {
  'fetch': MontyHostFunction('fetch', (positional, named) {
    calls.add({
      'name': 'fetch',
      'args': [for (final value in positional) _canon(value)],
      'kwargs': {
        for (final entry in named.entries) entry.key: _canon(entry.value),
      },
    });

    return replies.removeAt(0);
  }),
};

Future<void> _diagnoseWorker() async {
  try {
    final launch = await locateWorker();
    if (launch is SelfRelaunch) exit(0);
    throw StateError('worker locator chose $launch, not SelfRelaunch');
  } on Object catch (error) {
    stderr.writeln(error);
    exit(1);
  }
}

/// The parity suite's canonical form, for the value kinds s10 uses.
Map<String, Object?> _canon(MontyValue value) => switch (value) {
  MontyString(value: final text) => {'t': 'str', 'v': text},
  MontyInt(value: final integer) => {'t': 'int', 'v': '$integer'},
  _ => throw UnsupportedError('no canonical form here for $value'),
};

MontyValue _fromCanon(Object? json) => switch (_map(json)) {
  {'t': 'str', 'v': final String v} => MontyString(v),
  {'t': 'int', 'v': final String v} => MontyInt(int.parse(v)),
  final other => throw UnsupportedError('no value here for $other'),
};

Map<String, Object?> _map(Object? json) =>
    (json ?? (throw const FormatException('expected an object')))
        as Map<String, Object?>;

List<Object?> _list(Object? json) =>
    (json ?? (throw const FormatException('expected a list'))) as List<Object?>;

// F-0 is internal: exercise the capability that F-2's MountDir will own.
// Checking the selected route prevents an in-checkout package library from
// masking a missing code asset in this built consumer.
void _mountAssetSmoke() {
  final dir = Directory.systemTemp.createTempSync('aot-mount-');
  try {
    File('${dir.path}/hello').writeAsStringSync('asset');
    final root = NativeMountRoot(hostPath: dir.path, virtualPath: '/m');
    try {
      if (nativeMountLookupRoute != 'asset') {
        throw StateError('mount lookup did not use the bundled code asset');
      }
      final table = NativeMountTable([root]);
      try {
        final result = pb.ResumeCall.fromBuffer(
          table.call(
                pb.OsCall(callId: 19, readText: '/m/hello').writeToBuffer(),
              ) ??
              (throw StateError('bundled mount service did not handle read')),
        );
        if (result.callId != 19 ||
            !result.result.hasReturnValue() ||
            ArenaReader(result.values)[result.result.returnValue] !=
                const MontyString('asset')) {
          throw StateError('bundled mount service failed its read');
        }
      } finally {
        table.close();
      }
    } finally {
      root.close();
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
  stdout.writeln('mount route 1: asset OPEN / READ / CLOSE');
}
