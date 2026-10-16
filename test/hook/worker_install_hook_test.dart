@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_install.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;
import '../_accessors.dart';
import '../unit/worker/_worker_mirror.dart';

void main() {
  _coldHookTest();
  _warmHookTest();
  _corruptHookTest();
  _prebuiltLibraryHookTest();
}

void _coldHookTest() {
  test('installs a cold worker and declares the manifest dependency', () async {
    final fixture = await _fixture();
    final output = await fixture.run();

    expect(output.assets.code, isEmpty);
    await verifyWorkerFile(fixture.installed, fixture.mirror.artifact);
    expect(
      output.dependencies,
      contains(
        fixture.root.uri.resolve('lib/src/worker/worker_manifest_data.dart'),
      ),
    );
  });
}

void _warmHookTest() {
  test('uses the warm worker cache without fetching', () async {
    final fixture = await _fixture();
    final run = fixture.run;
    await run();
    final requests = fixture.server.requests;

    await run();

    expect(fixture.server.requests - requests, 0);
  });
}

void _corruptHookTest() {
  test('reports a corrupt archive without leaving a final directory', () async {
    final fixture = await _fixture(corruptArchive: true);

    await expectLater(
      fixture.run(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains(fixture.target),
            contains(fixture.server.url.toString()),
            contains(fixture.cache.path),
          ),
        ),
      ),
    );
    expect(
      Directory(
        workerCacheDir(fixture.cacheRoot, fixture.manifest.worker),
      ).existsSync(),
      isFalse,
    );
  });
}

void _prebuiltLibraryHookTest() {
  test('uses a prebuilt library without invoking cargo', () async {
    final fixture = await _fixture(withLibrary: true);
    final output = await fixture.run(buildWorker: true);

    final asset = onlyItem(output.assets.code);
    final library =
        fixture.manifest.library ??
        (throw StateError('fixture requested a prebuilt library'));
    final assetFile =
        asset.file ?? (throw StateError('prebuilt library output has no file'));
    expect(asset.id, 'package:dart_monty_core/src/worker/self_relaunch.dart');
    await verifyWorkerFile(
      File.fromUri(assetFile),
      library,
    );
    expect(
      Directory('${fixture.root.path}/native/worker').existsSync(),
      isFalse,
    );
  });
}

final class _Fixture {
  const _Fixture(
    this.root,
    this.cache,
    this.mirror,
    this.server,
    this.target,
    this.manifest,
  );

  final Directory root;
  final Directory cache;
  final WorkerMirror mirror;
  final WorkerHttpMirror server;
  final String target;
  final WorkerTarget manifest;

  String get cacheRoot => workerCacheRoot(environment: {'HOME': cache.path});

  File get installed => File(workerCacheFile(cacheRoot, manifest.worker));

  Future<BuildOutput> run({bool buildWorker = false}) async {
    final outputShared = root.uri.resolve('output_shared/');
    Directory.fromUri(outputShared).createSync();
    final extension = _extension();
    final builder = BuildInputBuilder()
      ..setupShared(
        packageRoot: root.uri,
        packageName: 'dart_monty_core',
        outputFile: root.uri.resolve('output.json'),
        outputDirectoryShared: outputShared,
        userDefines: PackageUserDefines(
          workspacePubspec: PackageUserDefinesSource(
            defines: {
              'build_worker': buildWorker,
              'worker_mirror': server.url.toString(),
            },
            basePath: root.uri,
          ),
        ),
      )
      ..setupBuildInput()
      ..config.setupBuild(linkingEnabled: false);
    extension.setupBuildInput(builder);
    final input = builder.build();
    expect(await extension.validateBuildInput(input), isEmpty);
    final inputFile = File.fromUri(root.uri.resolve('input.json'))
      ..writeAsStringSync(jsonEncode(input.json));
    await hook.runBuild(
      ['--config=${inputFile.path}'],
      manifest: WorkerManifest(
        version: 'v1',
        targets: {target: manifest},
      ),
      environment: {'HOME': cache.path},
    );
    final output = BuildOutput(
      jsonDecode(File.fromUri(input.outputFile).readAsStringSync())
          as Map<String, Object?>,
    );
    expect(await ProtocolBase.validateBuildOutput(input, output), isEmpty);
    expect(await extension.validateBuildOutput(input, output), isEmpty);

    return output;
  }
}

Future<_Fixture> _fixture({
  bool corruptArchive = false,
  bool withLibrary = false,
}) async {
  final root = await Directory.systemTemp.createTemp('worker_install_hook_');
  final cache = await Directory.systemTemp.createTemp('worker_hook_home_');
  final mirror = await WorkerMirror.create();
  final server = await WorkerHttpMirror.start(mirror.archive);
  addTearDown(() async {
    await server.close();
    await mirror.directory.delete(recursive: true);
    await root.delete(recursive: true);
    await cache.delete(recursive: true);
  });
  File('${root.path}/lib/src/worker/worker_manifest_data.dart').createSync(
    recursive: true,
  );
  final target = hookWorkerHostKey(
    OS.current.toString(),
    Architecture.current.toString(),
  );

  return _Fixture(
    root,
    cache,
    mirror,
    server,
    target,
    _fixtureTarget(mirror.artifact, corruptArchive, withLibrary),
  );
}

WorkerTarget _fixtureTarget(
  WorkerArtifact artifact,
  bool corruptArchive,
  bool withLibrary,
) {
  final archive =
      artifact.archive ??
      (throw StateError('worker mirror must provide an archive'));
  final worker = corruptArchive
      ? WorkerArtifact(
          file: artifact.file,
          bytes: artifact.bytes,
          sha256: artifact.sha256,
          archive: WorkerArchive(
            name: archive.name,
            bytes: archive.bytes,
            sha256: 'a' * 64,
          ),
        )
      : artifact;
  final library = !withLibrary
      ? null
      : WorkerArtifact(
          file: 'library-${artifact.file}',
          bytes: artifact.bytes,
          sha256: artifact.sha256,
          archive: archive,
        );

  return WorkerTarget(worker: worker, library: library);
}

CodeAssetExtension _extension() => CodeAssetExtension(
  linkModePreference: LinkModePreference.dynamic,
  targetArchitecture: Architecture.current,
  targetOS: OS.current,
  macOS: OS.current == OS.macOS ? MacOSCodeConfig(targetVersion: 13) : null,
);
