@Tags(['unit'])
library;

import 'dart:typed_data';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

// Expected values: memory-fs contract, P09 and D-099 (not the old VFS).
void main() {
  test(
    'PurePosixPath preserves dotdot and double root',
    () {
      final file = MemoryFile('//d//./a/../b', 'x');
      expect(file.path, '//d/a/../b');
      expect(file.name, 'b');
      file.path = '/new';
      expect(file.name, 'b');
    },
  );
  test('default and settable permissions', () {
    final file = MemoryFile('/a', 'x');
    expect(file.permissions, 420);
    file.permissions = 384;
    expect(file.permissions, 384);
  });
  test('text and bytes stay distinct', () {
    final bytes = Uint8List.fromList([255]);
    final file = MemoryFile('/a', bytes);
    final sameBytes = same(bytes);
    expect(file.readContent(), sameBytes);
    file.writeContent('text');
    expect(file.content, 'text');
    file.content = bytes;
    expect(file.content, sameBytes);
  });
  test('D-092 validates every content boundary', () {
    expect(() => MemoryFile('/a', [1]), throwsArgumentError);
    final file = MemoryFile('/a', 'original');
    expect(() => file.content = 1, throwsArgumentError);
    expect(() => file.writeContent(false), throwsArgumentError);
    expect(file.content, 'original');
  });
  test('delete and repr follow upstream', () {
    final file = MemoryFile('/a', 'secret');
    final describe = file.toString;
    expect(file.deleted, false);
    expect(
      // Re-read the representation to check the changed content type.
      describe(),
      "MemoryFile(path=/a, content='...', permissions=420)",
    );
    file.delete();
    expect(file.deleted, true);
    file.content = Uint8List(0);
    expect(
      // Re-read the representation to check the changed content type.
      describe(),
      "MemoryFile(path=/a, content=b'...', permissions=420)",
    );
  });
}
