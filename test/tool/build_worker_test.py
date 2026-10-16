"""Packaging contract: Cargo-reported executable AND cdylib, both stamped.

Run: python3 test/tool/build_worker_test.py
No compiler is needed: a fake Cargo reports deliberately nonstandard paths.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class WorkerBuildTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="worker-build-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("tool", "native/worker/src", "native/worker/upstream", "bin", "artifacts"):
            (self.root / directory).mkdir(parents=True)
        source = Path(__file__).resolve().parents[2] / "tool/build_worker.sh"
        shutil.copyfile(source, self.root / "tool/build_worker.sh")
        for name in ("native/worker/Cargo.toml", "native/worker/Cargo.lock",
                     "native/worker/build.rs", "native/rust-toolchain.toml"):
            (self.root / name).write_text("test input\n")
        self.exe = self.root / "artifacts/odd-executable"
        self.lib = self.root / "artifacts/lib-from-cargo.so"
        self.exe.write_text("executable bytes")
        self.lib.write_text("library bytes")
        self.messages = [
            {"reason": "compiler-artifact", "target": {"name": "dart_monty_worker", "crate_types": ["bin"]},
             "executable": str(self.exe), "filenames": [str(self.exe)]},
            {"reason": "compiler-artifact", "target": {"name": "dart_monty_worker", "crate_types": ["cdylib", "rlib"]},
             "executable": None, "filenames": [str(self.lib), "ignore.rlib"]},
        ]
        self.commands = self.root / "cargo-args.json"
        self.install("uname", '#!/bin/sh\nif [ "$1" = -s ]; then echo Linux; else echo x86_64; fi\n')
        self.install("rustc", "#!/bin/sh\necho rustc-test\n")
        self.install("cargo", """#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
(root / 'cargo-args.json').write_text(json.dumps(sys.argv[1:]))
print((root / 'messages.jsonl').read_text())
sys.exit(int((root / 'cargo-exit').read_text()))
""")
        self.environment = {**os.environ, "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"]}
        self.dest = self.root / "lib/src/bin/linux-x64/dart_monty_worker"
        self.lib_dest = self.dest.with_name("libdart_monty_worker.so")
        self.set_messages()

    def install(self, name, content):
        path = self.root / "bin" / name
        path.write_text(content)
        path.chmod(0o755)

    def set_messages(self, code=0):
        (self.root / "messages.jsonl").write_text("\n".join(map(json.dumps, self.messages)))
        (self.root / "cargo-exit").write_text(str(code))

    def run_script(self, *args, ok=True):
        result = subprocess.run(["bash", "tool/build_worker.sh", *args], cwd=self.root,
                                env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout

    def test_copies_cargo_reported_paths_and_prints_both(self):
        output = self.run_script()
        self.assertEqual(self.dest.read_bytes(), self.exe.read_bytes())
        self.assertEqual(self.lib_dest.read_bytes(), self.lib.read_bytes())
        args = json.loads(self.commands.read_text())
        self.assertIn("--lib", args)
        self.assertIn("--bin", args)
        self.assertIn("--locked", args)
        self.assertIn(str(self.dest.relative_to(self.root)), output)
        self.assertIn(str(self.lib_dest.relative_to(self.root)), output)
        self.assertEqual(self.run_script("--print").splitlines(),
                         [str(p.relative_to(self.root)) for p in (self.dest, self.lib_dest)])
        self.run_script("--check")

    def test_missing_either_binary_is_stale(self):
        for name in (self.dest, self.lib_dest):
            with self.subTest(name=name.name):
                self.run_script()
                name.unlink()
                self.run_script("--check", ok=False)

    def test_replacing_either_binary_is_stale(self):
        for name in (self.dest, self.lib_dest):
            with self.subTest(name=name.name):
                self.run_script()
                name.write_text("replaced")
                self.run_script("--check", ok=False)

    def test_missing_or_ambiguous_library_artifact_fails(self):
        library = self.messages.pop()
        self.set_messages()
        self.run_script(ok=False)
        self.assertFalse(self.dest.exists())
        self.messages.extend([library, library])
        self.set_messages()
        self.run_script(ok=False)
        self.assertFalse(self.lib_dest.exists())

    def test_cargo_failure_cannot_stamp_valid_looking_messages(self):
        self.set_messages(code=1)
        self.run_script(ok=False)
        self.assertFalse(self.dest.exists())

    def test_changed_build_script_is_stale(self):
        self.run_script()
        with (self.root / "tool/build_worker.sh").open("a") as file:
            file.write("\n# changed recipe\n")
        self.run_script("--check", ok=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
