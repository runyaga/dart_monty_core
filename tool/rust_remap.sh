#!/usr/bin/env bash
# =============================================================================
# rust_remap.sh — sourced by the wasm recipes; prints the rustc flags that keep
# build-machine absolute paths out of a committed module.
# =============================================================================
# Panic locations and debug strings embed source paths. Remapping the cargo
# home (registry and git checkouts), the rustup home and the checkout means the
# committed module carries neither the builder's home directory nor where the
# repo was cloned, and its bytes depend less on the machine.
#
# Used as CARGO_ENCODED_RUSTFLAGS, not RUSTFLAGS: cargo splits RUSTFLAGS on
# spaces (a home or checkout path with one breaks the flag), and an inherited
# CARGO_ENCODED_RUSTFLAGS would silently override RUSTFLAGS. Arguments are
# separated by 0x1f. The caller sets the whole value (and unsets RUSTFLAGS), so
# nothing is inherited.
#
# tool/check_asset_freshness.sh hashes this file into both asset records: a
# change here is a change to how every committed wasm is built.
#
# Usage:  source tool/rust_remap.sh
#         env -u RUSTFLAGS CARGO_ENCODED_RUSTFLAGS="$(remap_rustflags "$root")" \
#           cargo build ...
# =============================================================================

# $1: the repository root, remapped to /src.
remap_rustflags() {
  local root="${1:?remap_rustflags needs the repo root}" sep=$'\x1f'
  local cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  local rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  printf '%s' "--remap-path-prefix=$cargo_home=/cargo$sep--remap-path-prefix=$rustup_home=/rustup$sep--remap-path-prefix=$root=/src"
}
