#!/usr/bin/env python3
"""Kill the behavioral mutants behind the F-2 coverage regression tests.

Run from the repository root. Only named test assertion failures count;
source files are restored by run_mutant even if a test fails or times out.
"""
import json
import os
import subprocess
import sys

from check_mount_mutations import ROOT, run_mutant

PROTO = 'lib/src/worker/proto_session.dart'
RELAUNCH = 'lib/src/worker/self_relaunch.dart'
PROTO_TEST = 'test/unit/worker/proto_session_test.dart'
RELAUNCH_TEST = 'test/integration/worker/self_relaunch_availability_test.dart'
ARMING = 'self-relaunch requires arming and a resolvable worker'
MUTANTS = [
    ('omit-raw-step-cwd', PROTO_TEST,
     'raw step defaults cwd only until the first accepted feed', [
         (PROTO, '      request.feed.cwd = defaultCwd;',
          '      // mutant: omit the first raw feed cwd'),
     ]),
    ('relaunch-without-arming', RELAUNCH_TEST, ARMING, [
        (RELAUNCH, '  if (!_armed) return false;', ''),
    ]),
    ('relaunch-never-arms', RELAUNCH_TEST, ARMING, [
        (RELAUNCH, '  _armed = true;', '  _armed = false;'),
    ]),
    ('missing-worker-is-available', RELAUNCH_TEST, ARMING, [
        (RELAUNCH, '  } on ArgumentError {\n    return false;',
         '  } on ArgumentError {\n    return true;'),
    ]),
    ('hide-resolver-errors', RELAUNCH_TEST,
     'self-relaunch does not hide unrelated resolver failures', [
         (RELAUNCH, '  } on ArgumentError {', '  } on Object {'),
     ]),
]


def main():
    selected = [m for m in MUTANTS if len(sys.argv) == 1 or m[0] in sys.argv[1:]]
    if not selected:
        raise SystemExit('no matching mutants')
    for _, test, name, _ in selected:
        baseline = subprocess.run(
            ['dart', 'test', test, '-p', 'vm', '-N', name, '-r', 'expanded'],
            cwd=ROOT, env={**os.environ, 'DASH__SUPPRESS_ANALYTICS': 'true'},
            capture_output=True, text=True, timeout=60,
        )
        if baseline.returncode != 0:
            print(baseline.stdout, baseline.stderr, file=sys.stderr)
            raise SystemExit('baseline failed; no mutants counted')
    results = [run_mutant(*mutant) for mutant in selected]
    destination = ROOT / '.host-requests' / 'worker-coverage-mutations.json'
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps(results, indent=2) + '\n')
    killed = sum(result['killed'] for result in results)
    print(f'{killed}/{len(results)} mutants killed')
    return 0 if killed == len(results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
