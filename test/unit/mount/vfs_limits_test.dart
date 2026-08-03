@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

Matcher raises(String excType, String message) => throwsA(
  isA<OsCallException>()
      .having((e) => e.pythonExceptionType, 'excType', excType)
      .having((e) => e.message, 'message', message),
);

OsCallHandler withLimits({int? write, int? memory}) => memoryMountedOsHandler(
  mounts: [
    MountDir(
      virtualPath: '/mnt',
      writeBytesLimit: write,
      memoryUsageLimit: memory,
    ),
  ],
  files: const [],
);

void main() {
  // Upstream keeps two limits because they bound different things
  // (`_monty.pyi:111-118`): write_bytes_limit is CUMULATIVE and monotonic,
  // memory_usage_limit is RETAINED and refundable.
  group('writeBytesLimit is cumulative, not per-write', () {
    test('a single oversize write still fails', () async {
      final h = withLimits(write: 10);

      await expectLater(
        () => h('Path.write_text', ['/mnt/big.txt', 'x' * 100], null),
        raises('OSError', 'disk write limit of 10 bytes exceeded'),
      );
    });

    // THE REGRESSION. Each write is well under the cap; the TOTAL is not.
    // Under the old per-write check this loop ran forever and exhausted host
    // memory, which is precisely what an attacker does.
    test('many small writes that together exceed it fail', () async {
      final h = withLimits(write: 100);

      // 10 files x 30 bytes = 300 > 100, but no single write exceeds 100.
      var wrote = 0;
      Object? failure;
      for (var i = 0; i < 10; i++) {
        try {
          await h('Path.write_text', ['/mnt/f$i.txt', 'x' * 30], null);
          wrote++;
        } on OsCallException catch (e) {
          failure = e.message;
          break;
        }
      }

      expect(failure, 'disk write limit of 100 bytes exceeded');
      // 3 x 30 = 90 fits, the 4th would reach 120.
      expect(wrote, 3);
    });

    test('appending accumulates against the cap', () async {
      final h = withLimits(write: 25);

      await h('Path.append_text', ['/mnt/log.txt', 'x' * 10], null);
      await h('Path.append_text', ['/mnt/log.txt', 'x' * 10], null);

      await expectLater(
        () => h('Path.append_text', ['/mnt/log.txt', 'x' * 10], null),
        raises('OSError', 'disk write limit of 25 bytes exceeded'),
      );
    });

    test('deleting does NOT buy write budget back — it is monotonic', () async {
      final h = withLimits(write: 100);

      await h('Path.write_text', ['/mnt/a.txt', 'x' * 60], null);
      await h('Path.unlink', ['/mnt/a.txt'], null);

      // The bytes were still written, so the second 60 must not fit.
      await expectLater(
        () => h('Path.write_text', ['/mnt/b.txt', 'x' * 60], null),
        raises('OSError', 'disk write limit of 100 bytes exceeded'),
      );
    });

    test('null means unlimited', () async {
      // Both limits left null on purpose — `withLimits` defaults them to null,
      // which is the unlimited case, unlike `MountDir` itself which defaults
      // memoryUsageLimit to 100 MB.
      final h = withLimits();

      for (var i = 0; i < 50; i++) {
        await h('Path.write_text', ['/mnt/f$i.txt', 'x' * 1000], null);
      }
      expect(await h('Path.read_text', ['/mnt/f49.txt'], null), 'x' * 1000);
    });
  });

  group('memoryUsageLimit bounds RETAINED bytes and is refundable', () {
    test('a large live tree is refused with MemoryError', () async {
      final h = withLimits(memory: 2000);

      await expectLater(() async {
        for (var i = 0; i < 50; i++) {
          await h('Path.write_text', ['/mnt/f$i.txt', 'x' * 100], null);
        }
      }, raises('MemoryError', 'mount memory usage limit of 2 KB exceeded'));
    });

    // The per-entry charge is why: 1000 empty files cost no content bytes and
    // a great deal of real memory. Upstream charges 256 each
    // (`overlay_state.rs:22`), and so do we.
    test('empty files are charged the per-entry cost', () async {
      final h = withLimits(memory: entryMemoryUsage * 3);

      // Zero content bytes each, so only the entry charge can stop this.
      await h('Path.write_text', ['/mnt/a.txt', ''], null);
      await h('Path.write_text', ['/mnt/b.txt', ''], null);
      await h('Path.write_text', ['/mnt/c.txt', ''], null);

      await expectLater(
        () => h('Path.write_text', ['/mnt/d.txt', ''], null),
        raises(
          'MemoryError',
          'mount memory usage limit of 768 bytes exceeded',
        ),
      );
    });

    test('deleting DOES give the budget back', () async {
      final h = withLimits(memory: entryMemoryUsage + 100);

      await h('Path.write_text', ['/mnt/a.txt', 'x' * 100], null);
      // Full. A second file of the same size cannot fit...
      await expectLater(
        () => h('Path.write_text', ['/mnt/b.txt', 'x' * 100], null),
        throwsA(isA<OsCallException>()),
      );
      // ...until the first is removed.
      await h('Path.unlink', ['/mnt/a.txt'], null);
      await h('Path.write_text', ['/mnt/b.txt', 'x' * 100], null);

      expect(await h('Path.read_text', ['/mnt/b.txt'], null), 'x' * 100);
    });

    test('overwriting in place is not double-counted', () async {
      final h = withLimits(memory: entryMemoryUsage + 100);

      // Rewriting the same path 20 times must not accumulate.
      for (var i = 0; i < 20; i++) {
        await h('Path.write_text', ['/mnt/a.txt', 'x' * 100], null);
      }
      expect(await h('Path.read_text', ['/mnt/a.txt'], null), 'x' * 100);
    });

    test('mkdir is charged, and rmdir refunds it', () async {
      final h = withLimits(memory: entryMemoryUsage * 2);

      await h('Path.mkdir', ['/mnt/one'], null);
      await h('Path.mkdir', ['/mnt/two'], null);
      await expectLater(
        () => h('Path.mkdir', ['/mnt/three'], null),
        raises(
          'MemoryError',
          'mount memory usage limit of 512 bytes exceeded',
        ),
      );

      await h('Path.rmdir', ['/mnt/two'], null);
      await h('Path.mkdir', ['/mnt/three'], null);
      expect(await h('Path.is_dir', ['/mnt/three'], null), true);
    });

    test('a refused write leaves the tree untouched', () async {
      final h = withLimits(memory: entryMemoryUsage + 10);

      await expectLater(
        () => h('Path.write_text', ['/mnt/big.txt', 'x' * 500], null),
        throwsA(isA<OsCallException>()),
      );
      // The node must not exist — we refused to charge it.
      expect(await h('Path.exists', ['/mnt/big.txt'], null), false);
    });

    test('the default is 100 MB and does not disturb normal work', () async {
      expect(defaultMemoryUsageLimit, 100000000);

      // A plain mount takes the default; ordinary writes are unaffected.
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: const [],
      );
      await h('Path.write_text', ['/mnt/a.txt', 'x' * 10000], null);
      expect(await h('Path.read_text', ['/mnt/a.txt'], null), 'x' * 10000);
    });
  });

  // Upstream's wording, so a consumer reading either project sees the same
  // strings (`monty-fs/src/error.rs:207-234`). Decimal units, not binary.
  group('formatBytesPretty matches upstream', () {
    test('under 1 KB is plain bytes', () {
      expect(formatBytesPretty(0), '0 bytes');
      expect(formatBytesPretty(512), '512 bytes');
      expect(formatBytesPretty(999), '999 bytes');
    });

    test('decimal units, with a trailing .0 dropped', () {
      expect(formatBytesPretty(1000), '1 KB');
      expect(formatBytesPretty(1500), '1.5 KB');
      expect(formatBytesPretty(1000000), '1 MB');
      expect(formatBytesPretty(100000000), '100 MB');
      expect(formatBytesPretty(1000000000), '1 GB');
      expect(formatBytesPretty(1000000000000), '1 TB');
    });
  });
}
