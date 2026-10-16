// Observe the actual Worker constructor after a valid module compiles.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

@JS('fetch')
external JSFunction get _fetch;

@JS('fetch')
external set _fetch(JSFunction value);

@JS('Worker')
external JSFunction get _worker;

@JS('Worker')
external set _worker(JSFunction value);

@JS('Proxy')
extension type const _ConstructorProxy._(JSFunction _) implements JSFunction {
  external factory _ConstructorProxy(JSFunction target, JSObject handler);
}

/// Supplies a valid empty wasm module and records attempted Worker URLs.
/// Construction deliberately throws after recording: no fake protocol replies
/// can hide a factory URL error, and no asset server layout is required.
final class SpecChannelBrowser {
  SpecChannelBrowser({String? servedScript}) {
    _fetch = ((JSString url) {
      final path = url.toDart;
      fetched.add(path);
      final isModule = path.endsWith('.wasm');
      final headers = JSObject()
        ..['get'] = ((JSString name) => 'application/octet-stream'.toJS).toJS;
      final response = JSObject()
        ..['ok'] = (isModule || path == servedScript).toJS
        ..['status'] = 404.toJS
        ..['headers'] = headers
        ..['arrayBuffer'] = (() => Future.value(
          Uint8List.fromList([0, 97, 115, 109, 1, 0, 0, 0]).buffer.toJS,
        ).toJS).toJS;

      return Future.value(response).toJS;
    }).toJS;
    JSObject construct(JSFunction _, JSArray<JSString> arguments) {
      workers.add(arguments.toDart.firstOrNull?.toDart ?? '<missing URL>');
      throw StateError('fixture Worker construction observed');
    }

    final handler = JSObject()..['construct'] = construct.toJS;
    _worker = _ConstructorProxy(_originalWorker, handler);
  }

  final fetched = <String>[];
  final workers = <String>[];
  final JSFunction _originalFetch = _fetch;
  final JSFunction _originalWorker = _worker;

  /// Restores the browser globals, including after an assertion fails.
  void restore() {
    _fetch = _originalFetch;
    _worker = _originalWorker;
  }
}
