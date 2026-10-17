/// Deliberately corrupts a cached worker for the native platform probe.
library;

import 'dart:io';

import 'package:collection/collection.dart';

Future<void> main(List<String> arguments) async {
  final path = arguments.singleOrNull;
  if (path == null) {
    throw ArgumentError('expected cached worker path');
  }
  final file = File(path);
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) {
    throw StateError('cached worker is empty: ${file.path}');
  }
  final middle = bytes.length ~/ 2;
  bytes[middle] ^= 0xff;
  await file.writeAsBytes(bytes, flush: true);
}
