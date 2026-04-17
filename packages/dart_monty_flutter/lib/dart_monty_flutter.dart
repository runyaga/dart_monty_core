/// Flutter integration for dart_monty_core.
///
/// On **web**, call `DartMontyFlutter.ensureInitialized` before using any
/// Monty APIs to load the JavaScript bridge that dispatches calls to the
/// Monty WASM runtime running inside a Web Worker.
///
/// On **native** platforms (Android, iOS, macOS, Linux, Windows), no
/// initialisation is needed — the Rust dylib is compiled and linked
/// automatically via the `hook/build.dart` native-assets hook when you run
/// `flutter pub get`.
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await DartMontyFlutter.ensureInitialized();
///   runApp(const MyApp());
/// }
/// ```
library;

export 'package:dart_monty_core/dart_monty_core.dart';
export 'src/dart_monty_flutter_web.dart'
    if (dart.library.ffi) 'src/dart_monty_flutter_native.dart';
