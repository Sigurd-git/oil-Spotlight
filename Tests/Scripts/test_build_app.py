import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[2]
LOCAL_CERTIFICATE_SHA1 = "0123456789ABCDEF0123456789ABCDEF01234567"


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="oilfind-build-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        (self.root / "Resources").mkdir()
        (self.root / "bin").mkdir()
        for name in ("build-app.sh", "verify-release-app.sh"):
            shutil.copy2(PROJECT / "scripts" / name, self.root / "scripts" / name)
        shutil.copy2(PROJECT / "Resources/Info.plist", self.root / "Resources/Info.plist")
        (self.root / "Resources/AppIcon.icns").write_bytes(b"test icon")
        self.binary = self.root / "binary/OilFind"
        self.binary.parent.mkdir()
        self.binary.write_text("new executable")
        self.binary.chmod(0o755)
        (self.binary.parent / "key-service.xpc").mkdir()
        (self.binary.parent / "key-service.xpc/service").write_text("fixed test service")
        self.log = self.root / "calls.jsonl"
        self.local_signing_config = self.root / "Local Signing/identity.plist"
        self.local_keychain = self.root / "Local Signing/signing keychain.keychain-db"
        self.environment = dict(os.environ)
        for key in tuple(self.environment):
            if key.startswith("OILFIND_TEST_") or key in (
                "OILFIND_SIGN_IDENTITY", "OILFIND_BUILD_SYSTEM",
                "OILFIND_LOCAL_SIGNING_CONFIG", "OILFIND_REQUIRE_STABLE_SIGNING",
            ):
                self.environment.pop(key)
        self.environment.update(
            PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
            OILFIND_TEST_ROOT=str(self.root),
            OILFIND_TEST_LOG=str(self.log),
            OILFIND_LOCAL_SIGNING_CONFIG=str(self.local_signing_config),
        )
        stub = self.root / "bin/stub"
        stub.write_text(f"#!{sys.executable}\n" + r'''
import json, os, shutil, signal, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["OILFIND_TEST_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")
failure = os.environ.get("OILFIND_TEST_FAIL", "")
root = Path(os.environ["OILFIND_TEST_ROOT"])
if name == "swift":
    if failure == "build": sys.exit(1)
    if "--show-bin-path" in args: print(root / "binary")
elif name == "strip":
    if failure == "strip": sys.exit(1)
elif name == "security":
    if failure == "security": sys.exit(1)
    if os.environ.get("OILFIND_TEST_LOCAL_IDENTITY"):
        print('1) ' + os.environ["OILFIND_TEST_LOCAL_IDENTITY"] + ' "Oil Find Local Signing"')
    if os.environ.get("OILFIND_TEST_SELF_SIGNED"): print('1) ABC "Oil Find Self-Signed"')
elif name == "codesign":
    if "--force" in args and failure == "sign": sys.exit(1)
    if "--verify" in args and failure == "verify": sys.exit(1)
    if "--test-requirement" in args and failure == "requirement": sys.exit(1)
    if "-d" in args: print("Identifier=" + os.environ.get("OILFIND_TEST_IDENTIFIER", "com.oiloil.find"))
elif name == "prepare-key-service.sh":
    if failure == "key-service": sys.exit(1)
    print(root / "binary/key-service.xpc")
elif name == "mv":
    if Path(args[0]).name == "Oil Find.app" and Path(args[1]).name != "previous.app" and failure == "promote":
        sys.exit(1)
    shutil.move(args[0], args[1])
    if Path(args[1]).name == "previous.app" and failure == "interrupt":
        os.kill(os.getppid(), signal.SIGTERM)
elif name == "xcrun":
    print(os.environ.get("OILFIND_TEST_BUILD_INFO", "platform MACOS\nminos 14.0\nsdk 15.5"))
''')
        stub.chmod(0o755)
        for name in ("swift", "strip", "security", "codesign", "mv", "xcrun"):
            (self.root / "bin" / name).symlink_to(stub)
        (self.root / "scripts/prepare-key-service.sh").symlink_to(stub)

    def app_path(self, debug=False):
        return self.root / ("build/debug/Oil Find.app" if debug else "build/Oil Find.app")

    def seed_old_app(self, debug=False):
        app = self.app_path(debug)
        app.mkdir(parents=True)
        (app / "stale-resource").write_text("old artifact")
        return app

    def run_script(self, name="build-app.sh", arguments=(), **environment):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts" / name), *map(str, arguments)],
            capture_output=True, text=True, env=dict(self.environment, **environment),
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_no_stage(self):
        self.assertEqual(sorted((self.root / "build").glob("**/.oilfind-stage.*")), [])

    def write_local_signing_config(self, fingerprint=LOCAL_CERTIFICATE_SHA1, path=None):
        config = self.local_signing_config if path is None else path
        config.parent.mkdir(parents=True, exist_ok=True)
        self.local_keychain.parent.mkdir(parents=True, exist_ok=True)
        self.local_keychain.touch()
        config.write_bytes(plistlib.dumps({
            "certificateSHA1": fingerprint,
            "keychainPath": str(self.local_keychain),
        }))
        return config

    def assert_prebuild_signing_failure(self, result, app):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((app / "stale-resource").read_text(), "old artifact")
        self.assertFalse((app / "Contents").exists())
        self.assertFalse(any(call[0] in ("swift", "strip", "codesign", "mv") for call in self.calls()))
        self.assert_no_stage()

    def test_signing_environment_is_isolated_from_host_settings(self):
        with patch.dict(os.environ, {
            "OILFIND_LOCAL_SIGNING_CONFIG": "/host/signing/identity.plist",
            "OILFIND_REQUIRE_STABLE_SIGNING": "1",
            "OILFIND_SIGN_IDENTITY": "Developer ID Application: Host",
            "OILFIND_BUILD_SYSTEM": "invalid-host-setting",
            "OILFIND_TEST_LOCAL_IDENTITY": LOCAL_CERTIFICATE_SHA1,
            "OILFIND_TEST_SELF_SIGNED": "1",
            "OILFIND_TEST_FAIL": "security",
        }):
            isolated = BuildAppTests(methodName="test_release_replaces_old_bundle_without_stale_resources")
            self.addCleanup(isolated.doCleanups)
            isolated.setUp()
            self.assertEqual(isolated.environment["OILFIND_LOCAL_SIGNING_CONFIG"], str(isolated.local_signing_config))
            for key in ("OILFIND_REQUIRE_STABLE_SIGNING", "OILFIND_SIGN_IDENTITY", "OILFIND_BUILD_SYSTEM",
                        "OILFIND_TEST_LOCAL_IDENTITY", "OILFIND_TEST_SELF_SIGNED", "OILFIND_TEST_FAIL"):
                self.assertNotIn(key, isolated.environment)
            result = isolated.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        sign = next(call for call in isolated.calls() if call[:2] == ["codesign", "--force"])
        self.assertEqual(sign[sign.index("--sign") + 1], "-")

    def test_local_signing_pins_certificate_keychain_and_requirement(self):
        for fingerprint, required in ((LOCAL_CERTIFICATE_SHA1, "0"), (LOCAL_CERTIFICATE_SHA1.lower(), "1")):
            with self.subTest(fingerprint=fingerprint, required=required):
                self.log.unlink(missing_ok=True)
                self.write_local_signing_config(fingerprint)
                result = self.run_script(OILFIND_TEST_LOCAL_IDENTITY=LOCAL_CERTIFICATE_SHA1,
                                         OILFIND_TEST_SELF_SIGNED="1", OILFIND_REQUIRE_STABLE_SIGNING=required)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.calls()
                identity_lookup = ["security", "find-identity", "-p", "codesigning", str(self.local_keychain)]
                self.assertIn(identity_lookup, calls)
                build_index = next(i for i, call in enumerate(calls) if call[0] == "swift")
                self.assertLess(calls.index(identity_lookup), build_index)
                sign = next(call for call in calls if call[:2] == ["codesign", "--force"])
                self.assertEqual(sign[sign.index("--sign") + 1], LOCAL_CERTIFICATE_SHA1)
                self.assertEqual(sign[sign.index("--keychain") + 1], str(self.local_keychain))
                self.assertEqual(sign[sign.index("--identifier") + 1], "com.oiloil.find")
                self.assertIn("--timestamp=none", sign)
                requirement = f'identifier "com.oiloil.find" and certificate leaf = H"{LOCAL_CERTIFICATE_SHA1}"'
                self.assertEqual(sign[sign.index("--requirements") + 1], "=designated => " + requirement)
                verifications = [call for call in calls if call[:2] == ["codesign", "--verify"]]
                self.assertTrue(any("--deep" in call and "--strict" in call for call in verifications))
                pinned_check = next(call for call in verifications if "--test-requirement" in call)
                self.assertIn("--strict", pinned_check)
                self.assertEqual(pinned_check[pinned_check.index("--test-requirement") + 1], "=" + requirement)
                self.assertEqual(pinned_check[-1], sign[-1])
                self.assertEqual((self.app_path() / "Contents/XPCServices/OilFindClipboardKeyService.xpc/service").read_text(),
                                 "fixed test service")
                info = plistlib.loads((self.app_path() / "Contents/Info.plist").read_bytes())
                self.assertIs(info["OilFindUsesKeyService"], True)
                move_index = next(i for i, call in enumerate(calls) if call[0] == "mv")
                self.assertTrue(all(calls.index(call) < move_index for call in verifications))
                self.assert_no_stage()

    def test_fixed_key_service_failure_preserves_previous_artifact(self):
        app = self.seed_old_app()
        self.write_local_signing_config()
        result = self.run_script(OILFIND_TEST_LOCAL_IDENTITY=LOCAL_CERTIFICATE_SHA1,
                                 OILFIND_REQUIRE_STABLE_SIGNING="1", OILFIND_TEST_FAIL="key-service")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((app / "stale-resource").read_text(), "old artifact")
        self.assertFalse(any(call[0] in ("mv", "codesign") for call in self.calls()))
        self.assert_no_stage()

    def test_explicit_config_path_selects_its_identity(self):
        self.write_local_signing_config("F" * 40)
        selected = self.write_local_signing_config(path=self.root / "Selected Signing Config/identity.plist")
        result = self.run_script(OILFIND_LOCAL_SIGNING_CONFIG=str(selected),
                                 OILFIND_TEST_LOCAL_IDENTITY=LOCAL_CERTIFICATE_SHA1,
                                 OILFIND_REQUIRE_STABLE_SIGNING="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        sign = next(call for call in self.calls() if call[:2] == ["codesign", "--force"])
        self.assertEqual(sign[sign.index("--sign") + 1], LOCAL_CERTIFICATE_SHA1)

    def test_explicit_developer_id_can_override_optional_local_config(self):
        self.write_local_signing_config()
        identity = "Developer ID Application: Example"
        result = self.run_script(OILFIND_SIGN_IDENTITY=identity, OILFIND_TEST_FAIL="security")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertFalse(any(call[0] == "security" for call in calls))
        sign = next(call for call in calls if call[:2] == ["codesign", "--force"])
        self.assertEqual(sign[sign.index("--sign") + 1], identity)
        self.assertIn("--timestamp", sign)
        self.assertIn("--options", sign)
        self.assertNotIn("--keychain", sign)
        self.assertNotIn("--requirements", sign)

    def test_explicit_pinned_hash_satisfies_required_stable_signing(self):
        self.write_local_signing_config()
        result = self.run_script(OILFIND_REQUIRE_STABLE_SIGNING="1",
                                 OILFIND_SIGN_IDENTITY=LOCAL_CERTIFICATE_SHA1,
                                 OILFIND_TEST_LOCAL_IDENTITY=LOCAL_CERTIFICATE_SHA1)
        self.assertEqual(result.returncode, 0, result.stderr)
        sign = next(call for call in self.calls() if call[:2] == ["codesign", "--force"])
        self.assertEqual(sign[sign.index("--sign") + 1], LOCAL_CERTIFICATE_SHA1)
        self.assertEqual(sign[sign.index("--keychain") + 1], str(self.local_keychain))
        self.assertIn("--requirements", sign)

    def test_required_stable_signing_rejects_missing_config_before_build(self):
        app = self.seed_old_app()
        for identity in ("", "Developer ID Application: Example"):
            with self.subTest(identity=identity):
                self.log.unlink(missing_ok=True)
                result = self.run_script(OILFIND_REQUIRE_STABLE_SIGNING="1", OILFIND_SIGN_IDENTITY=identity,
                                         OILFIND_TEST_SELF_SIGNED="1")
                self.assert_prebuild_signing_failure(result, app)

    def test_invalid_local_config_never_builds_or_falls_back(self):
        app = self.seed_old_app()
        valid = {"certificateSHA1": LOCAL_CERTIFICATE_SHA1, "keychainPath": str(self.local_keychain)}
        invalid_configs = {
            "malformed plist": b"not a plist",
            "missing fingerprint": plistlib.dumps({"keychainPath": str(self.local_keychain)}),
            "missing keychain path": plistlib.dumps({"certificateSHA1": LOCAL_CERTIFICATE_SHA1}),
            "short fingerprint": plistlib.dumps(dict(valid, certificateSHA1=LOCAL_CERTIFICATE_SHA1[:-1])),
            "long fingerprint": plistlib.dumps(dict(valid, certificateSHA1=LOCAL_CERTIFICATE_SHA1 + "0")),
            "nonhex fingerprint": plistlib.dumps(dict(valid, certificateSHA1="G" * 40)),
            "missing keychain": plistlib.dumps(dict(valid, keychainPath=str(self.root / "missing keychain"))),
            "keychain is directory": plistlib.dumps(dict(valid, keychainPath=str(self.root))),
        }
        self.write_local_signing_config()
        for required in ("0", "1"):
            for case, contents in invalid_configs.items():
                with self.subTest(case=case, required=required):
                    self.log.unlink(missing_ok=True)
                    self.local_signing_config.write_bytes(contents)
                    result = self.run_script(OILFIND_REQUIRE_STABLE_SIGNING=required,
                                             OILFIND_TEST_LOCAL_IDENTITY=LOCAL_CERTIFICATE_SHA1,
                                             OILFIND_TEST_SELF_SIGNED="1")
                    self.assert_prebuild_signing_failure(result, app)

    def test_unavailable_local_identity_never_builds_or_falls_back(self):
        app = self.seed_old_app()
        self.write_local_signing_config()
        for required in ("0", "1"):
            for identity, failure in (("", ""), ("F" * 40, ""), (LOCAL_CERTIFICATE_SHA1, "security")):
                with self.subTest(required=required, identity=identity, failure=failure):
                    self.log.unlink(missing_ok=True)
                    result = self.run_script(OILFIND_REQUIRE_STABLE_SIGNING=required,
                                             OILFIND_TEST_LOCAL_IDENTITY=identity, OILFIND_TEST_FAIL=failure,
                                             OILFIND_TEST_SELF_SIGNED="1")
                    self.assert_prebuild_signing_failure(result, app)
                    self.assertIn(["security", "find-identity", "-p", "codesigning", str(self.local_keychain)], self.calls())

    def test_required_stable_signing_rejects_conflicting_explicit_identity(self):
        app = self.seed_old_app()
        self.write_local_signing_config()
        for identity in ("Developer ID Application: Example", "F" * 40, "-"):
            with self.subTest(identity=identity):
                self.log.unlink(missing_ok=True)
                result = self.run_script(OILFIND_REQUIRE_STABLE_SIGNING="1", OILFIND_SIGN_IDENTITY=identity,
                                         OILFIND_TEST_LOCAL_IDENTITY=LOCAL_CERTIFICATE_SHA1)
                self.assert_prebuild_signing_failure(result, app)

    def test_local_signing_and_verification_failures_preserve_previous_artifact(self):
        app = self.seed_old_app()
        self.write_local_signing_config()
        for failure in ("sign", "verify", "requirement"):
            with self.subTest(failure=failure):
                self.log.unlink(missing_ok=True)
                result = self.run_script(OILFIND_REQUIRE_STABLE_SIGNING="1", OILFIND_TEST_FAIL=failure,
                                         OILFIND_TEST_LOCAL_IDENTITY=LOCAL_CERTIFICATE_SHA1)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((app / "stale-resource").read_text(), "old artifact")
                self.assertFalse((app / "Contents").exists())
                self.assertFalse(any(call[0] == "mv" for call in self.calls()))
                signs = [call for call in self.calls() if call[:2] == ["codesign", "--force"]]
                self.assertEqual(len(signs), 1)
                self.assertEqual(signs[0][signs[0].index("--sign") + 1], LOCAL_CERTIFICATE_SHA1)
                self.assert_no_stage()

    def test_release_replaces_old_bundle_without_stale_resources(self):
        app = self.seed_old_app()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(app))
        self.assertFalse((app / "stale-resource").exists())
        self.assertEqual((app / "Contents/MacOS/OilFind").read_text(), "new executable")
        calls = self.calls()
        self.assertIn(["swift", "build", "-c", "release"], calls)
        self.assertTrue(any(call[:2] == ["strip", "-S"] for call in calls))
        sign = next(call for call in calls if call[:2] == ["codesign", "--force"])
        self.assertEqual(sign[sign.index("--sign") + 1], "-")
        verify_index = next(i for i, call in enumerate(calls) if call[:2] == ["codesign", "--verify"])
        move_index = next(i for i, call in enumerate(calls) if call[0] == "mv")
        self.assertLess(verify_index, move_index)
        self.assert_no_stage()

    def test_debug_bundle_is_separate_and_not_stripped(self):
        release = self.seed_old_app()
        debug = self.seed_old_app(debug=True)
        result = self.run_script(arguments=("--debug",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((release / "stale-resource").exists())
        self.assertFalse((debug / "stale-resource").exists())
        self.assertIn(["swift", "build", "-c", "debug"], self.calls())
        self.assertFalse(any(call[0] == "strip" for call in self.calls()))
        self.assert_no_stage()

    def test_signing_identity_selection_is_preserved(self):
        for environment, identity, hardened in (
            ({"OILFIND_SIGN_IDENTITY": "Developer ID Application: Example"}, "Developer ID Application: Example", True),
            ({"OILFIND_TEST_SELF_SIGNED": "1"}, "Oil Find Self-Signed", False),
        ):
            with self.subTest(identity=identity):
                self.log.unlink(missing_ok=True)
                result = self.run_script(**environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                sign = next(call for call in self.calls() if call[:2] == ["codesign", "--force"])
                self.assertEqual(sign[sign.index("--sign") + 1], identity)
                self.assertEqual(sign[sign.index("--identifier") + 1], "com.oiloil.find")
                self.assertEqual("--timestamp" in sign, hardened)
                self.assertEqual("--options" in sign, hardened)
                self.assert_no_stage()

    def test_selected_build_system_is_used_for_build_and_binary_discovery(self):
        result = self.run_script(OILFIND_BUILD_SYSTEM="native")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["swift", "build", "-c", "release", "--build-system", "native"], self.calls())
        self.assertIn(["swift", "build", "-c", "release", "--build-system", "native", "--show-bin-path"], self.calls())

    def test_invalid_build_system_preserves_previous_artifact(self):
        app = self.seed_old_app()
        result = self.run_script(OILFIND_BUILD_SYSTEM="unknown")
        self.assertEqual(result.returncode, 2)
        self.assertEqual((app / "stale-resource").read_text(), "old artifact")
        self.assertEqual(self.calls(), [])

    def test_failures_preserve_previous_artifact_and_clean_stage(self):
        app = self.seed_old_app()
        for failure in ("build", "strip", "sign", "verify", "promote", "interrupt"):
            with self.subTest(failure=failure):
                result = self.run_script(OILFIND_TEST_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((app / "stale-resource").read_text(), "old artifact")
                self.assertFalse((app / "Contents").exists())
                self.assert_no_stage()

    def test_first_build_promotion_failure_leaves_no_artifact(self):
        result = self.run_script(OILFIND_TEST_FAIL="promote")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.app_path().exists())
        self.assert_no_stage()

    def test_removed_icon_is_not_carried_over(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / "Resources/AppIcon.icns").unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.app_path() / "Contents/Resources/AppIcon.icns").exists())

    def test_invalid_arguments_do_not_build(self):
        for arguments in (("--invalid",), ("--debug", "extra"), ("",)):
            with self.subTest(arguments=arguments):
                result = self.run_script(arguments=arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.calls(), [])

    def test_release_verification_accepts_valid_metadata_and_signature(self):
        self.assertEqual(self.run_script().returncode, 0)
        result = self.run_script("verify-release-app.sh", (self.app_path(),))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified release app:", result.stdout)

    def test_release_verification_rejects_bad_sdk_target_and_signature(self):
        self.assertEqual(self.run_script().returncode, 0)
        for environment in (
            {"OILFIND_TEST_BUILD_INFO": "platform MACOS\nminos 14.0\nsdk 15.3"},
            {"OILFIND_TEST_BUILD_INFO": "platform MACOS\nminos 15.0\nsdk 15.5"},
            {"OILFIND_TEST_BUILD_INFO": "platform IOS\nminos 14.0\nsdk 15.5"},
            {"OILFIND_TEST_BUILD_INFO": ""},
            {"OILFIND_TEST_IDENTIFIER": "wrong.bundle"},
            {"OILFIND_TEST_FAIL": "verify"},
        ):
            with self.subTest(environment=environment):
                result = self.run_script("verify-release-app.sh", (self.app_path(),), **environment)
                self.assertNotEqual(result.returncode, 0)

    def test_release_verification_requires_executable_and_icon(self):
        self.assertEqual(self.run_script().returncode, 0)
        binary = self.app_path() / "Contents/MacOS/OilFind"
        binary.chmod(0o644)
        self.assertNotEqual(self.run_script("verify-release-app.sh", (self.app_path(),)).returncode, 0)
        binary.chmod(0o755)
        (self.app_path() / "Contents/Resources/AppIcon.icns").unlink()
        self.assertNotEqual(self.run_script("verify-release-app.sh", (self.app_path(),)).returncode, 0)

    def test_release_verification_rejects_wrong_plist_metadata(self):
        for key, value in (("CFBundleIdentifier", "wrong.bundle"), ("CFBundleExecutable", "Wrong"),
                           ("LSMinimumSystemVersion", "15.0")):
            with self.subTest(key=key):
                self.assertEqual(self.run_script().returncode, 0)
                subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :{key} {value}",
                                str(self.app_path() / "Contents/Info.plist")], check=True)
                self.assertNotEqual(self.run_script("verify-release-app.sh", (self.app_path(),)).returncode, 0)

    def test_real_macho_signing_and_archive_roundtrip(self):
        source = self.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        subprocess.run(["/usr/bin/xcrun", "clang", "-mmacosx-version-min=14.0",
                        str(source), "-o", str(self.binary)], check=True, capture_output=True)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "com.oiloil.find",
                        str(self.app_path())], check=True, capture_output=True)
        archive = self.root / "release.zip"
        extracted = self.root / "extracted"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                        str(self.app_path()), str(archive)], check=True)
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], check=True)
        for app in (self.app_path(), extracted / "Oil Find.app"):
            result = subprocess.run(["/bin/bash", str(self.root / "scripts/verify-release-app.sh"), str(app)],
                                    capture_output=True, text=True, env=os.environ)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (extracted / "Oil Find.app/Contents/MacOS/OilFind").write_bytes(b"tampered executable")
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/verify-release-app.sh"),
                                 str(extracted / "Oil Find.app")], capture_output=True, text=True, env=os.environ)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
