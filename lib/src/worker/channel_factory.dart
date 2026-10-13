/// Which `MontyChannel` a new worker gets: the pool's only conditional
/// import. A process on native, a Web Worker in the browser.
///
/// Each half provides `SpawnHandle openChannel({String? workerLocation})`
/// and `int defaultMaxProcesses()`.
///
/// Internal to the package; nothing here is exported.
library;

export 'channel_factory_stub.dart'
    if (dart.library.io) 'channel_factory_io.dart'
    if (dart.library.js_interop) 'channel_factory_web.dart';
