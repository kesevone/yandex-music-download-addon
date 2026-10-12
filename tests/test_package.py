"""Packaging tests have no network access and never install or start the music app."""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("addon_build", ROOT / "scripts/build.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class PackageTests(unittest.TestCase):
    def test_archive_is_deterministic_and_explicitly_allowlisted(self):
        first = BUILD.package()
        self.assertEqual(first, BUILD.package())
        with zipfile.ZipFile(io.BytesIO(first)) as archive:
            self.assertEqual(set(archive.namelist()), set((*BUILD.PACKAGE_FILES, "package.json")))
            manifest = json.loads(archive.read("package.json"))
            self.assertEqual(len(manifest["files"]), len(BUILD.PACKAGE_FILES))
            for entry in manifest["files"]:
                self.assertEqual(hashlib.sha256(archive.read(entry["path"])).hexdigest(), entry["sha256"])
            for name in archive.namelist():
                self.assertNotIn("dpapi", name)
                self.assertNotIn("downloads.json", name)
                self.assertNotIn(".asar", name)
                self.assertNotIn("config.json", name)

    def test_unlisted_private_files_are_never_packaged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in BUILD.PACKAGE_FILES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, path)
            sentinel = b"private-fixture-must-never-leave-build-directory"
            (root / "src/.yandex-music-session.dpapi").write_bytes(sentinel)
            (root / "src/downloads.json").write_bytes(sentinel)
            payload = BUILD.package(root)
            with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                self.assertFalse(any(sentinel in archive.read(name) for name in archive.namelist()))
                self.assertEqual(set(archive.namelist()), set((*BUILD.PACKAGE_FILES, "package.json")))

    def test_self_contained_setup_is_repeatable(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "setup.cmd"
            result = BUILD.build(target)
            first = target.read_bytes()
            self.assertEqual(result, BUILD.build(target))
            self.assertEqual(first, target.read_bytes())
            payload = re.search(rb"(?ms)^:YM_PAYLOAD_BEGIN\r?\n(.*?)^:YM_PAYLOAD_END", first).group(1)
            self.assertEqual(hashlib.sha256(base64.b64decode(payload)).hexdigest(), result["payloadSha256"])
            self.assertEqual(hashlib.sha256(first).hexdigest(), result["sha256"])
            self.assertNotIn(b"raw.githubusercontent.com", first)

    @unittest.skipUnless(sys.platform == "win32", "Windows CMD verification")
    def test_cmd_check_and_tampered_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "setup.cmd"
            BUILD.build(target)
            checked = subprocess.run(["cmd.exe", "/d", "/c", str(target), "--check"],
                                     capture_output=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            content = target.read_bytes()
            matched = re.search(rb"(?ms)^:YM_PAYLOAD_BEGIN\r?\n(.*?)^:YM_PAYLOAD_END", content)
            payload = bytearray(base64.b64decode(matched.group(1)))
            payload[-1] ^= 1
            corrupted = content[:matched.start(1)] + base64.b64encode(payload) + b"\r\n" + content[matched.end(1):]
            target.write_bytes(corrupted)
            rejected = subprocess.run(["cmd.exe", "/d", "/c", str(target), "--check"],
                                      capture_output=True, timeout=30)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b"checksum mismatch", rejected.stdout.lower())

    @unittest.skipUnless(sys.platform == "win32", "Windows CMD verification")
    def test_extract_only_with_shell_metacharacters_and_delayed_expansion(self):
        with tempfile.TemporaryDirectory() as temporary:
            special = Path(temporary) / "space & bang!"
            special.mkdir()
            target = special / "setup file.cmd"
            output = special / "extracted & ! files"
            BUILD.build(target)
            checked = subprocess.run('cmd.exe /d /v:on /s /c ""' + str(target)
                                     + '" --extract-only "' + str(output) + '""',
                                     capture_output=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertTrue((output / "src/ym-button-helper.mjs").is_file())
            self.assertEqual({str(path.relative_to(output)).replace("\\", "/")
                              for path in output.rglob("*") if path.is_file()},
                             set((*BUILD.PACKAGE_FILES, "package.json")))


if __name__ == "__main__":
    unittest.main()
