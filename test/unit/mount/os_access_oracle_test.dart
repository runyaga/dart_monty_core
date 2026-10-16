@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';
import '_memory_fs_oracle.g.dart';

void main() {
  for (final encoded in memoryFsOracle) {
    final row = jsonDecode(encoded) as Map<String, Object?>;
    test('upstream memory fs ${row['name']}', () async {
      final fs = _seed();
      if (row['seedBytes'] case final List<Object?> bytes) {
        for (final file in fs.files) {
          if (file.path == '/bytes') {
            file.writeContent(Uint8List.fromList(bytes.cast<int>()));
          }
        }
      }
      await fs('Path.unlink', [MontyPath('/empty/f')], {});
      final op = row['op'] as String? ?? (throw StateError('missing op'));
      final args =
          row['args'] as List<Object?>? ?? (throw StateError('missing args'));
      final kwargs =
          row['kwargs'] as Map<String, Object?>? ??
          (throw StateError('missing kwargs'));
      Map<String, Object?> result;
      try {
        result = {
          'value': _encode(
            await fs(op, _args(op, args), {
              for (final e in kwargs.entries)
                e.key: MontyBool(e.value as bool? ?? false),
            }),
          ),
        };
      } on ExternalException catch (error) {
        result = {
          'error': [error.excType, error.message],
        };
      }
      expect(result, row['result']);
      expect([
        for (final f in fs.files)
          [f.path, _content(f.readContent()), f.deleted],
      ], row['state']);
    });
  }
}

OSAccess _seed() => OSAccess(
  files: [
    MemoryFile('/d/f', 'é'),
    MemoryFile('/d/sub/f', 'nested'),
    MemoryFile('/empty/f', ''),
    MemoryFile('/bytes', Uint8List.fromList([0, 255])),
    MemoryFile('//double/f', 'double'),
  ],
);

List<MontyValue> _args(String op, List<Object?> args) => [
  for (final (i, arg) in args.indexed)
    if (i == 0 || op == 'Path.rename')
      MontyPath(arg as String? ?? (throw StateError('missing argument')))
    else if (arg is List<Object?>)
      MontyBytes(arg.cast<int>())
    else
      MontyString(arg as String? ?? (throw StateError('missing argument'))),
];

Object? _encode(MontyValue value) => switch (value) {
  MontyBytes(:final value) => {'bytes': value},
  MontyPath(:final value) => {'path': value},
  MontyFileHandle(:final path, :final mode) => {
    'handle': [path, mode],
  },
  MontyNamedTuple(:final values) => {
    'stat': values.take(7).map(_encode).toList(),
  },
  MontyList(:final items) => items.map(_encode).toList(),
  _ => value.dartValue,
};
Object _content(Object value) => value is Uint8List ? {'bytes': value} : value;
