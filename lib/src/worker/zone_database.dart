/// The host's own tz database, where the worker reads one: the zoneinfo
/// directory a native worker's jiff prefers over its bundled copy.
///
/// Each half provides `bool? hostZoneKnown(String name)`: null when there is
/// no such directory (the web, or a host without one), so the bundled list
/// decides; otherwise whether the directory resolves the name.
///
/// Internal to the package; nothing here is exported.
library;

export 'zone_database_stub.dart' if (dart.library.io) 'zone_database_io.dart';
