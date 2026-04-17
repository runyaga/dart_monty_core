/// Native (FFI) stub — no initialisation needed.
///
/// On Android, iOS, macOS, Linux, and Windows the Rust dylib is compiled and
/// linked at build time via `hook/build.dart` in dart_monty_core. There is
/// nothing to load at runtime.
abstract final class DartMontyFlutter {
  /// No-op on native platforms.
  ///
  /// The Rust dylib is compiled automatically when you run `flutter pub get`
  /// (requires Rust + cargo). Call this unconditionally in `main()` for
  /// cross-platform code — it resolves immediately on native.
  static Future<void> ensureInitialized() async {}
}
