@Tags(['unit'])
library;

import 'dart:async';
import 'dart:typed_data';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/unsafe_callback_file.dart';
import 'package:test/test.dart';

void main() {
  _attributes();
  _renames();
  _failures();
}

void _attributes() {
  test('normalised construction and setters', () {
    final file = CallbackFile(
      'a//./../b',
      (_) => 'old',
      (_, _) => fail('unexpected write'),
    );
    expect(file.path, 'a/../b');
    expect(file.name, 'b');
    expect(file.permissions, 420);
    expect(
      CallbackFile('', (_) => '', (_, _) => fail('unexpected write')).path,
      '.',
    );
    file
      ..permissions = 384
      ..read = (_) => 'new';
    Object? written;
    file.write = (_, value) => written = value;
    expect(file.readContent(), 'new');
    file.writeContent('new write');
    expect(written, 'new write');
    expect(file.permissions, 384);
    expect(file.deleted, false);
    file.delete();
    expect(file.deleted, true);
    final representation = file.toString();
    expect(representation, startsWith('CallbackFile(path=a/../b, read='));
    expect(representation, endsWith('permissions=384)'));
  });
  test('no caching', () {
    var reads = 0;
    final writes = <Object>[];
    final file = CallbackFile(
      '/f',
      (_) => ++reads,
      (_, value) => writes.add(value),
    );
    // Reading again must invoke the callback rather than use cached content.
    // ignore: prefer-moving-to-variable
    expect(file.readContent(), 1);
    file.writeContent('not cached');
    // The write must not replace the next callback result with cached content.
    // ignore: prefer-moving-to-variable
    expect(file.readContent(), 2);
    expect(writes, ['not cached']);
  });
  test('writes raw content synchronously', () async {
    final pending = Completer<void>();
    final seen = <Object>[];
    // This verifies that a synchronous write does not await an async callback.
    // ignore: avoid-passing-async-when-sync-expected
    final file = CallbackFile('/f', (_) => 'independent', (_, value) async {
      seen.add(value);
      await pending.future;
    });
    final bytes = Uint8List.fromList([255]);
    file.writeContent(bytes);
    expect(seen, [same(bytes)]);
    expect(file.readContent(), 'independent');
    pending.complete();
    await pending.future;
  });
}

void _renames() {
  for (final directory in [false, true]) {
    test(
      'SPEC6(c) write after ${directory ? 'directory' : 'file'} rename',
      () async {
        final reads = <String>[];
        final writes = <(String, Object)>[];
        final file = CallbackFile('/d/f', (path) {
          reads.add(path);

          return 'value';
        }, (path, value) => writes.add((path, value)));
        final fs = OSAccess(files: [file]);
        await fs('Path.rename', [
          MontyPath(directory ? '/d' : '/d/f'),
          MontyPath(directory ? '/e' : '/d/g'),
        ], {});
        final path = directory ? '/e/f' : '/d/g';
        await fs('Path.read_text', [MontyPath(path)], {});
        await fs('Path.write_text', [
          MontyPath(path),
          const MontyString('written'),
        ], {});
        expect(reads, ['/d/f']);
        expect(writes, [('/d/f', 'written')]);
        expect(file.path, directory ? '/e/f' : '/d/f');
        expect(file.name, 'f');
      },
    );
  }
  test('SPEC6(c) cb-write-mset renamed host path cannot redirect writes', () {
    final paths = <String>[];
    final file =
        CallbackFile(
            '/d/./f',
            (_) => '',
            (path, _) => paths.add(path),
          )
          ..path = '/elsewhere'
          ..writeContent('x');
    expect(file.name, 'f');
    expect(paths, ['/d/f']);
  });
}

void _failures() {
  test('errors unchanged', () {
    final error = StateError('host');
    final file = CallbackFile('/f', (_) => throw error, (_, _) => throw error);
    final sameError = throwsA(same(error));
    expect(file.readContent, sameError);
    expect(() => file.writeContent('x'), sameError);
  });
  test('D-099 callback stat sees changed permissions', () async {
    final file = CallbackFile(
      '/f',
      (_) => 'x',
      (_, _) => fail('unexpected write'),
    );
    final fs = OSAccess(files: [file]);
    file.permissions = 384;
    final stat = await fs('Path.stat', [MontyPath('/f')], {});
    expect((stat as MontyNamedTuple).values.firstOrNull, const MontyInt(33152));
  });
}
