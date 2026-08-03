/// Default per-mount memory budget in bytes — 100 MB.
///
/// Matches upstream's `DEFAULT_MEMORY_USAGE_LIMIT`
/// (`monty-fs/src/mount_table.rs:18`).
const int defaultMemoryUsageLimit = 100000000;

/// Bookkeeping charge for each node the sandbox creates, on top of its content.
///
/// Mirrors upstream's `ENTRY_MEMORY_USAGE` (`monty-fs/src/overlay_state.rs:21`),
/// which describes it as covering "the map node, key allocation, and entry
/// metadata", with variable-size contents charged separately. Without it a
/// sandbox can exhaust host memory with a million empty files, each of which
/// costs zero content bytes and a real allocation.
const int entryMemoryUsage = 256;

/// Formats [bytes] the way upstream's limit messages do
/// (`monty-fs/src/error.rs:207-234`): plain bytes under 1 KB, then decimal —
/// not binary — units, dropping a trailing `.0`.
String formatBytesPretty(int bytes) {
  const kb = 1000;
  const mb = 1000000;
  const gb = 1000000000;
  const tb = 1000000000000;

  if (bytes < kb) return '$bytes bytes';

  final (double value, String unit) = switch (bytes) {
    < mb => (bytes / kb, 'KB'),
    < gb => (bytes / mb, 'MB'),
    < tb => (bytes / gb, 'GB'),
    _ => (bytes / tb, 'TB'),
  };

  // Drop the decimal place when it rounds to `.0`, as upstream does.
  final tenths = ((value * 10).round() % 10).abs();

  return tenths == 0
      ? '${value.toStringAsFixed(0)} $unit'
      : '${value.toStringAsFixed(1)} $unit';
}
