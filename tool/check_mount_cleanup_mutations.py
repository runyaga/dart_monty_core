#!/usr/bin/env python3
"""Terminal resume cleanup and abandoned-table regression mutations.

Run from the repository root after rebuilding the native mount service:
  python3 tool/check_mount_cleanup_mutations.py
Each mutant must fail a named VM assertion, never just compilation/loading.
"""
import json
import os
import re
import subprocess
import sys

from check_mount_mutations import ROOT, run_mutant

TEST = 'test/integration/worker/mount_lifecycle_io_test.dart'
SESSION = 'lib/src/worker/monty_session.dart'
NATIVE = 'lib/src/mount/native_mounts.dart'
MUTANTS = [
    ('lookup-failure-keeps-table', TEST,
     'feed table releases capability on lookup failure', [
         (SESSION,
          "// the checkout. No step() follows to release this feed's resources.\n"
          '        _host.dispose();',
          '// mutant: leave the lookup feed alive'),
     ]),
    ('unresolved-futures-keeps-table', TEST,
     'feed table releases capability on unresolved futures', [
         (SESSION,
          '// No step() follows this terminal failure, so end the feed here.\n'
          '        _host.dispose();',
          '// mutant: leave the unresolved-futures feed alive'),
     ]),
    ('abandoned-table-has-no-finalizer', TEST,
     'abandoned suspended feeds release tables on isolate exit', [
         (NATIVE,
          '''  NativeMountTable._(this._serviceBindings, this._id) {
    _serviceBindings.finalizer.attach(
      this,
      Pointer.fromAddress(_id),
      detach: this,
    );
  }''',
          '  NativeMountTable._(this._serviceBindings, this._id);'),
     ]),
]


def main():
    selected = [m for m in MUTANTS if len(sys.argv) == 1 or m[0] in sys.argv[1:]]
    if not selected:
        raise SystemExit('no matching mutants')
    baseline = subprocess.run(
        ['dart', 'test', TEST, '-p', 'vm', '-n',
         '|'.join(re.escape(m[2]) for m in selected), '--reporter', 'expanded'],
        cwd=ROOT, env={**os.environ, 'DASH__SUPPRESS_ANALYTICS': 'true'},
        capture_output=True, text=True, timeout=60,
    )
    if baseline.returncode != 0:
        print(baseline.stdout, baseline.stderr, file=sys.stderr)
        raise SystemExit('baseline failed; rebuild the native service before counting kills')
    results = [run_mutant(*mutant) for mutant in selected]
    destination = ROOT / '.host-requests' / 'f2-cleanup-mutation-results.json'
    destination.write_text(json.dumps(results, indent=2) + '\n')
    count = sum(result['killed'] for result in results)
    print(f'{count}/{len(results)} mutants killed')
    return 0 if count == len(results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
