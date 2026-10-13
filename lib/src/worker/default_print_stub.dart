/// The default print sink where there is neither `dart:io` nor a browser.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';

/// Always throws [UnsupportedError]: this platform has no worker channel,
/// so no session can print here.
FutureOr<void> defaultPrint(String stream, String text) =>
    throw UnsupportedError(
      'no default print sink on this platform ($stream, ${text.length} '
      'characters)',
    );
