import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="oilfind-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        (self.project / "scripts").mkdir(parents=True)
        (self.project / "Resources").mkdir()
        shutil = __import__("shutil")
        shutil.copy2(PROJECT / "scripts/install.sh", self.project / "scripts/install.sh")
        shutil.copy2(PROJECT / "Resources/Info.plist", self.project / "Resources/Info.plist")
        source = self.project / "build/Oil Find.app/Contents"
        (source / "MacOS").mkdir(parents=True)
        (source / "Info.plist").write_text("bundle=com.oiloil.find\n")
        (source / "MacOS/OilFind").write_text("new application")
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.destination = self.applications / "Oil Find.app"
        (self.destination / "Contents/MacOS").mkdir(parents=True)
        (self.destination / "Contents/Info.plist").write_text("bundle=com.oiloil.find\n")
        (self.destination / "Contents/MacOS/OilFind").write_text("previous application")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.environment = dict(os.environ)
        self.environment.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                                OILFIND_TEST_LOG=str(self.log),
                                OILFIND_INSTALL_DIR=str(self.applications))
        commands = {
            "pgrep": """#!/usr/bin/env python3
import sys
sys.exit(1)
""",
            "open": """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ['OILFIND_TEST_LOG'], 'a') as f: f.write(json.dumps(['open', *sys.argv[1:]])+'\\n')
sys.exit(1 if os.environ.get('OILFIND_TEST_FAIL') == 'open' else 0)
""",
            "codesign": """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ['OILFIND_TEST_LOG'], 'a') as f: f.write(json.dumps(['codesign', *sys.argv[1:]])+'\\n')
target = Path(sys.argv[-1])
sys.exit(1 if os.environ.get('OILFIND_TEST_FAIL') == 'verify' and target.name == 'Oil Find.app' else 0)
""",
            "ditto": """#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
with open(os.environ['OILFIND_TEST_LOG'], 'a') as f: f.write(json.dumps(['ditto', *sys.argv[1:]])+'\\n')
shutil.copytree(sys.argv[-2], sys.argv[-1])
""",
            "mv": """#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
with open(os.environ['OILFIND_TEST_LOG'], 'a') as f: f.write(json.dumps(['mv', *sys.argv[1:]])+'\\n')
src, dst = map(Path, sys.argv[1:])
if os.environ.get('OILFIND_TEST_FAIL') == 'promote' and src.name.startswith('.oilfind-stage') and dst.name == 'Oil Find.app': sys.exit(1)
if os.environ.get('OILFIND_TEST_FAIL') == 'restore' and src.name.startswith('.oilfind-backup'): sys.exit(1)
shutil.move(src, dst)
""",
        }
        # macOS absolute tools are replaced by private test shims in a copied script.
        self.script = self.project / "scripts/install.sh"
        source_text = self.script.read_text()
        source_text = source_text.replace("/usr/libexec/PlistBuddy", str(self.bin / "PlistBuddy"))
        self.script.write_text(source_text)
        build_shim = self.project / "scripts/build-app.sh"
        build_shim.write_text('#!/bin/bash\nprintf \'%s\\n\' \'["build-app"]\' >> "$OILFIND_TEST_LOG"\n')
        build_shim.chmod(0o755)
        commands["PlistBuddy"] = """#!/usr/bin/env python3
import sys
from pathlib import Path
print('com.oiloil.find' if 'bundle=com.oiloil.find' in Path(sys.argv[-1]).read_text() else 'wrong.bundle')
"""
        for name, body in commands.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)

    def run_install(self, failure=None):
        env = dict(self.environment)
        if failure:
            env["OILFIND_TEST_FAIL"] = failure
        return subprocess.run(["/bin/bash", str(self.script)], env=env, capture_output=True, text=True)

    def read_calls(self):
        return [json.loads(row) for row in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_installs_only_oil_find_and_opens_after_staging(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/MacOS/OilFind").read_text(), "new application")
        calls = self.read_calls()
        self.assertEqual(calls[0], ["build-app"])
        self.assertEqual(next(i for i, call in enumerate(calls) if call[0] == "open"), len(calls) - 1)
        self.assertFalse(any("Sift" in str(call) or "sift" in str(call) for call in calls))
        self.assertEqual(list(self.applications.glob(".oilfind-*")), [])

    def test_failed_promotion_rolls_back_previous_app_and_cleans_stage(self):
        result = self.run_install("promote")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/MacOS/OilFind").read_text(), "previous application")
        self.assertEqual(list(self.applications.glob(".oilfind-*")), [])
        self.assertFalse(any(call[0] == "open" for call in self.read_calls()))

    def test_failed_post_install_verification_rolls_back_previous_app(self):
        result = self.run_install("verify")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/MacOS/OilFind").read_text(), "previous application")
        self.assertEqual(list(self.applications.glob(".oilfind-*")), [])

    def test_failed_open_rolls_back_previous_app(self):
        result = self.run_install("open")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/MacOS/OilFind").read_text(), "previous application")
        self.assertEqual(list(self.applications.glob(".oilfind-*")), [])

    def test_source_script_has_no_sift_removal_or_user_data_deletion(self):
        script = PROJECT.joinpath("scripts/install.sh").read_text().lower()
        self.assertNotIn("sift", script)
        self.assertNotIn("defaults delete", script)
        self.assertNotIn('"/Applications/sift.app"', script)
        self.assertIn("com.oiloil.find", script)


if __name__ == "__main__":
    unittest.main()
