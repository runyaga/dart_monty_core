/// Internal host-directory service; unavailable in browsers.
library;

export 'native_mounts_web.dart' if (dart.library.ffi) 'native_mounts.dart';
