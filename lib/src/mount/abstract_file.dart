/// A host file in OSAccess's in-memory namespace.
///
/// Implementations may live outside this library. Content is a [String] or
/// `Uint8List`; callbacks can provide a different backing store.
abstract interface class AbstractFile {
  /// The current POSIX path, mutable when a directory is renamed.
  String get path;
  set path(String value);

  /// The basename at construction.
  String get name;

  /// Unix permission bits used by stat.
  int get permissions;

  /// Whether [delete] has been called.
  bool get deleted;

  /// Reads the current text or bytes.
  Object readContent();

  /// Replaces the text or bytes.
  void writeContent(Object content);

  /// Marks this file deleted.
  void delete();
}
