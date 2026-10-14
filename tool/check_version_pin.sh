#!/usr/bin/env bash
# =============================================================================
# This package's MINOR version must equal the monty patch it pins.
# =============================================================================
# The convention, unbroken across every release until it broke silently:
#
#     monty v0.0.17  ->  dart_monty_core 0.17.x
#     monty v0.0.18  ->  dart_monty_core 0.18.1
#     monty v0.0.19  ->  dart_monty_core 0.19.0
#     monty v0.0.23  ->  dart_monty_core 0.23.x
#
# It is not decorative. Snapshots are NOT portable across monty upgrades (see
# CHANGELOG: 0.18.x snapshots cannot be restored on 0.19.0), so the version a
# consumer reads is how they know which snapshot format and which engine
# semantics they are getting. A package that pins v0.0.23 while calling itself
# 0.19.0 tells every consumer the wrong thing about compatibility.
#
# How it broke: e1e4eda ("SoL-Pi run 2 (clean): monty v0.0.19 -> v0.0.23")
# moved the pin and did not touch pubspec.yaml or the CHANGELOG. Nothing
# compared the two, so the package described itself as 0.19.0 for as long as it
# took a human to notice the version on the deployed demo page.
#
# This is the same shape as tool/check_fixture_links.sh, which exists because a
# crate bump would otherwise leave every fixture link pointing at the wrong
# upstream source. Same failure, same remedy: a check, not a comment.
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

# G9: the package minor joins all three upstream digits (upstream 1.1.0 ->
# 0.110.x, 1.0.2 -> 0.102.x); the patch counts core's own fixes on one pin; a
# -dev.N suffix is allowed before release. native/worker/Cargo.toml carries
# the same major.minor.
python3 -I - <<'PY'
import json, re, sys

def want_minor(upstream):
    m = re.fullmatch(r"(\d)\.(\d)\.(\d)", upstream)
    if not m:
        sys.exit(f"FATAL: upstream version {upstream!r} is not three single digits")
    return "".join(m.groups())

# The two documented mappings, as controls.
assert want_minor("1.1.0") == "110" and want_minor("1.0.2") == "102"

upstream = json.load(open("tool/upstream/upstream-pin.json"))["version"]
minor = want_minor(upstream)
ver_re = re.compile(r"0\.(\d+)\.(\d+)(-dev\.\d+)?")
pub = re.search(r"^version:\s*(\S+)", open("pubspec.yaml").read(), re.M).group(1)
cargo = re.search(r'^version\s*=\s*"([^"]+)"', open("native/worker/Cargo.toml").read(), re.M).group(1)
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
