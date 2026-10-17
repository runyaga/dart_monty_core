#!/usr/bin/env bash
# =============================================================================
# This package's version must track the upstream monty it pins (G9).
# =============================================================================
# The package minor joins all three upstream digits:
#
#     pydantic/monty 1.1.0  ->  dart_monty_core 0.110.x
#     pydantic/monty 1.0.2  ->  dart_monty_core 0.102.x
#
# The patch counts core's own fixes on one pin, and a -dev.N suffix is allowed
# before release. Upstream's version is read from
# tool/upstream/upstream-pin.json; pubspec.yaml and native/worker/Cargo.toml
# must both carry the mapped 0.<minor>.x.
#
# It is not decorative. Snapshots are NOT portable across monty upgrades, so
# the version a consumer reads is how they know which snapshot format and which
# engine semantics they are getting. The 0.0.x line once moved its monty pin
# without touching pubspec.yaml and described itself as the wrong release for
# as long as it took a human to notice: a check, not a comment.
#
# A two-digit upstream component (1.10.0, 10.0.0) has no mapping: it would
# collide with or overflow the joined minor. The check refuses it, and the
# message says the mapping needs an owner decision.
#
# Usage:
#   bash tool/check_version_pin.sh              # check the tree
#   bash tool/check_version_pin.sh --self-test  # the mapping's controls only
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

python3 -I - "${1:-}" <<'PY'
import json, re, sys


def want_minor(upstream):
    """The package minor for an upstream version, or None if it has none."""
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", upstream)
    if not m or any(len(g) != 1 for g in m.groups()):
        return None
    return "".join(m.groups())


def refuse(upstream):
    sys.exit(
        f"FAIL: upstream version {upstream!r} is not three single digits.\n"
        "  G9 joins the three upstream digits into the package minor "
        "(1.1.0 -> 0.110.x), so a two-digit component has no mapping.\n"
        "  A two-digit upstream release needs an owner decision on the "
        "version mapping before this check can pass.")


# The controls: the two documented mappings pass, two-digit components fail.
CONTROLS = {"1.1.0": "110", "1.0.2": "102", "1.10.0": None, "10.0.0": None}
for up, want in CONTROLS.items():
    got = want_minor(up)
    if got != want:
        sys.exit(f"FAIL: control {up}: want {want!r}, got {got!r}")
if sys.argv[1] == "--self-test":
    for up, want in CONTROLS.items():
        verdict = f"0.{want}.x" if want else "refused"
        print(f"PASS: control {up} -> {verdict}")
    sys.exit(0)
if sys.argv[1]:
    sys.exit(f"usage: bash tool/check_version_pin.sh [--self-test] "
             f"(got {sys.argv[1]!r})")

upstream = json.load(open("tool/upstream/upstream-pin.json"))["version"]
minor = want_minor(upstream)
if minor is None:
    refuse(upstream)
ver_re = re.compile(r"0\.(\d+)\.(\d+)(-dev\.\d+)?")
pub = re.search(r"^version:\s*(\S+)", open("pubspec.yaml").read(), re.M).group(1)
cargo = re.search(r'^version\s*=\s*"([^"]+)"',
                  open("native/worker/Cargo.toml").read(), re.M).group(1)
rc = 0
for name, v in (("pubspec.yaml", pub), ("native/worker/Cargo.toml", cargo)):
    m = ver_re.fullmatch(v)
    if not m or m.group(1) != minor:
        print(f"FAIL: {name} version {v} does not track upstream {upstream} "
              f"(want 0.{minor}.<patch>[-dev.N])")
        rc = 1
    else:
        print(f"PASS: {name} {v} tracks upstream {upstream}")
sys.exit(rc)
PY
