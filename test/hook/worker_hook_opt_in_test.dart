// Hook opt-out and manifest validation against an empty fixture root.
@Tags(['integration'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;

/// Runs the hook for this host with [packageRoot] and the `build_worker`
/// user-define set to [buildWorker] (absent when null), and returns its
/// validated output.
Future<BuildOutput> _runHook(
  Directory packageRoot, {
  Object? buildWorker,
  OS? targetOS,
  bool codeAssets = true,
}) async {
  final root = packageRoot.uri;
  final outputShared = root.resolve('output_shared/');
  Directory.fromUri(outputShared).createSync();
  final os = targetOS ?? OS.current;
  final extension = CodeAssetExtension(
    linkModePreference: LinkModePreference.dynamic,
    targetArchitecture: Architecture.current,
    targetOS: os,
    macOS: os == OS.macOS ? MacOSCodeConfig(targetVersion: 13) : null,
    android: os == OS.android ? AndroidCodeConfig(targetNdkApi: 24) : null,
    iOS: os == OS.iOS
        ? IOSCodeConfig(targetSdk: IOSSdk.iPhoneOS, targetVersion: 13)
        : null,
  );
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: root,
      packageName: 'dart_monty_core',
      outputFile: root.resolve('output.json'),
      outputDirectoryShared: outputShared,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: {'build_worker': ?buildWorker},
          basePath: root,
        ),
      ),
    )
    ..setupBuildInput()
    ..config.setupBuild(linkingEnabled: false);
  if (codeAssets) extension.setupBuildInput(builder);
  final input = builder.build();
  if (codeAssets) expect(await extension.validateBuildInput(input), isEmpty);
  final inputFile = File.fromUri(root.resolve('input.json'))
    ..writeAsStringSync(jsonEncode(input.json));
  await hook.main(['--config=${inputFile.path}']);
  final output = BuildOutput(
    jsonDecode(File.fromUri(input.outputFile).readAsStringSync())
        as Map<String, Object?>,
  );
  expect(await ProtocolBase.validateBuildOutput(input, output), isEmpty);
  if (codeAssets) {
    expect(await extension.validateBuildOutput(input, output), isEmpty);
  }

  return output;
}

Directory _emptyRoot() {
  final root = Directory.systemTemp.createTempSync('worker_hook_');
  addTearDown(() => root.deleteSync(recursive: true));

  return root;
}

void main() {
  for (final os in [OS.android, OS.iOS]) {
    test(
      '${os.name} target ignores invalid worker opt-in',
      () async {
        final output = await _runHook(
          _emptyRoot(),
          buildWorker: 'invalid',
          targetOS: os,
        );
        expect(output.assets.code, isEmpty);
        expect(output.dependencies, isEmpty);
      },
    );
  }

  test(
    'disabled code assets ignores invalid opt-in',
    () async {
      final output = await _runHook(
        _emptyRoot(),
        buildWorker: 'invalid',
        codeAssets: false,
      );
      expect(output.assets.code, isEmpty);
      expect(output.dependencies, isEmpty);
    },
  );

  for (final setting in [null, false]) {
    test(
      'build_worker $setting emits no native assets',
      () async {
        final root = _emptyRoot();
        final output = await _runHook(root, buildWorker: setting);
        expect(output.assets.code, isEmpty);
        expect(output.dependencies, isEmpty);
        expect(Directory('${root.path}/native').existsSync(), isFalse);
      },
    );
  }
  test(
    'true requires the worker manifest',
    () async {
      final root = _emptyRoot();
      await expectLater(
        _runHook(root, buildWorker: true),
        throwsStateError,
      );
    },
  );
}
