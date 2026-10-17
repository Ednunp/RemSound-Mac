#!/usr/bin/env python3
"""Exercise the build's fixture setup with a fake app, without opening UI or audio."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

CHECK_SCRIPT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "CheckAccessibility.sh"


class AccessibilityCheckTests(unittest.TestCase):
    def setUp(self):
        path = os.environ.get("REMSOUND_TEST_ROOT", "")
        root = Path(path)
        if not path or not root.is_absolute() or not root.is_dir() or root.resolve() != root or root in [Path("/"), Path.home()]:
            self.fail("REMSOUND_TEST_ROOT must name an existing isolated absolute directory")
        self.temporary = tempfile.TemporaryDirectory(prefix="build-accessibility-", dir=root)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.bin = self.root / "bin"
        self.work = self.root / "work"
        self.stubs = self.root / "stubs"
        for folder in [self.source / "App/Resources/default sounds", self.source / "docs", self.bin, self.work, self.stubs, self.root / "Frameworks"]:
            folder.mkdir(parents=True, exist_ok=True)
        (self.source / "App/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "RemSound", "CFBundleIdentifier": "org.remsound.mac",
            "CFBundleName": "RemSound", "CFBundlePackageType": "APPL"
        }))
        (self.source / "App/RemSound.entitlements").write_bytes(plistlib.dumps({}))
        (self.source / "README.md").write_text("Synthetic help")
        (self.source / "Manual.html").write_text("<!doctype html><html lang='en'><title>Manual</title><p>Synthetic manual</p></html>")
        (self.source / "docs/fixture.md").write_text("Synthetic documentation")
        (self.source / "App/Resources/default sounds/fixture.wav").write_bytes(b"synthetic-wave")
        (self.root / "Frameworks/libmp3lame.0.dylib").write_bytes(b"synthetic-library")
        executable = self.bin / "RemSound"
        executable.write_text('''#!/usr/bin/python3
import json,os,plistlib,sys
from pathlib import Path
executable=Path(sys.argv[0])
info=executable.parent.parent/"Info.plist"
metadata=plistlib.loads(info.read_bytes()) if info.exists() else {}
resources=executable.parent.parent/"Resources"
report={
    "executable":str(executable),
    "identifier":metadata.get("CFBundleIdentifier"),
    "name":metadata.get("CFBundleName"),
    "arguments":sys.argv[1:],
    "manual":(resources/"README.md").exists(),
    "htmlManual":(resources/"Manual.html").exists(),
    "docs":(resources/"docs/fixture.md").exists(),
    "sounds":(resources/"default sounds/fixture.wav").exists(),
    "library":(executable.parent.parent/"Frameworks/libmp3lame.0.dylib").exists()
}
Path(os.environ["REMSOUND_FIXTURE_REPORT"]).write_text(json.dumps(report))
sys.exit(int(os.environ.get("REMSOUND_FIXTURE_EXIT","0")))
''')
        executable.chmod(0o700)
        signer = self.stubs / "codesign"
        signer.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$REMSOUND_FIXTURE_SIGN_LOG"
exit "${REMSOUND_FIXTURE_SIGN_EXIT:-0}"
''')
        signer.chmod(0o700)

    def run_fixture(self, allow="1", app_exit=0, sign_exit=0):
        self.report = self.root / "report.json"
        self.report.unlink(missing_ok=True)
        env = os.environ.copy()
        env.update(PATH=str(self.stubs) + os.pathsep + env["PATH"],
            REMSOUND_FIXTURE_REPORT=str(self.report), REMSOUND_FIXTURE_SIGN_LOG=str(self.root / "sign.log"),
            REMSOUND_FIXTURE_EXIT=str(app_exit), REMSOUND_FIXTURE_SIGN_EXIT=str(sign_exit))
        env.pop("REMSOUND_ALLOW_VISIBLE_UI_TESTS", None)
        if allow is not None:
            env["REMSOUND_ALLOW_VISIBLE_UI_TESTS"] = allow
        return subprocess.run(["/bin/bash", str(CHECK_SCRIPT), str(self.source), str(self.bin), str(self.work)],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)

    def assert_isolated_report(self):
        report = json.loads(self.report.read_text())
        self.assertIsInstance(report["identifier"], str, report)
        self.assertTrue(report["identifier"].startswith("org.remsound.mac.accessibility-test."), report)
        self.assertNotEqual(report["identifier"], "org.remsound.mac")
        self.assertEqual(report["name"], "RemSound", "Native menu contracts use the source app name")
        executable = Path(report["executable"])
        self.assertEqual(executable.parent.name, "MacOS")
        fixture = executable.parents[3]
        self.assertEqual(fixture.parent, self.work)
        self.assertTrue(fixture.name.startswith("accessibility."))
        self.assertIn("--check-accessibility", report["arguments"])
        self.assertIn("--silent", report["arguments"])
        config = Path(report["arguments"][report["arguments"].index("--config-dir") + 1])
        self.assertEqual(config, fixture / "config")
        for key in ["manual", "htmlManual", "docs", "sounds", "library"]:
            self.assertTrue(report[key], key)
        self.assertFalse(fixture.exists(), "The fixture must be cleaned after its exact process exits")
        self.assertEqual(list(self.work.iterdir()), [])
        return report["identifier"]

    def test_unset_or_nonexact_opt_in_skips_without_touching_work(self):
        for allow in [None, "", "true", "0"]:
            result = self.run_fixture(allow=allow)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("SKIP:", result.stdout)
            self.assertFalse(self.report.exists())
            self.assertFalse((self.root / "sign.log").exists())
            self.assertEqual(list(self.work.iterdir()), [])

    def test_explicit_opt_in_uses_unique_silent_bundle_and_cleans(self):
        identifiers = []
        for _ in range(2):
            result = self.run_fixture()
            self.assertEqual(result.returncode, 0, result.stdout)
            identifiers.append(self.assert_isolated_report())
        self.assertNotEqual(*identifiers)
        self.assertEqual(len((self.root / "sign.log").read_text().splitlines()), 6)

    def test_failed_app_propagates_exit_and_cleans(self):
        result = self.run_fixture(app_exit=23)
        self.assertEqual(result.returncode, 23, result.stdout)
        self.assert_isolated_report()

    def test_failed_signing_does_not_launch_and_cleans(self):
        result = self.run_fixture(sign_exit=17)
        self.assertEqual(result.returncode, 17, result.stdout)
        self.assertFalse(self.report.exists())
        self.assertEqual(list(self.work.iterdir()), [])

    def test_work_inside_source_is_rejected_before_staging(self):
        self.work = self.source / "work"
        self.work.mkdir()
        result = self.run_fixture()
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertFalse(self.report.exists())
        self.assertEqual(list(self.work.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
