/// Browser refusal for the internal host-directory service.
// Constructors match the native API but must refuse before using any input.
// ignore_for_file: avoid_unused_constructor_parameters
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The browser's refusal for operations requiring a host directory.
abstract final class NativeMountsWeb {
  /// Refuses before inspecting any host input.
  static Never unsupported() => throw UnsupportedError(
    'MountDir needs a host directory; the browser has none',
  );
}

/// No discovery route exists in a browser.
String get nativeMountLookupRoute => NativeMountsWeb.unsupported();

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
    NativeMountsWeb.unsupported();
  }

  /// Allows tests to exercise otherwise unreachable instance refusals.
  @visibleForTesting
  const NativeMountRoot.unsupported();

  /// Unavailable on the web.
  String get hostPath => NativeMountsWeb.unsupported();

  /// Unavailable on the web.
  String get virtualPath => NativeMountsWeb.unsupported();

  /// Unavailable on the web.
  void close() => NativeMountsWeb.unsupported();
}

/// Browser counterpart of a per-feed mount table.
final class NativeMountTable {
  /// Always refuses host-directory mounts.
  factory NativeMountTable(List<NativeMountRoot> roots) {
    NativeMountsWeb.unsupported();
  }

  /// Allows tests to exercise otherwise unreachable instance refusals.
  @visibleForTesting
  const NativeMountTable.unsupported();

  /// Unavailable on the web.
  Uint8List? call(List<int> _) => NativeMountsWeb.unsupported();

  /// Unavailable on the web.
  void close() => NativeMountsWeb.unsupported();
}
