#!/usr/bin/env bash
# =============================================================================
# This package's version must track the upstream monty it pins (G9).
# =============================================================================
# The package minor joins the upstream major and minor, then a zero:
#
#     pydantic/monty 1.1.0  ->  dart_monty_core 0.110.0
#     pydantic/monty 1.1.1  ->  dart_monty_core 0.110.1
#     pydantic/monty 1.2.0  ->  dart_monty_core 0.120.0
#
# The release patch equals the upstream patch. A higher core patch is allowed
# for core's own fixes, and a -dev.N suffix is allowed before release. Upstream's version is read from
# tool/upstream/upstream-pin.json; pubspec.yaml and native/worker/Cargo.toml
# must both carry the mapped 0.<minor>.<patch>.
#
# It is not decorative. Snapshots are NOT portable across monty upgrades, so
# the version a consumer reads is how they know which snapshot format and which
# engine semantics they are getting. The 0.0.x line once moved its monty pin
# without touching pubspec.yaml and described itself as the wrong release for
# as long as it took a human to notice: a check, not a comment.
#
# A two-digit upstream major or minor component (1.10.0, 10.0.0) has no mapping:
# it would collide with the joined minor. The check refuses it, and the
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


def want_version(upstream):
    """The package minor and minimum patch for an upstream version."""
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", upstream)
    if not m or any(len(g) != 1 for g in m.groups()[:2]):
        return None
    major, minor, patch = m.groups()
    return major + minor + "0", int(patch)


def refuse(upstream):
    sys.exit(
        f"FAIL: upstream version {upstream!r} does not have single-digit major and minor components.\n"
        "  G9 joins the upstream major and minor into the package minor "
        "(1.1.0 -> 0.110.0), so a two-digit component has no mapping.\n"
        "  A two-digit upstream release needs an owner decision on the "
        "version mapping before this check can pass.")


# The controls: documented mappings pass and two-digit major/minor refuse.
CONTROLS = {
    "1.1.0": ("110", 0), "1.1.1": ("110", 1), "1.2.0": ("120", 0),
    "1.0.2": ("100", 2), "1.10.0": None, "10.0.0": None,
}
for up, want in CONTROLS.items():
    got = want_version(up)
    if got != want:
        sys.exit(f"FAIL: control {up}: want {want!r}, got {got!r}")
if sys.argv[1] == "--self-test":
    for up, want in CONTROLS.items():
        verdict = f"0.{want[0]}.{want[1]}" if want else "refused"
        print(f"PASS: control {up} -> {verdict}")
    sys.exit(0)
if sys.argv[1]:
    sys.exit(f"usage: bash tool/check_version_pin.sh [--self-test] "
             f"(got {sys.argv[1]!r})")

upstream = json.load(open("tool/upstream/upstream-pin.json"))["version"]
mapped = want_version(upstream)
if mapped is None:
    refuse(upstream)
minor, minimum_patch = mapped
ver_re = re.compile(r"0\.(\d+)\.(\d+)(-dev\.\d+)?")
pub = re.search(r"^version:\s*(\S+)", open("pubspec.yaml").read(), re.M).group(1)
cargo = re.search(r'^version\s*=\s*"([^"]+)"',
                  open("native/worker/Cargo.toml").read(), re.M).group(1)
rc = 0
for name, v in (("pubspec.yaml", pub), ("native/worker/Cargo.toml", cargo)):
    m = ver_re.fullmatch(v)
    if not m or m.group(1) != minor or int(m.group(2)) < minimum_patch:
        print(f"FAIL: {name} version {v} does not track upstream {upstream} "
              f"(want 0.{minor}.{minimum_patch} or higher patch, optionally -dev.N)")
        rc = 1
    else:
        print(f"PASS: {name} {v} tracks upstream {upstream}")
sys.exit(rc)
PY
