// Shared test body for ffi_open_test.dart and wasm_open_test.dart.
//
// Exercises Python's `open()` / file I/O end-to-end against
// memoryMountedOsHandler: the interpreter issues an `Open` OS-call (serviced
// by the handler, which returns a MontyFileHandle), then drives buffered
// reads/writes/appends through `Path.read_text`/`write_text`/`append_text`.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runOpenTests() {
  group('open() / file I/O', () {
    test('text read returns full file content', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        vfs: {'/m/a.txt': 'hello world\n'},
      );

      final r = await Monty(
        'f = open("/m/a.txt")\n'
        'data = f.read()\n'
        'f.close()\n'
        'data',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(r.value.dartValue, 'hello world\n');
    });

    test('TextIOWrapper type and mode are reported', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        vfs: {'/m/a.txt': 'x'},
      );

      final r = await Monty(
        'f = open("/m/a.txt")\n'
        'out = (str(type(f)), f.mode, f.readable(), f.writable())\n'
        'f.close()\n'
        'out',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(r.value.dartValue, [
        "<class '_io.TextIOWrapper'>",
        'r',
        true,
        false,
      ]);
    });

    test('write truncates then appends; returns char counts', () async {
      final vfs = <String, String>{};
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        vfs: vfs,
      );

      final r = await Monty(
        'f = open("/m/out.txt", "w")\n'
        'n1 = f.write("alpha")\n'
        'n2 = f.write("beta")\n'
        'f.close()\n'
        '(n1, n2)',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(r.value.dartValue, [5, 4]);
      expect(vfs['/m/out.txt'], 'alphabeta');
    });

    test('append mode preserves existing content', () async {
      final vfs = <String, String>{'/m/log.txt': 'seed-'};
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        vfs: vfs,
      );

      final r = await Monty(
        'f = open("/m/log.txt", "a")\n'
        'f.write("X")\n'
        'f.close()\n'
        'open("/m/log.txt").read()',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(r.value.dartValue, 'seed-X');
      expect(vfs['/m/log.txt'], 'seed-X');
    });

    test('with open(...) closes the file at block exit', () async {
      final vfs = <String, String>{};
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        vfs: vfs,
      );

      final r = await Monty(
        'with open("/m/w.txt", "w") as f:\n'
        '    n = f.write("hello")\n'
        '    inside = f.closed\n'
        'out = (n, inside, f.closed)\n'
        'out',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(r.value.dartValue, [5, false, true]);
      expect(vfs['/m/w.txt'], 'hello');
    });

    test(
      'opening a missing file raises a catchable FileNotFoundError',
      () async {
        final handler = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/m')],
          vfs: const {},
        );

        final r = await Monty(
          'try:\n'
          '    open("/m/nope.txt")\n'
          "    out = 'no-error'\n"
          'except FileNotFoundError as e:\n'
          "    out = ('caught', str(e))\n"
          'out',
        ).run(osHandler: handler);

        expect(r.error, isNull);
        final tuple = r.value.dartValue! as List<Object?>;
        expect(tuple.first, 'caught');
        expect(tuple[1], contains('/m/nope.txt'));
      },
    );
  });
}
