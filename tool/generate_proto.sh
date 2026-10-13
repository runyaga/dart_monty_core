#!/usr/bin/env bash
# =============================================================================
# Generate the Dart bindings for upstream monty-proto
# =============================================================================
# Output: lib/src/worker/proto/monty/v1/monty.pb*.dart (committed).
#
# Inputs, all pinned:
#   monty.proto     crates/monty-proto/proto/monty/v1/monty.proto at the
#                   commit tool/upstream/upstream-pin.json records. Fetched by
#                   commit id into a temp dir, so the content is addressed by
#                   hash and nothing upstream is vendored here.
#   protoc          grpcio-tools from tool/upstream/protoc-requirements.lock,
#                   installed with --require-hashes into a temp venv; must
#                   report libprotoc 35.1.
#   protoc_plugin   25.1.0 and every transitive dependency (dart_style
#                   among them, which formats the emitted code) from the
#                   committed tool/proto_gen/pubspec.lock, resolved with
#                   --enforce-lockfile: a lock that no longer satisfies
#                   tool/proto_gen/pubspec.yaml, or a package whose content
#                   hash differs, fails rather than re-resolving.
#   dart format     the SDK tool/check_sdk_pin.sh enforces, so the committed
#                   output has no format churn.
#
# Four declared field types differ from upstream's, in a working copy of the
# fetched file (the pinned blob itself is checked out read-only and never
# edited). Each keeps its wire type, so the bytes on the wire are unchanged;
# only what package:protobuf does with them changes:
#
#   MontyNode.int     sint64 -> uint64   package:protobuf 6.1.0 undoes zigzag
#                                        with an ARITHMETIC shift, so every
#                                        |v| >= 2^62 decodes wrongly (2^63-1
#                                        arrives as -1). As uint64 the raw
#                                        zigzag value comes through, and
#                                        lib/src/worker/wire_scalars.dart
#                                        decodes it with a logical shift.
#   MontyNode.float   double -> fixed64  package:protobuf writes every NaN as
#   Complex.real                         7ff8000000000000, dropping its sign
#   Complex.imag                         and payload, and dart2js can lose
#                                        them on read. As fixed64 the eight
#                                        bytes come through as bits, converted
#                                        to and from a double in the same file.
#
# Each substitution must match its upstream line exactly once, so a reshaped
# upstream file fails here rather than generating something else.
#
# CI's `proto-drift` job runs this and fails on `git diff`. That job is also
# the compensating check for excluding lib/src/worker/proto/ from the analyzer
# and DCM: generated code is not linted, so it must be proven to be exactly
# what the pinned generator emits.
#
# Needs: git, python3 (3.12-3.14; see the lock), dart, network.
# Usage: bash tool/generate_proto.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

OUT=lib/src/worker/proto
PROTO_PATH=crates/monty-proto/proto
PROTO_FILE=monty/v1/monty.proto
WANT_PROTOC='libprotoc 35.1'
WANT_PLUGIN='25.1.0'

TMP="$(mktemp -d)"
# chmod first: the fetched .proto and its working copy are made read-only.
trap 'chmod -R u+w "$TMP" 2>/dev/null; /bin/rm -rf "$TMP"' EXIT

read -r UPSTREAM COMMIT < <(python3 -I -c '
import json
p = json.load(open("tool/upstream/upstream-pin.json"))
print(p["upstream"], p["commit"])')

echo "--- fetch $PROTO_PATH/$PROTO_FILE @ ${COMMIT:0:12} ---"
git init -q "$TMP/upstream"
git -C "$TMP/upstream" fetch -q --depth 1 --filter=blob:none "$UPSTREAM.git" "$COMMIT"
mkdir -p "$TMP/pinned/$(dirname "$PROTO_FILE")" "$TMP/proto/$(dirname "$PROTO_FILE")"
git -C "$TMP/upstream" show "$COMMIT:$PROTO_PATH/$PROTO_FILE" > "$TMP/pinned/$PROTO_FILE"
chmod -R a-w "$TMP/pinned"
BLOB="$(git -C "$TMP/upstream" rev-parse "$COMMIT:$PROTO_PATH/$PROTO_FILE")"
GOT_BLOB="$(git hash-object "$TMP/pinned/$PROTO_FILE")"
[ "$GOT_BLOB" = "$BLOB" ] \
  || { echo "FAIL: fetched $PROTO_FILE hashes to $GOT_BLOB, want $BLOB"; exit 1; }
echo "blob $BLOB"

echo "--- working copy: 4 field-type substitutions ---"
python3 -I -c '
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
# (message, upstream declaration, generated declaration)
SUBS = [
    ("MontyNode", "    sint64 int = 5;\n", "    uint64 int = 5;\n"),
    ("MontyNode", "    double float = 7;\n", "    fixed64 float = 7;\n"),
    ("Complex", "  optional double real = 1;\n", "  optional fixed64 real = 1;\n"),
    ("Complex", "  optional double imag = 2;\n", "  optional fixed64 imag = 2;\n"),
]
for message, old, new in SUBS:
    head = "\nmessage " + message + " {\n"
    if text.count(head) != 1:
        sys.exit(f"FAIL: message {message} appears {text.count(head)} times, want 1")
    start = text.index(head)
    body = text[start:text.index("\n}\n", start) + 1]
    if text.count(old) != 1 or body.count(old) != 1:
        sys.exit(f"FAIL: {old.strip()!r} appears {text.count(old)} times "
                 f"({body.count(old)} in {message}), want exactly 1, in {message}")
    text = text.replace(old, new)
    print(f"{message}: {old.strip()} -> {new.strip()}")
open(dst, "w", encoding="utf-8").write(text)
' "$TMP/pinned/$PROTO_FILE" "$TMP/proto/$PROTO_FILE"
chmod -R a-w "$TMP/proto"

echo "--- protoc (grpcio-tools, hash-pinned) ---"
python3 -m venv "$TMP/venv"
"$TMP/venv/bin/python" -m pip install -q --disable-pip-version-check --no-cache-dir \
  --require-hashes --only-binary :all: --no-deps \
  -r tool/upstream/protoc-requirements.lock
GOT_PROTOC="$("$TMP/venv/bin/python" -I -m grpc_tools.protoc --version)"
[ "$GOT_PROTOC" = "$WANT_PROTOC" ] \
  || { echo "FAIL: protoc reports '$GOT_PROTOC', want '$WANT_PROTOC'"; exit 1; }
echo "$GOT_PROTOC"

echo "--- protoc_plugin $WANT_PLUGIN ---"
GEN=tool/proto_gen
if ! out="$(dart pub get --enforce-lockfile --directory "$GEN" 2>&1)"; then
  echo "$out"; echo "FAIL: $GEN/pubspec.lock does not resolve as committed"; exit 1
fi
PLUGIN_ROOT="$(python3 -I -c '
import json, sys
from pathlib import Path
from urllib.parse import urlparse, unquote
cfg = Path(sys.argv[1]) / ".dart_tool/package_config.json"
for p in json.loads(cfg.read_text())["packages"]:
    if p["name"] == "protoc_plugin":
        u = p["rootUri"]
        root = Path(unquote(urlparse(u).path)) if u.startswith("file:") else (cfg.parent / u).resolve()
        print(root)
        sys.exit(0)
sys.exit(f"protoc_plugin is not in {cfg}")' "$GEN")"
GOT_PLUGIN="$(sed -nE 's/^version: *([^ ]+).*/\1/p' "$PLUGIN_ROOT/pubspec.yaml")"
[ "$GOT_PLUGIN" = "$WANT_PLUGIN" ] \
  || { echo "FAIL: resolved protoc_plugin $GOT_PLUGIN, want $WANT_PLUGIN"; exit 1; }
# Output is shown only on failure: the compile notes that the plugin's own
# pubspec says `resolution: workspace`, which is harmless here because
# --packages supplies the resolution.
if ! out="$(dart compile exe --packages="$GEN/.dart_tool/package_config.json" \
  "$PLUGIN_ROOT/bin/protoc_plugin.dart" -o "$TMP/protoc-gen-dart" 2>&1)"; then
  echo "$out"; echo "FAIL: could not compile protoc_plugin"; exit 1
fi

echo "--- generate $OUT ---"
/bin/rm -rf "$OUT"
mkdir -p "$OUT"
"$TMP/venv/bin/python" -I -m grpc_tools.protoc \
  --plugin=protoc-gen-dart="$TMP/protoc-gen-dart" \
  -I "$TMP/proto" \
  --dart_out="$OUT" \
  "$PROTO_FILE"

echo "--- dart format (generated) ---"
# The package's language version, stated rather than inferred: the root
# package is not resolved here, and without a package config dart format
# falls back to the SDK's latest language version.
LANG_VERSION="$(sed -nE 's/^  sdk: *"?\^?([0-9]+\.[0-9]+)\..*/\1/p' pubspec.yaml)"
[ -n "$LANG_VERSION" ] || { echo "FAIL: no sdk constraint in pubspec.yaml"; exit 1; }
dart format --line-length=80 --language-version="$LANG_VERSION" "$OUT" >/dev/null 2>&1

find "$OUT" -type f | sort | while read -r f; do
  printf '%6d  %s\n' "$(wc -l < "$f")" "$f"
done
echo "=== monty-proto bindings generated ==="
