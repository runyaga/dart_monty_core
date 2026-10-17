/// Prepares isolated package copies for the native worker-cache platform probe.
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 5) {
    throw ArgumentError(
      'expected core source, consumer source, core copy, consumer copy, '
      'and manifest',
    );
  }
  final [
    coreSourcePath,
    consumerSourcePath,
    coreCopyPath,
    consumerCopyPath,
    manifestPath,
  ] = arguments;
  final coreSource = Directory(coreSourcePath);
  final consumerSource = Directory(consumerSourcePath);
  final coreCopy = Directory(coreCopyPath);
  final consumerCopy = Directory(consumerCopyPath);
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    throw ArgumentError.value(manifest.path, 'manifest', 'must exist');
  }

  await _copyCore(coreSource, coreCopy, manifest.readAsStringSync());
  await _copyConsumer(consumerSource, consumerCopy, coreCopy);
}

Future<void> _copyCore(
  Directory source,
  Directory destination,
  String manifest,
) async {
  final destinationUri = destination.uri;
  final pubspec = File.fromUri(destinationUri.resolve('pubspec.yaml'));
  await _copyFile(File.fromUri(source.uri.resolve('pubspec.yaml')), pubspec);
  await _sanitizeCorePubspec(pubspec);
  await _copyTree(
    Directory.fromUri(source.uri.resolve('hook/')),
    Directory.fromUri(destinationUri.resolve('hook/')),
  );
  await _copyTree(
    Directory.fromUri(source.uri.resolve('lib/')),
    Directory.fromUri(destinationUri.resolve('lib/')),
    skip: (relative) =>
        relative == 'src/bin' || relative.startsWith('src/bin/'),
  );
  await _replaceManifest(
    File.fromUri(
      destinationUri.resolve('lib/src/worker/worker_manifest_data.dart'),
    ),
    manifest,
  );
}

Future<void> _copyConsumer(
  Directory source,
  Directory destination,
  Directory coreCopy,
) async {
  await _copyTree(
    source,
    destination,
    skip: (relative) =>
        relative == '.dart_tool' || relative.startsWith('.dart_tool/'),
  );
  final pubspec = File.fromUri(destination.uri.resolve('pubspec.yaml'));
  final pubspecSource = pubspec.readAsStringSync();
  final path = coreCopy.path
      .replaceAll(Platform.pathSeparator, '/')
      .replaceAll("'", "''");
  final updated = pubspecSource.replaceFirstMapped(
    RegExp(r'^(\s*path:\s*).*$', multiLine: true),
    (match) => "${match[1]}'$path'",
  );
  if (updated == pubspecSource) {
    throw StateError('consumer pubspec has no dependency path to replace');
  }
  final mirror = Directory.fromUri(destination.uri.resolve('../dist/'));
  // The caller places dist next to the copies. Its URI is valid on Windows.
  final mirrorTemplate = '${mirror.uri}{archive}';
  pubspec.writeAsStringSync(
    '$updated\n'
    'hooks:\n'
    '  user_defines:\n'
    '    dart_monty_core:\n'
    '      worker_mirror: ${jsonEncode(mirrorTemplate)}\n',
    flush: true,
  );
}

Future<void> _copyTree(
  Directory source,
  Directory destination, {
  bool Function(String relative)? skip,
}) async {
  if (!source.existsSync()) {
    throw ArgumentError.value(source.path, 'source', 'must exist');
  }
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = entity.uri.path.substring(source.uri.path.length);
    final normalized = relative.endsWith('/')
        ? relative.substring(0, relative.length - 1)
        : relative;
    if (skip?.call(normalized) ?? false) continue;
    final target = destination.uri.resolve(relative);
    if (entity is Directory) {
      await Directory.fromUri(target).create(recursive: true);
    } else if (entity is File) {
      await _copyFile(entity, File.fromUri(target));
    }
  }
}

Future<void> _copyFile(File source, File destination) async {
  await destination.parent.create(recursive: true);
  await source.copy(destination.path);
}

Future<void> _sanitizeCorePubspec(File pubspec) async {
  final retained = <String>[];
  var skippingSection = false;
  for (final line in pubspec.readAsLinesSync()) {
    if (skippingSection && line.isNotEmpty && !line.startsWith(' ')) {
      skippingSection = false;
    }
    if (RegExp('^(workspace|dev_dependencies):').hasMatch(line)) {
      skippingSection = true;
      continue;
    }
    if (RegExp(r'^resolution:\s*workspace\s*$').hasMatch(line)) continue;
    if (!skippingSection) retained.add(line);
  }
  await pubspec.writeAsString('${retained.join('\n')}\n', flush: true);
}

Future<void> _replaceManifest(File manifestData, String manifest) async {
  final source = manifestData.readAsStringSync();
  final matcher = RegExp(r'const workerManifestJson =[\s\S]*?;');
  final replacement = 'const workerManifestJson = ${jsonEncode(manifest)};';
  final updated = source.replaceFirst(matcher, replacement);
  if (updated == source) {
    throw StateError(
      'could not replace workerManifestJson declaration: '
      'no declaration matched',
    );
  }
  await manifestData.writeAsString(updated, flush: true);
}
