/// No host tz database: the web worker uses its bundled copy alone.
///
/// Internal to the package; nothing here is exported.
library;

/// Always null: the bundled zone list decides.
bool? hostZoneKnown(String _) => null;
