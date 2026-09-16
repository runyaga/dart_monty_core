#!/usr/bin/env bash
# =============================================================================
# tool/dmc_container.sh — the recipe for the `dmc-build` gate container
# =============================================================================
# `tool/gate.sh` runs inside a container named `dmc-build`, and so does
# dart_monty's. Until now that container existed ONLY as a running object: it
# was started ad hoc from a shell, the invocation was never written down, and
# the sole trace of it in either repo was prose in gate.sh and
# dcm_host_gate.sh telling you to run things "in the container" without saying
# where that container came from. `podman inspect` was the only copy of the
# recipe, which meant the recipe would have died with the container.
#
# That is the first thing this file fixes: THE RECIPE IS NOW IN THE REPO.
#
# ---------------------------------------------------------------------------
# THE SECOND THING: `--init`, AND WHY ITS ABSENCE LEAKED 45,725 ZOMBIES
# ---------------------------------------------------------------------------
# The original invocation was, verbatim from `podman inspect`:
#
#   podman run -d --name dmc-build \
#     -v <klangk-workspace>/home:/home -v <solpi-bench>:/work \
#     --entrypoint '["sleep","infinity"]' \
#     localhost/klangk-workspace-devtools:latest
#
# so PID 1 in the container was `sleep infinity`. `sleep` never calls wait().
#
# On Linux, when a process dies before its children, those children are
# re-parented to PID 1, and PID 1 is responsible for reaping them. An init
# reaps; `sleep` does not. Every orphan therefore became a permanent zombie,
# holding its PID-table entry and task_struct for the life of the container.
#
# Measured 2026-09-16, container `Up 2 days`:
#
#   $ podman exec dmc-build bash -lc 'ps -eo stat | grep -c Z'
#   45725                       # out of 45730 processes total: 5 were alive
#
#   $ podman exec dmc-build bash -lc 'ps -eo stat=,comm= | awk "\$1~/Z/{print \$2}" \
#       | sort | uniq -c | sort -rn | head -5'
#   17470 dart:dartdev_ao
#   12368 chromium
#    5780 bash
#    5126 chrome_crashpad
#    2307 dart:test.dart-
#
# NOTE WHAT THAT HISTOGRAM RULES OUT. The leak is not a Chromium bug and not a
# missing `--no-zygote`: Dart tooling outnumbers Chromium, and plain `bash` is
# third. Anything whose parent happens to exit first ends up on PID 1. So there
# is no harness to patch and no wrapper that should `wait` — the single defect
# is that PID 1 cannot reap, and one flag fixes every producer at once.
#
# `--init` makes podman run catatonit as PID 1, which reaps orphans and
# forwards signals; the real command becomes PID 2. Nothing else changes.
#
# ---------------------------------------------------------------------------
# WHY THE FIX IS A RUN FLAG AND NOT AN `ENTRYPOINT` IN THE IMAGE
# ---------------------------------------------------------------------------
# The obvious alternative is to bake tini/dumb-init into the image
# (klangk's src/containers/workspace/Dockerfile.devtools) as its ENTRYPOINT.
# That would NOT have prevented this: the invocation above passes
# `--entrypoint '["sleep","infinity"]'`, which REPLACES whatever the image
# declares. An image-level init is defeated by the very flag that created this
# container. `--init` is injected by podman independently of the entrypoint, so
# it survives the override — it is the only form of the fix that actually holds
# here.
#
# (klangk's own workspace path already gets this right: podman.py's
# `_create_base_args` appends `--init`. `dmc-build` is hand-rolled and bypassed
# it. Only the ad-hoc container was ever affected.)
#
# ---------------------------------------------------------------------------
# WHAT RECREATION COSTS
# ---------------------------------------------------------------------------
# `--init` cannot be added to an existing container, so applying this fix means
# recreating `dmc-build`. Both bind mounts are on the host and survive intact:
#
#   /home  <- the klangk workspace home (.pub-cache, .cargo, .dart-tool)
#   /work  <- the solpi-bench checkout, including native/target/
#
# What is lost is the container's writable layer, and the only part of it worth
# naming is CARGO_HOME=/opt/rust/cargo — 311 MB of crates-registry and
# advisory-db cache, which cargo re-downloads on the next build. Nothing there
# is authored; recreation costs network time, not data.
#
# Usage:
#   bash tool/dmc_container.sh check     # is PID 1 a reaper? exit 0 / 1
#   bash tool/dmc_container.sh create    # create it (fails if it exists)
#   bash tool/dmc_container.sh recreate  # replace it, applying --init
#
# `check` is what gate.sh calls; it is a no-op outside a container.
# =============================================================================
set -uo pipefail

# The klangk workspace whose home directory is mounted at /home. This is a
# host-specific path (it embeds a klangk workspace UUID), so it is overridable;
# the default is the value the live container was built with, recorded here so
# the recipe is reproducible rather than approximate.
DMC_HOME_MOUNT="${DMC_HOME_MOUNT:-/Users/runyaga/dev/klangk/.devenv/state/klangk/data/workspaces/543a45d3-6bdb-4b83-bc94-c3f11aceddf6/home}"
# The directory mounted at /work. dart_monty_core lives one level down, so this
# is the repo's parent: the gate runs at /work/dart_monty_core.
DMC_WORK_MOUNT="${DMC_WORK_MOUNT:-$(cd "$(dirname "$0")/../.." && pwd)}"
DMC_IMAGE="${DMC_IMAGE:-localhost/klangk-workspace-devtools:latest}"
DMC_NAME="${DMC_NAME:-dmc-build}"

in_container(){ [ -e /run/.containerenv ] || [ -e /.dockerenv ]; }

# Does PID 1 actually reap? ASK THE KERNEL, DO NOT PATTERN-MATCH THE NAME.
#
# The obvious check is an allowlist of known-good PID 1s — catatonit, tini,
# dumb-init. That was the first version of this function and it was WRONG in
# the passing direction: podman does not exec catatonit under its own name, it
# copies it in and runs it as `/run/podman-init`, so /proc/1/comm reads
# `podman-init`. A correctly-fixed container failed its own guard. Any such
# list is a guess about spelling that has to be maintained against every init
# anyone might use.
#
# So measure the PROPERTY instead: orphan a process and see whether it is
# reaped. `setsid bash -c '<probe> 1 & exit 0'` leaves <probe> running with a
# dead parent, so the kernel re-parents it to PID 1; one second later the probe
# exits. If PID 1 reaps, it is gone. If PID 1 is `sleep`, it is a zombie with
# ppid 1 and stays one forever.
#
# The probe is a uniquely-named copy of /bin/sleep so a gate running in
# parallel cannot be mistaken for it — counting zombies generally would be
# flaky, counting THIS name is exact. (comm truncates at 15 chars; the name is
# kept short deliberately.)
pid1_reaps(){
  local probe_name="dmcreap$$" probe="/tmp/dmcreap$$"
  cp /bin/sleep "$probe" 2>/dev/null || return 1
  setsid bash -c "'$probe' 1 & exit 0" >/dev/null 2>&1
  sleep 3
  local left
  left="$(ps -eo stat=,ppid=,comm= 2>/dev/null \
          | awk -v n="$probe_name" '$1 ~ /Z/ && $2 == 1 && $3 == n' | wc -l)"
  rm -f "$probe"
  [ "$left" -eq 0 ]
}

cmd_check(){
  if ! in_container; then
    echo "SKIP: not in a container — PID 1 reaping is a container concern."
    return 0
  fi
  local comm zn
  comm="$(tr -d '\0' < /proc/1/comm 2>/dev/null || echo '?')"
  zn="$(ps -eo stat --no-headers 2>/dev/null | grep -c Z || true)"
  if pid1_reaps; then
    echo "PID 1 ('$comm') reaped an orphaned probe. Zombies now: $zn."
    return 0
  fi
  echo "PID 1 ('$comm') did NOT reap an orphaned probe. Zombies: $zn." >&2
  echo "This container was created without --init; every orphaned test," >&2
  echo "browser and toolchain process will accumulate as a zombie forever." >&2
  echo "Fix: bash tool/dmc_container.sh recreate   (run it on the HOST)" >&2
  return 1
}

# The recipe. `--init` is the entire fix; everything else reproduces the
# container that was already in use.
dmc_run(){
  podman run -d --name "$DMC_NAME" \
    --init \
    -v "$DMC_HOME_MOUNT:/home" \
    -v "$DMC_WORK_MOUNT:/work" \
    --entrypoint '["sleep","infinity"]' \
    "$DMC_IMAGE"
}

cmd_create(){
  in_container && { echo "Refusing: run this on the HOST, not inside the container." >&2; exit 2; }
  dmc_run
}

cmd_recreate(){
  in_container && { echo "Refusing: run this on the HOST, not inside the container." >&2; exit 2; }
  podman rm -f "$DMC_NAME" >/dev/null 2>&1 || true
  dmc_run
}

case "${1:-check}" in
  check)    cmd_check ;;
  create)   cmd_create ;;
  recreate) cmd_recreate ;;
  *) echo "usage: $0 {check|create|recreate}" >&2; exit 2 ;;
esac
