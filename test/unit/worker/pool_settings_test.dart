// api/MontyTypingError.md: the complete diagnostic-format vocabulary.
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

void main() {
  const formats = {
    'full': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_FULL,
    'concise': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_CONCISE,
    'azure': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_AZURE,
    'json': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON,
    'jsonlines': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON_LINES,
    'json-lines': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON_LINES,
    'rdjson': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_RDJSON,
    'pylint': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_PYLINT,
    'gitlab': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITLAB,
    'github': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITHUB,
  };
  for (final MapEntry(:key, :value) in formats.entries) {
    test(
      'checkout accepts $key in either ASCII case',
      () async {
        for (final name in [key, key.toUpperCase()]) {
          final channel = ScriptedChannel([configurePool, resetPool]);
          final pool = await poolWith([channel]);
          final session = await pool.checkout(typeCheckFormat: name);
          expect(onlyItem(channel.requests).configure.typeCheckFormat, value);
          await session.close();
        }
      },
    );
  }
}
