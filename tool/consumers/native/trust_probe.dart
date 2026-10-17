import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';

Future<void> main(List<String> arguments) async {
  final argument = arguments.singleOrNull;
  if (argument == '--hook-only') {
    final temp = await Directory.systemTemp.createTemp('worker-trust-');
    try {
      await _hookEnvironment(temp);
    } finally {
      await temp.delete(recursive: true);
    }

    return;
  }
  if (argument == null) {
    stderr.writeln('usage: trust_probe.dart <worker>');
    exitCode = 64;

    return;
  }
  final worker = File(argument);
  try {
    await _run(worker);
  } on Object catch (error, stackTrace) {
    _unavailable('internal-error', '$error $stackTrace');
    exitCode = 1;
  }
}

Future<void> _run(File worker) async {
  final temp = await Directory.systemTemp.createTemp('worker-trust-');
  try {
    final downloaded = File('${temp.path}/downloaded${_extension()}');
    await _download(worker, downloaded);
    _fact('download', 'bytes=${await downloaded.length()}');
    if (!Platform.isWindows) {
      final mode = await _process('chmod', ['755', downloaded.path]);
      _factResult('download-mode', mode);
    }
    await switch (Platform.operatingSystem) {
      'windows' => _windows(downloaded, temp),
      'macos' => _macos(downloaded, temp),
      _ => _linux(downloaded),
    };
    await _hookEnvironment(temp);
  } finally {
    await temp.delete(recursive: true);
  }
}

String _extension() => Platform.isWindows ? '.exe' : '';

Future<void> _download(File source, File destination) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) => unawaited(_serve(request, source)));
  try {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://${server.address.address}:${server.port}/worker'),
      );
      final response = await request.close();
      await response.pipe(destination.openWrite());
    } finally {
      client.close();
    }
  } finally {
    await server.close(force: true);
  }
}

Future<void> _serve(HttpRequest request, File source) async {
  request.response
    ..statusCode = HttpStatus.ok
    ..add(await source.readAsBytes());
  await request.response.close();
}

Future<void> _windows(File downloaded, Directory temp) async {
  final before = await _process('powershell', [
    '-NoProfile',
    '-Command',
    _listAdsCommand,
  ], environment: _environment({'WORKER': downloaded.path}));
  if (before.exitCode != 0) {
    _unavailable('windows-ads', _result(before));
  } else {
    _fact('windows-ads', 'zone=${_hasZone(before.text)} ${_result(before)}');
  }
  final zoned = File('${temp.path}/zoned.exe');
  await downloaded.copy(zoned.path);
  final add = await _process('powershell', [
    '-NoProfile',
    '-Command',
    _addZoneCommand,
  ], environment: _environment({'WORKER': zoned.path}));
  if (add.exitCode != 0) {
    _unavailable('windows-add-zone', _result(add));

    return;
  }
  _fact('windows-add-zone', _result(add));
  final zone = await _process('powershell', [
    '-NoProfile',
    '-Command',
    _readZoneCommand,
  ], environment: _environment({'WORKER': zoned.path}));
  if (zone.exitCode != 0) {
    _unavailable('windows-zone-content', _result(zone));

    return;
  }
  _fact('windows-zone-content', 'stream=${_flat(zone.text)}');
  await _workerRun('windows-zone-process', zoned);
  final started = await _process('powershell', [
    '-NoProfile',
    '-Command',
    _startProcessCommand,
  ], environment: _environment({'WORKER': zoned.path}));
  if (started.exitCode != 0) {
    _unavailable('windows-zone-start-process', _result(started));
  } else {
    _fact(
      'windows-zone-start-process',
      '${_result(started)} blocked=${_blocked(started.text)}',
    );
  }
  final unblock = await _process('powershell', [
    '-NoProfile',
    '-Command',
    r'Unblock-File -LiteralPath $env:WORKER',
  ], environment: _environment({'WORKER': zoned.path}));
  if (unblock.exitCode != 0) {
    _unavailable('windows-unblock', _result(unblock));

    return;
  }
  _fact('windows-unblock', _result(unblock));
  await _workerRun('windows-unblocked-process', zoned);
}

Future<void> _macos(File downloaded, Directory temp) async {
  final attributes = await _process('xattr', ['-l', downloaded.path]);
  if (attributes.exitCode != 0) {
    _unavailable('macos-download-xattr', _result(attributes));
  } else {
    _fact(
      'macos-download-xattr',
      'quarantine=${attributes.text.contains('com.apple.quarantine')} '
          '${_result(attributes)}',
    );
  }
  await _workerRun('macos-download-process', downloaded);
  final quarantined = File('${temp.path}/quarantined');
  await downloaded.copy(quarantined.path);
  final write = await _process('xattr', [
    '-w',
    'com.apple.quarantine',
    '0081;00000000;Probe;',
    quarantined.path,
  ]);
  if (write.exitCode != 0) {
    _unavailable('macos-add-quarantine', _result(write));

    return;
  }
  _fact('macos-add-quarantine', _result(write));
  await _workerRun('macos-quarantine-process', quarantined);
  final signature = await _process('codesign', ['-dv', downloaded.path]);
  _factResult('macos-codesign', signature);
  final assessment = await _process('spctl', [
    '--assess',
    '--type',
    'execute',
    '-vv',
    downloaded.path,
  ]);
  _factResult('macos-spctl', assessment);
}

Future<void> _linux(File downloaded) async {
  final available = await _process('sh', ['-c', 'command -v getfattr']);
  if (available.exitCode == 0) {
    final attributes = await _process('getfattr', ['-d', downloaded.path]);
    _factResult('linux-download-attributes', attributes);
  } else {
    _fact('linux-download-attributes', 'getfattr=unavailable');
  }
  await _workerRun('linux-download-process', downloaded);
}

Future<void> _workerRun(String name, File worker) async {
  final result = await _process(worker.path, const []);
  if (result.exitCode != 0) {
    _unavailable(name, _result(result));
  } else {
    _fact(name, '${_result(result)} blocked=${_blocked(result.text)}');
  }
}

Future<void> _hookEnvironment(Directory temp) async {
  final package = Directory('${temp.path}/hook_environment_probe')
    ..createSync();
  Directory('${package.path}/bin').createSync();
  Directory('${package.path}/hook').createSync();
  File('${package.path}/pubspec.yaml').writeAsStringSync(_hookPubspec);
  File('${package.path}/bin/main.dart').writeAsStringSync('void main() {}\n');
  File('${package.path}/hook/build.dart').writeAsStringSync(_hookSource);
  final get = await _process('dart', ['pub', 'get'], cwd: package.path);
  final build = get.exitCode == 0
      ? await _process('dart', [
          'build',
          'cli',
          '-o',
          'build/probe',
        ], cwd: package.path)
      : get;
  final environment = File('${package.path}/hook-environment.txt');
  if (build.exitCode != 0) {
    _unavailable('hook-env', _result(build));

    return;
  }
  final detail = environment.existsSync()
      ? environment.readAsStringSync()
      : 'environment-file-missing';
  _fact('hook-env', '${_result(build)} $detail');
}

Future<({int exitCode, String text})> _process(
  String executable,
  List<String> arguments, {
  String? cwd,
  Map<String, String>? environment,
}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: cwd,
      environment: environment,
      includeParentEnvironment: environment == null,
    );

    return (
      exitCode: result.exitCode,
      text: '${result.stdout}\n${result.stderr}',
    );
  } on ProcessException catch (error) {
    return (exitCode: -1, text: error.toString());
  }
}

String _result(({int exitCode, String text}) result) =>
    'exit=${result.exitCode} text=${_flat(result.text)}';

Map<String, String> _environment(Map<String, String> added) => {
  ...Platform.environment,
  ...added,
};

bool _hasZone(String text) => text.contains('Zone.Identifier');

bool _blocked(String text) {
  final lower = text.toLowerCase();

  return lower.contains('smartscreen') ||
      lower.contains('defender') ||
      lower.contains('blocked');
}

void _fact(String name, String detail) =>
    stdout.writeln('TRUST $name ${_flat(detail)}');

void _unavailable(String name, String reason) =>
    _fact(name, 'unavailable $reason');

void _factResult(String name, ({int exitCode, String text}) result) {
  if (result.exitCode != 0) {
    _unavailable(name, _result(result));
  } else {
    _fact(name, _result(result));
  }
}

String _flat(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

const _hookPubspec = '''
name: hook_environment_probe
publish_to: none
environment:
  sdk: ^3.10.0
dependencies:
  hooks: ^1.0.2
''';

const _listAdsCommand = r'''
Get-Item -LiteralPath $env:WORKER -Stream * |
Format-Table -HideTableHeaders Stream
''';

const _addZoneCommand =
    r'''$ErrorActionPreference = 'Stop'; Set-Content -LiteralPath $env:WORKER -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3"; if (-not $?) { exit 1 }''';

const _readZoneCommand =
    r'''$ErrorActionPreference = 'Stop'; Get-Content -LiteralPath $env:WORKER -Stream Zone.Identifier''';

const _startProcessCommand = r'''
$ErrorActionPreference = 'Stop';
$p = Start-Process -FilePath $env:WORKER -Wait -PassThru;
if ($null -eq $p) { throw 'Start-Process returned no process' }
Write-Output "exit=$($p.ExitCode)"
''';

const _hookSource = r'''
import 'dart:io';

import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    final keys = Platform.environment.keys.toList()..sort();
    final present = ['HOME', 'USERPROFILE', 'LOCALAPPDATA']
        .map((key) => '$key=${Platform.environment.containsKey(key)}');
    File.fromUri(input.packageRoot.resolve('hook-environment.txt'))
        .writeAsStringSync('keys=${keys.join(',')} ${present.join(' ')}');
  });
}
''';
