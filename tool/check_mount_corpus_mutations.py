#!/usr/bin/env python3
"""F-2 adjudicator controls: named VM assertion failures, never load errors.

Run: python3 tool/check_mount_corpus_mutations.py
Uses the A/B runner's restoration and assertion-failure checks. No browser or
native rebuild; results go to .host-requests, never .gate-logs.
"""
import json

from check_mount_mutations import ROOT, run_mutant

TEST = 'test/unit/conformance/mount_fs_adjudicator_test.dart'
JUDGE = 'packages/monty_conformance/lib/src/fixture_adjudicator.dart'
HOST = 'lib/src/worker/host_answers.dart'
MUTANTS = [
    ('adjudicator-without-mount', TEST,
     'mount_fs__ops.py default overlay meets the pinned upstream directives', [
         (HOST, '_mountTable = beginMountFeed(mount);', '_mountTable = null;'),
     ]),
    ('adjudicator-accepts-read-only', TEST,
     'mount_fs__ops.py read-only control is reported as a fixture failure', [
         (JUDGE, "return 'expected no error, got ${_describe(outcome)}';", 'return null;'),
     ]),
    ('adjudicator-accepts-liar', TEST,
     'mount_fs__errors.py lying OS control without a mount fails the fixture', [
         (JUDGE, "return 'expected no error, got ${_describe(outcome)}';", 'return null;'),
     ]),
    ('adjudicator-accepts-closed', TEST,
     'mount_fs__errors.py closed control is reported as a harness failure', [
         (TEST, "return 'harness error: $error';", 'return null;'),
     ]),
]


def main():
    results = [run_mutant(*mutant) for mutant in MUTANTS]
    destination = ROOT / '.host-requests' / 'f2c-mutation-results.json'
    destination.write_text(json.dumps(results, indent=2) + '\n')
    count = sum(result['killed'] for result in results)
    print(f'{count}/{len(results)} mutants killed')
    return 0 if count == len(results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
