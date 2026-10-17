// Explicit null and invalid build_worker settings at the real hook boundary.
@Tags(['integration'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;

/// Runs the hook for this host with [packageRoot] and the `build_worker`
/// user-define set to [buildWorker] (including explicit null), and returns its
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
  );
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: root,
      packageName: 'dart_monty_core',
      outputFile: root.resolve('output.json'),
      outputDirectoryShared: outputShared,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: {'build_worker': buildWorker},
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
  await hook.runBuild(
    ['--config=${inputFile.path}'],
    manifest: WorkerManifest(targets: {}),
  );
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
  for (final run in [1, 2]) {
    test('explicit null builds no worker library (run $run)', () async {
      final output = await _runHook(_emptyRoot());
      expect(output.assets.code, isEmpty);
      expect(output.dependencies, isEmpty);
    });
  }
  for (final run in [1, 2]) {
    for (final value in <Object>['yes', 1, 0]) {
      test(
        'rejects build_worker $value with its diagnostic (run $run)',
        () async {
          await expectLater(
            _runHook(_emptyRoot(), buildWorker: value),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'dart_monty_core: the user_define build_worker must be '
                    'true or false, '
                    'got ${value.runtimeType} $value.',
              ),
            ),
          );
        },
      );
    }
  }
}
