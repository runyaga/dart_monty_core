/// Where a session's printed text goes when the caller passes no print
/// callback: the process's own streams on native, the console on the web.
///
/// Each half provides
/// `FutureOr<void> defaultPrint(String stream, String text)`.
///
/// Internal to the package; nothing here is exported.
library;

export 'default_print_stub.dart'
    if (dart.library.io) 'default_print_io.dart'
    if (dart.library.js_interop) 'default_print_web.dart';
