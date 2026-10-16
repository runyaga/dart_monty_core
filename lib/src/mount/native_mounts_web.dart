/// Browser refusal for the internal host-directory service.
// Constructors match the native API but must refuse before using any input.
// ignore_for_file: avoid_unused_constructor_parameters
library;

import 'dart:typed_data';

Never _unsupported() => throw UnsupportedError(
  'MountDir needs a host directory; the browser has none',
);

/// No discovery route exists in a browser.
String get nativeMountLookupRoute => _unsupported();

/// Browser counterpart of the native directory capability.
final class NativeMountRoot {
  /// Always refuses: browsers have no host directory capability.
  factory NativeMountRoot({
    required String hostPath,
    required String virtualPath,
    String mode = 'overlay',
    int? writeBytesLimit,
    int memoryUsageLimit = 100000000,
  }) {
    _unsupported();
  }

  /// Unavailable on the web.
  String get hostPath => _unsupported();

  /// Unavailable on the web.
  String get virtualPath => _unsupported();

  /// Unavailable on the web.
  void close() => _unsupported();
}

/// Browser counterpart of a per-feed mount table.
final class NativeMountTable {
  /// Always refuses host-directory mounts.
  factory NativeMountTable(List<NativeMountRoot> roots) {
    _unsupported();
  }

  /// Unavailable on the web.
  Uint8List? call(List<int> bytes) => _unsupported();

  /// Unavailable on the web.
  void close() => _unsupported();
}
