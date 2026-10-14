// hook/build.dart run against a package root that holds native/worker/ and
// the shared toolchain file but no native/Cargo.toml: the tree the old
// engine's removal leaves. The opted-in worker library must still build.
//
// Builds native/worker's cdylib (release, --lib) through the hook, so it is
// tagged `integration` and run on its own:
//   dart test test/hook -p vm --run-skipped --tags=integration
@Tags(['integration'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;

/// A package root with native/worker/ (a link to this checkout's, so cargo
/// reuses its target directory) and native/rust-toolchain.toml, and without
/// native/Cargo.toml.
Directory _workerOnlyRoot() {
  final tmp = Directory.systemTemp.createTempSync('worker_only_hook_');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final native = Directory('${tmp.path}/native')..createSync();
  Link(
    '${native.path}/worker',
  ).createSync(Directory('native/worker').absolute.path);
  File(
    'native/rust-toolchain.toml',
  ).copySync('${native.path}/rust-toolchain.toml');
  expect(File('${native.path}/Cargo.toml').existsSync(), isFalse);

  return tmp;
}

/// Runs the hook for this host with [packageRoot] and the `build_worker`
/// user-define set to [buildWorker] (absent when null), and returns its
/// validated output.
Future<BuildOutput> _runHook(Directory packageRoot, {bool? buildWorker}) async {
  final root = packageRoot.uri;
  final outputShared = root.resolve('output_shared/');
  Directory.fromUri(outputShared).createSync();
  final extension = CodeAssetExtension(
    linkModePreference: LinkModePreference.dynamic,
    targetArchitecture: Architecture.current,
    targetOS: OS.current,
    macOS: OS.current == OS.macOS ? MacOSCodeConfig(targetVersion: 13) : null,
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
  extension.setupBuildInput(builder);
  final input = builder.build();
  expect(await extension.validateBuildInput(input), isEmpty);
  final inputFile = File.fromUri(root.resolve('input.json'))
    ..writeAsStringSync(jsonEncode(input.json));
  await hook.main(['--config=${inputFile.path}']);
  final output = BuildOutput(
    jsonDecode(File.fromUri(input.outputFile).readAsStringSync())
        as Map<String, Object?>,
  );
  expect(await ProtocolBase.validateBuildOutput(input, output), isEmpty);
  expect(await extension.validateBuildOutput(input, output), isEmpty);

  return output;
}

void main() {
  test(
    'without native/Cargo.toml, the opted-in worker library still builds',
    () async {
      final root = _workerOnlyRoot();
      final output = await _runHook(root, buildWorker: true);

      final assets = output.assets.code.toList();
      expect(assets.map((a) => a.id), [
        'package:dart_monty_core/src/worker/self_relaunch.dart',
      ]);
      final library = File.fromUri(assets.single.file!);
      expect(library.lengthSync(), greaterThan(0));

      // The toolchain is the worker's own declared input, not one it relied
      // on the old crate's declarations for.
      final deps = output.dependencies.map((u) => u.toFilePath()).toSet();
      final native = '${root.path}/native';
      expect(deps, contains('$native/rust-toolchain.toml'));
      expect(deps, contains('$native/worker/Cargo.toml'));
      expect(deps, contains('$native/worker/Cargo.lock'));
      expect(
        deps.where((d) => d.startsWith('$native/worker/src/')),
        isNotEmpty,
      );
      expect(deps, isNot(contains('$native/Cargo.toml')));
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test(
    'without native/Cargo.toml or the opt-in, the hook fails as before',
    () async {
      final root = _workerOnlyRoot();
      await expectLater(
        _runHook(root),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('native/Cargo.toml not found'),
          ),
        ),
      );
    },
  );
}
