# Dependency check: shared contract

Each repository keeps its own `tool/check_dependencies.py`, `tool/test_check_dependencies.py` and `tool/dependency_allowlist.txt`. The three implementations follow this contract. Only the policy block (section 1) differs between repositories.

## 1. Policy (per repository)

| repository | FORBIDDEN (exact names) | FORBIDDEN_PREFIXES | PREFIX_EXEMPT |
|---|---|---|---|
| dart_monty_core | `dart_monty`, `dart_monty_extras` | none | none |
| dart_monty | `dart_monty_extras` | none | none |
| dart_monty_extras | none | `dart_monty` | `dart_monty_core`, `dart_monty` |

The policy is three module-level constants at the top of the script: `FORBIDDEN = frozenset({...})`, `FORBIDDEN_PREFIXES = (...)` and `PREFIX_EXEMPT = frozenset({...})`.

## 2. Rules

1. **direction**: a resolved package is a violation when its name is in FORBIDDEN, or when it starts with a FORBIDDEN_PREFIXES entry and is not in PREFIX_EXEMPT. This holds even when the name is in the allowlist.
2. **allowlist**: a resolved package that is absent from the allowlist is a violation.
3. The two rules are checked independently, so a package that breaks both produces two findings.
4. An allowlist entry that no package resolves is allowed. The allowlist is a set of approved names, not an inventory.

## 3. Lockfile parsing (standard library only, line by line)

- Strip a trailing comment (` #` and everything after it, and a line whose first non-space character is `#`) and trailing whitespace from every line before parsing. Then skip blank lines.
- The package block starts at a line that is exactly `packages:` at column 0. Any other spelling, an indented `packages:` among them, does not start the block.
- Inside the block, a line indented by exactly 2 spaces is a package key. It must match `^  ([a-z0-9_]+):$` after stripping. Anything else at 2-space indentation is an `input` error.
- Lines indented by 4 or more spaces belong to the current package and are ignored.
- The block ends at the next line at column 0.
- Input errors: a missing or unreadable file, a file that is not valid UTF-8, no `packages:` block, more than one `packages:` block, an empty block, or the same package key twice. Each is reported as a finding of rule `input` and exits 1.

## 4. Allowlist format

- UTF-8, one package name per line. Comments as in section 3 (whole-line and trailing). Blank lines are ignored.
- Each entry must match `^[a-z0-9_]+$`. A malformed entry or a duplicate entry is an `input` finding.
- The committed file keeps its entries sorted, and a test asserts this.
- The seed is the current one. Do not add or remove names.

## 5. Command line

```
python3 tool/check_dependencies.py [--root DIR] [--lockfile PATH] [--allowlist PATH]
```

- `--root` defaults to the repository root, which is the parent of the script's directory.
- `--lockfile` defaults to `pubspec.lock` and `--allowlist` to `tool/dependency_allowlist.txt`. A relative path resolves against `--root`.
- Exit 0: everything passes. Exit 1: one or more findings. Exit 2: usage error (argparse).

## 6. Output

- On success: exactly one line on stdout, `PASS: <n> resolved packages allowed`.
- On failure: nothing on stdout. One line per finding on stderr, in the form `FAIL <rule> <package-or-path>: <reason>`, where `<rule>` is one of `direction`, `allowlist` or `input`. No header, summary or footer lines.
- No traceback for any input error.

## 7. Tests (`tool/test_check_dependencies.py`, unittest, temporary files)

Every repository has all of the following. Each one runs the script as a subprocess, checks the exit code, and checks the exact stdout and stderr.

1. A clean lock covering every dependency kind (`direct main`, `direct dev`, `transitive`, `direct overridden`) passes.
2. A forbidden package fails with `direction`. Repeat with the forbidden name in the allowlist: it still fails with `direction` only.
3. An unlisted package fails with `allowlist`.
4. A package that is both forbidden and unlisted gives two findings.
5. An allowlist entry that resolves to nothing passes.
6. A column-0 comment inside the package block does not end the scan: a forbidden package after it still fails.
7. A package key with a trailing comment (`  name: # c`) or trailing spaces is still read.
8. An indented `packages:` under another key is not a package block, which gives an `input` failure.
9. A second top-level `packages:` block is an `input` failure.
10. A duplicate package key in the lock is an `input` failure, and so is a duplicate entry in the allowlist.
11. A malformed allowlist entry is an `input` failure. A trailing `#` comment on an entry is accepted.
12. Missing lock, empty package block, and non-UTF-8 lock each give one `input` line and exit 1, with no traceback.
13. A relative `--lockfile` resolves against `--root`.
14. The committed allowlist is sorted and free of duplicates.
15. For dart_monty_extras only: `dart_monty_foo` fails with `direction`, and `dart_monty` and `dart_monty_core` pass.
16. The checker passes against the repository's real `pubspec.lock` after `dart pub get`.
