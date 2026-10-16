#!/usr/bin/env python3
"""F-2 parts A and B mutation checks. Each edit must fail a named VM test.

Run from the repository root: python3 tool/check_mount_mutations.py
No Rust, browser, baseline, or golden mutation. Originals are restored in
finally even when a test times out or a mutation survives. Test JSON must
report a failure of the selected test: compiler/load failures do not count.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
IO = "test/integration/worker/mount_io_test.dart"
LIFE = "test/integration/worker/mount_lifecycle_io_test.dart"
LOOKUP = "test/unit/mount/mount_dir_lookup_test.dart"
HOST = "lib/src/worker/host_answers.dart"
SESSION = "lib/src/worker/monty_session.dart"
NATIVE = "lib/src/mount/native_mounts.dart"
MOUNT = "lib/src/mount/mount_dir.dart"
MOUNT_LOOKUP = "lib/src/mount/native_mount_lookup.dart"
PROTO = "lib/src/worker/proto_session.dart"
CWD = "test/unit/worker/mount_cwd_test.dart"
BINDINGS = "lib/src/mount/native_mount_bindings.dart"

MUTANTS = [
    ("os-before-mount", IO, "P07 mount precedes handler", [
        (HOST, "final mounted = _mountTable?.call(call.writeToBuffer());",
         "final mounted = os != null ? null : _mountTable?.call(call.writeToBuffer());"),
    ]),
    ("omit-feed-table", IO, "P14 overlay across suspension", [
        (HOST, "_mountTable = beginMountFeed(mount);", "_mountTable = null;"),
    ]),
    ("retain-overlay-between-feeds", IO, "P04 overlay per feed", [
        (MOUNT, "NativeMountTable? beginMountFeed",
         "NativeMountTable? _mutationTable;\nNativeMountTable? beginMountFeed"),
        (MOUNT, ": NativeMountTable([for (final mount in mounts) mount._root]);",
         ": _mutationTable ??= NativeMountTable([for (final mount in mounts) mount._root]);"),
        (HOST, "_mountTable?.close();", "// mutant retains the table"),
    ]),
    ("skip-closed-check", IO, "P03 closed mount rejected before Feed start=false", [
        (NATIVE, "if (root._closed) {", "if (false) {"),
    ]),
    ("resume-consults-mounts", IO, "resume direct bypasses mount", [
        (SESSION, "    checkExternalResult(result);\n    final callId",
         "    if (snapshot.isOsFunction) return resumeCallAuto(snapshot);\n"
         "    checkExternalResult(result);\n    final callId"),
    ]),
    ("resume-auto-ignores-mount", IO, "P14 overlay across suspension", [
        (SESSION, "await _host.osCall(event.osCall, parentSleeps: false)",
         "await HostAnswers(os: _host.os).osCall(event.osCall, parentSleeps: false)"),
    ]),
    ("rename-source-only", IO, "P08 rename /else/a to /d/a never falls back", [
        (HOST, "final mounted = _mountTable?.call(call.writeToBuffer());",
         "final mounted = call.whichCall() == pb.OsCall_Call.rename && "
         "!call.rename.src.startsWith('/d/') ? null : "
         "_mountTable?.call(call.writeToBuffer());"),
    ]),
    ("rename-nul-before-length", IO, "P08 rename invalid destination length before NUL", [
        (HOST, "    final mounted = _mountTable?.call(call.writeToBuffer());",
         "    if (call.whichCall() == pb.OsCall_Call.rename && "
         "call.rename.dst.contains('\\u0000')) {\n"
         "      return _failed(call.callId, const ExternalException("
         "'ValueError', 'rename: embedded null character in dst'));\n"
         "    }\n    final mounted = _mountTable?.call(call.writeToBuffer());"),
    ]),
    ("consume-feed-start-sleep", IO,
     "sleep with mounts system.sleep feedStart surfaces then dispatches auto=true", [
        (SESSION,
         "    if (event.whichKind() == pb.ChildEvent_Kind.complete) {\n"
         "      return _completion(session._proto, event.complete);",
         "    if (event.whichKind() == pb.ChildEvent_Kind.osCall && "
         "event.osCall.whichCall() == pb.OsCall_Call.systemSleep) {\n"
         "      return _step(await _host.osCall(event.osCall, parentSleeps: true));\n"
         "    }\n"
         "    if (event.whichKind() == pb.ChildEvent_Kind.complete) {\n"
         "      return _completion(session._proto, event.complete);"),
    ]),
    ("resume-auto-local-sleep", IO,
     "sleep with mounts system.async_sleep feedStart surfaces then dispatches auto=true", [
        (SESSION, "await _host.osCall(event.osCall, parentSleeps: false)",
         "await _host.osCall(event.osCall, parentSleeps: true)"),
    ]),
    ("feed-run-handler-sleep", IO, "sleep with mounts system.sleep feedRun stays automatic", [
        (HOST, "          parentSleeps: true,", "          parentSleeps: false,"),
    ]),
    ("null-library-lookup", LOOKUP, "D-098 no library refuses", [
        # Simulate a loader returning a null native pointer silently. The Dart
        # type boundary must fail this named test; it must not be mistaken for
        # the actionable UnsupportedError. Never dereference the null pointer.
        (MOUNT_LOOKUP, "openLibrary: DynamicLibrary.open,",
         "openLibrary: (_) => nullptr as dynamic,"),
    ]),
    ("skip-package-library-open", IO, "P01 construction canonical fields", [
        (BINDINGS, "final library = openLibrary(worker.resolve(name).toFilePath());",
         "final DynamicLibrary library = throw ArgumentError('skip route 2');"),
    ]),
    ("skip-root-finalizer", LOOKUP, "MountDir NativeFinalizer releases unclosed roots", [
        (NATIVE, """    _serviceBindings.finalizer.attach(
      this,
      Pointer.fromAddress(_id),
      detach: this,
    );""", "    // mutant: root is never finalized"),
    ]),
    ("skip-table-disposal", LIFE, "feed table releases capability on complete", [
        (HOST, "_mountTable?.close();", "// mutant: table is never closed"),
    ]),
    ("leak-rejected-feed-table", LIFE, "feed table releases capability on input rejection", [
        # An unowned table acquired during preflight leaks on input refusal.
        (SESSION, "// Prepare inputs and cwd before opening a feed's mount table.",
         "// mutant: acquire and forget a preflight table\n"
         "        _hostFor(_proto, _config, externalLookup, os, mount);"),
    ]),
    ("forget-snapshot-mounts", IO, "P11 restore with mount=true starts fresh table", [
        (SESSION, "final host = _hostFor(_proto, _config, externalLookup, os, mount);",
         "final host = _hostFor(_proto, _config, externalLookup, os, null);"),
    ]),
    ("skip-first-mount-cwd", IO,
     "cwd mounted=true start=false first mount chooses cwd", [
        (PROTO, "request.feed.cwd = firstMount ?? defaultCwd;", "request.feed.cwd = defaultCwd;"),
    ]),
    ("reset-restored-cwd", IO,
     "cwd mounted=false start=false load snapshot preserves saved cwd", [
        (PROTO, "    _cwdSet = true;\n\n    return (",
         "    _cwdSet = false;\n\n    return ("),
    ]),
    ("establish-cwd-on-typing-rejection", CWD,
     "typing rejection retries default on wire mounted=false", [
        (PROTO, "if (feed && event.whichKind() != pb.ChildEvent_Kind.typingError) {",
         "if (feed) {"),
    ]),
    ("mount-table-before-cwd", CWD,
     "invalid cwd precedes overlap and sends no Feed start=false", [
        (SESSION, "// Prepare inputs and cwd before opening a feed's mount table.",
         "final host = _hostFor(_proto, _config, externalLookup, os, mount);"),
        (SESSION, "host: _hostFor(_proto, _config, externalLookup, os, mount),",
         "host: host,"),
    ]),
    ("do-not-establish-on-sent-error", IO,
     "cwd mounted=false start=false sent syntax error establishes cwd", [
        (PROTO, "if (feed && event.whichKind() != pb.ChildEvent_Kind.typingError) {",
         "if (feed && event.whichKind() == pb.ChildEvent_Kind.complete) {"),
    ]),

]


def run_mutant(identifier, test_file, name, edits):
    originals = {path: (ROOT / path).read_text() for path, _, _ in edits}
    changed = dict(originals)
    try:
        for path, old, new in edits:
            if changed[path].count(old) != 1:
                raise RuntimeError(f"{identifier}: expected one match in {path}: {old!r}")
            changed[path] = changed[path].replace(old, new)
        for path, source in changed.items():
            (ROOT / path).write_text(source)
        result = subprocess.run(
            ["dart", "test", test_file, "-p", "vm", "-N", name, "--reporter", "json"],
            cwd=ROOT, env={**os.environ, "DASH__SUPPRESS_ANALYTICS": "true"},
            capture_output=True, text=True, timeout=60,
        )
        selected = set()
        failed = set()
        errors = []
        for line in result.stdout.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "testStart":
                test = event["test"]
                if name in test["name"] and not test["name"].startswith("loading "):
                    selected.add(test["id"])
            if event.get("type") == "testDone" and event.get("result") in ("error", "failure"):
                failed.add(event["testID"])
            if event.get("type") == "error":
                errors.append(event.get("error", ""))
        killed = result.returncode != 0 and bool(selected & failed)
        print(f"{identifier}: {'KILLED' if killed else 'NOT KILLED'} — {name}", flush=True)
        if not killed:
            print(result.stdout[-6000:], result.stderr[-2000:], file=sys.stderr)
        return {
            "mutant": identifier, "test_file": test_file, "test": name,
            "killed": killed, "exit_code": result.returncode, "errors": errors,
        }
    finally:
        for path, source in originals.items():
            (ROOT / path).write_text(source)


def main():
    selected = [m for m in MUTANTS if len(sys.argv) == 1 or m[0] in sys.argv[1:]]
    if not selected:
        raise SystemExit("no matching mutants")
    results = [run_mutant(*mutant) for mutant in selected]
    destination = ROOT / ".host-requests" / "f2-mutation-results.json"
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps(results, indent=2) + "\n")
    count = sum(result["killed"] for result in results)
    print(f"{count}/{len(results)} mutants killed")
    return 0 if count == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
