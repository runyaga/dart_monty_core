import 'dart:io';

import 'package:dart_monty_core/src/worker/worker_install_error.dart';

/// Opens an archive as a stream of bytes.
typedef WorkerFetcher = Stream<List<int>> Function(Uri url);

/// Opens a file or permitted HTTP(S) archive.
Stream<List<int>> defaultWorkerFetcher(Uri url) async* {
  if (url.scheme == 'file') {
    yield* File.fromUri(url).openRead();

    return;
  }
  if (!_isAllowedRemoteUrl(url)) {
    throw WorkerInstallError(
      'URL $url uses an unsupported scheme or insecure host; use file:, '
      'https:, or loopback http:.',
    );
  }

  yield* _fetchRemoteArchive(url);
}

Stream<List<int>> _fetchRemoteArchive(Uri url) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    var current = url;
    for (var redirects = 0; ; redirects++) {
      if (!_isAllowedRemoteUrl(current)) {
        throw WorkerInstallError(
          'redirect URL $current is not permitted; use https: or loopback '
          'http:.',
        );
      }
      final request = await client.getUrl(current);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode == HttpStatus.ok) {
        yield* response;

        return;
      }
      if (!_redirectStatus(response.statusCode) || redirects == 5) {
        throw WorkerInstallError(
          'URL $current returned HTTP ${response.statusCode}; publish the '
          'archive or configure worker_mirror.',
        );
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) {
        throw WorkerInstallError(
          'URL $current redirected without Location; fix the mirror response.',
        );
      }
      current = current.resolve(location);
      await response.drain<void>();
    }
  } on WorkerInstallError {
    rethrow;
  } on Object catch (error) {
    throw WorkerInstallError(
      'URL $url could not be downloaded ($error); check the mirror and '
      'network connection.',
    );
  } finally {
    client.close(force: true);
  }
}

bool _isAllowedRemoteUrl(Uri url) =>
    url.scheme == 'https' || (url.scheme == 'http' && _isLoopback(url.host));

bool _isLoopback(String host) =>
    host == '127.0.0.1' || host == '::1' || host == 'localhost';

bool _redirectStatus(int status) =>
    status == HttpStatus.movedPermanently ||
    status == HttpStatus.found ||
    status == HttpStatus.seeOther ||
    status == HttpStatus.temporaryRedirect ||
    status == HttpStatus.permanentRedirect;
