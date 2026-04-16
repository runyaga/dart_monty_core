import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final os = code.targetOS;
    final arch = code.targetArchitecture;

    final libName = switch (os) {
      OS.macOS => 'libdart_monty_native.dylib',
      OS.linux => 'libdart_monty_native.so',
      OS.windows => 'dart_monty_native.dll',
      _ => null,
    };

    // Graceful fallback for iOS/Android — no native assets for now.
    if (libName == null) return;

    // Include arch in the output path to avoid collisions when Flutter
    // invokes the hook for multiple architectures (e.g. macOS universal).
    final outFile = File.fromUri(
      input.outputDirectoryShared.resolve('$arch/$libName'),
    );
    outFile.parent.createSync(recursive: true);

    final nativeDir = input.packageRoot.resolve('native/');
    final cargoToml = File.fromUri(nativeDir.resolve('Cargo.toml'));

    if (cargoToml.existsSync()) {
      // Contributor path: always run cargo (handles incremental builds).
      final triple = _rustTriple(os, arch);
      final targetArgs = triple != null ? ['--target', triple] : <String>[];
      final result = await Process.run('cargo', [
        'build',
        '--release',
        ...targetArgs,
      ], workingDirectory: Directory.fromUri(nativeDir).path);
      if (result.exitCode != 0) {
        throw StateError(
          'cargo build failed.\n'
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
        );
      }

      for (final sub in _cargoPaths(os, arch, libName)) {
        final f = File.fromUri(nativeDir.resolve(sub));
        if (f.existsSync() && f.lengthSync() > 0) {
          f.copySync(outFile.path);
          _addAsset(output, input.packageName, outFile.uri);

          return;
        }
      }

      throw StateError(
        'cargo build succeeded but $libName not found in target directories.',
      );
    }

    throw StateError(
      'native/Cargo.toml not found — clone the full monorepo to build from source.',
    );
  });
}

void _addAsset(BuildOutputBuilder output, String packageName, Uri file) {
  output.assets.code.add(
    CodeAsset(
      package: packageName,
      name: 'dart_monty_core_ffi.dart',
      linkMode: DynamicLoadingBundled(),
      file: file,
    ),
  );
}

List<String> _cargoPaths(OS os, Architecture? arch, String libName) {
  final triple = _rustTriple(os, arch);

  return [
    if (triple != null) 'target/$triple/release/$libName',
    'target/release/$libName',
  ];
}

String? _rustTriple(OS os, Architecture? arch) {
  final a = arch?.toString() ?? 'arm64';

  return switch ((os, a)) {
    (OS.macOS, 'arm64') => 'aarch64-apple-darwin',
    (OS.macOS, 'x64') => 'x86_64-apple-darwin',
    (OS.linux, 'arm64') => 'aarch64-unknown-linux-gnu',
    (OS.linux, 'x64') => 'x86_64-unknown-linux-gnu',
    (OS.windows, 'arm64') => 'aarch64-pc-windows-msvc',
    (OS.windows, 'x64') => 'x86_64-pc-windows-msvc',
    _ => null,
  };
}
