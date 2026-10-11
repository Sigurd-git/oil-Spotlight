import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[2]
FINGERPRINT = "0123456789ABCDEF0123456789ABCDEF01234567"
EXISTING_IDENTITY = {"fingerprint": "A" * 40, "name": "Unrelated signing identity"}
AES_ACL = {"application": "previous Oil Find", "access": "unchanged"}


class CreateSigningCertTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="oilfind-signing-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "Test Home"
        self.keychain = self.home / "Library/Keychains/login.keychain-db"
        self.keychain.parent.mkdir(parents=True)
        self.keychain.write_bytes(b"untouched mock keychain")
        self.config = self.home / "Library/Application Support/Oil Find Signing/identity.plist"
        self.config.parent.mkdir(parents=True)
        self.work = self.config.parent / ".configure-work"
        self.backup = self.home / "Documents/Oil Find Signing/oil-find-signing.p12"
        self.state = self.root / "keychain-state.json"
        self.log = self.root / "calls.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = {
            "HOME": str(self.home),
            "PATH": str(self.bin) + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "OILFIND_LOCAL_SIGNING_CONFIG": str(self.config),
            "OILFIND_TEST_ROOT": str(self.root),
            "OILFIND_TEST_KEYCHAIN": str(self.keychain),
            "OILFIND_TEST_STATE": str(self.state),
            "OILFIND_TEST_LOG": str(self.log),
            "OILFIND_TEST_FINGERPRINT": FINGERPRINT,
        }
        self.reset_case()
        stub = self.bin / "stub"
        stub.write_text(f"#!{sys.executable}\n" + r'''
import json, os, plistlib, shutil, stat, sys, time
from pathlib import Path

name, args = Path(sys.argv[0]).name, sys.argv[1:]
root = Path(os.environ["OILFIND_TEST_ROOT"])
state_path = Path(os.environ["OILFIND_TEST_STATE"])
fingerprint = os.environ["OILFIND_TEST_FINGERPRINT"]
failure = os.environ.get("OILFIND_TEST_FAIL", "")
with open(os.environ["OILFIND_TEST_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")

def argument(flag):
    return args[args.index(flag) + 1]

def write_state(state):
    state_path.write_text(json.dumps(state))

if name == "security":
    # Fail closed on any command that could alter trust, search lists or key ACLs.
    if not args or args[0] not in ("find-identity", "find-certificate"):
        sys.exit(70)
    if Path(args[-1]).resolve() != Path(os.environ["OILFIND_TEST_KEYCHAIN"]):
        sys.exit(71)
    if failure == "security": sys.exit(1)
    state = json.loads(state_path.read_text())
    if args[0] == "find-identity":
        for index, identity in enumerate(state["identities"], 1):
            if failure == "identity-check" and identity["fingerprint"] == fingerprint:
                continue
            print(f'{index}) {identity["fingerprint"]} "{identity["name"]}"')
    else:
        sys.exit(0 if state["certificate_only"] else 1)
elif name == "openssl":
    if args[0] == "req":
        key = Path(argument("-keyout"))
        key.write_text("mock private key")
        Path(argument("-out")).write_text("mock certificate")
        (root / "private-modes.json").write_text(json.dumps({
            "directory": stat.S_IMODE(key.parent.stat().st_mode),
            "key": stat.S_IMODE(key.stat().st_mode),
        }))
        if os.environ.get("OILFIND_TEST_HOLD_GENERATION"):
            parent_pid = os.getppid()
            (root / "generation-held").touch()
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        os.kill(parent_pid, 0)
                    except ProcessLookupError:
                        sys.exit(1)
                    time.sleep(0.02)
                sys.exit(1)
            finally:
                (root / "generation-stopped").touch()
    elif args[0] == "x509":
        print("sha1 Fingerprint=" + ":".join(fingerprint[i:i + 2] for i in range(0, 40, 2)))
    elif args[0] == "rand":
        print("mock-transport-password")
    elif args[0] == "pkcs12":
        output = Path(argument("-out"))
        if failure == "backup-export" and output.name == "backup.p12":
            output.write_bytes(b"incomplete export")
            sys.exit(1)
        output.write_text(json.dumps({"mock_encrypted_identity": fingerprint}))
    else:
        sys.exit(72)
elif name == "xcrun":
    if not args or args[0] != "swiftc": sys.exit(73)
    if failure == "compile": sys.exit(1)
    output = Path(argument("-o"))
    shutil.copyfile(root / "bin/stub", output)
    output.chmod(0o700)
elif name == "import-identity":
    if len(args) != 3 or Path(args[0]).resolve() != Path(os.environ["OILFIND_TEST_KEYCHAIN"]):
        sys.exit(74)
    if json.loads(Path(args[1]).read_text())["mock_encrypted_identity"] != fingerprint:
        sys.exit(75)
    if Path(args[2]).read_text().strip() != "mock-transport-password": sys.exit(76)
    if failure == "import": sys.exit(1)
    state = json.loads(state_path.read_text())
    state["identities"].append({"fingerprint": fingerprint, "name": "Oil Find Self-Signed"})
    write_state(state)
elif name == "plutil":
    path = Path(args[-1])
    if args[0] == "-create":
        value = {}
    elif args[0] == "-insert":
        value = plistlib.loads(path.read_bytes())
        value[args[1]] = int(args[3]) if args[2] == "-integer" else args[3]
    else:
        sys.exit(77)
    path.write_bytes(plistlib.dumps(value))
elif name == "PlistBuddy":
    try:
        field = argument("-c").split(":", 1)[1]
        print(plistlib.loads(Path(args[-1]).read_bytes())[field])
    except (KeyError, ValueError, plistlib.InvalidFileException):
        sys.exit(1)
elif name in ("cp", "mv"):
    source, destination = map(Path, args[-2:])
    if failure == "backup-copy" and name == "cp" and source.name == "backup.p12": sys.exit(1)
    if failure == "backup-promote" and name == "mv" and destination.name == "oil-find-signing.p12": sys.exit(1)
    if failure == "config-promote" and name == "mv" and destination.name == "identity.plist": sys.exit(1)
    if name == "cp":
        shutil.copyfile(source, destination)
    else:
        os.replace(source, destination)
else:
    # Never delegate unexpected invocations to a real security or build tool.
    sys.exit(78)
''')
        stub.chmod(0o755)
        for name in ("security", "openssl", "xcrun", "plutil", "PlistBuddy", "cp", "mv",
                     "codesign", "swift", "swiftc"):
            (self.bin / name).symlink_to(stub)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / "create-signing-cert.sh"
        source = (PROJECT / "scripts/create-signing-cert.sh").read_text()
        # Rewrite absolute command paths only in this private test copy.
        for name in ("openssl", "xcrun", "security", "codesign", "plutil", "swift", "swiftc"):
            source = source.replace("/usr/bin/" + name, str(self.bin / name))
        source = source.replace("/usr/libexec/PlistBuddy", str(self.bin / "PlistBuddy"))
        self.script.write_text(source)
        shutil.copyfile(PROJECT / "scripts/import-signing-identity.swift", scripts / "import-signing-identity.swift")

    def tearDown(self):
        self.assert_unrelated_keychain_untouched()

    def assert_unrelated_keychain_untouched(self):
        state = self.read_state()
        self.assertEqual(state["aes_acl"], AES_ACL)
        self.assertIn(EXISTING_IDENTITY, state["identities"])
        self.assertEqual(self.keychain.read_bytes(), b"untouched mock keychain")
        calls = self.calls()
        self.assertTrue(all(call[1] in ("find-identity", "find-certificate")
                            for call in calls if call[0] == "security"))
        self.assertFalse(any(call[0] in ("codesign", "swift", "swiftc") for call in calls))

    def reset_case(self):
        self.config.unlink(missing_ok=True)
        self.backup.unlink(missing_ok=True)
        self.log.unlink(missing_ok=True)
        self.state.write_text(json.dumps({
            "identities": [EXISTING_IDENTITY], "certificate_only": False, "aes_acl": AES_ACL,
        }))

    def read_state(self):
        return json.loads(self.state.read_text())

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def run_script(self, arguments=("--local",), passwords="test-password\ntest-password\n", **environment):
        result = subprocess.run(["/bin/bash", str(self.script), *arguments], cwd=self.root,
                                env=dict(self.environment, **environment), input=passwords,
                                capture_output=True, text=True, timeout=15)
        self.assert_unrelated_keychain_untouched()
        return result

    def seed_identity(self, fingerprint=FINGERPRINT):
        state = self.read_state()
        state["identities"].append({"fingerprint": fingerprint, "name": "Oil Find Self-Signed"})
        self.state.write_text(json.dumps(state))

    def seed_config(self, fingerprint=FINGERPRINT):
        self.config.write_bytes(plistlib.dumps({
            "certificateSHA1": fingerprint, "keychainPath": str(self.keychain),
        }))

    def assert_no_creation(self):
        self.assertFalse(any(call[0] in ("openssl", "xcrun", "import-identity") for call in self.calls()))

    def assert_clean(self):
        self.assertFalse(self.work.exists())
        self.assertEqual(sorted(self.config.parent.glob(".identity.*")), [])
        self.assertEqual(sorted(self.backup.parent.glob(".oil-find-signing.*")), [])

    def assert_config(self):
        config = plistlib.loads(self.config.read_bytes())
        self.assertEqual(config["certificateSHA1"], FINGERPRINT)
        self.assertEqual(config["keychainPath"], str(self.keychain))
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.config.parent.stat().st_mode), 0o700)

    def test_local_creation_protects_temporary_keys_and_preserves_other_entries(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_config()
        self.assertFalse(self.backup.exists())
        self.assertEqual(json.loads((self.root / "private-modes.json").read_text()), {"directory": 0o700, "key": 0o600})
        self.assertEqual(len(self.read_state()["identities"]), 2)
        self.assertEqual(sum(call[0] == "import-identity" for call in self.calls()), 1)
        self.assert_clean()

    def test_default_creation_publishes_complete_private_backup_before_import(self):
        result = self.run_script(arguments=())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_config()
        self.assertEqual(json.loads(self.backup.read_text()), {"mock_encrypted_identity": FINGERPRINT})
        self.assertEqual(stat.S_IMODE(self.backup.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.backup.parent.stat().st_mode), 0o700)
        calls = self.calls()
        exports = [call for call in calls if call[:2] == ["openssl", "pkcs12"]]
        self.assertTrue(all(Path(call[call.index("-out") + 1]).parent == self.work for call in exports))
        publication = next(i for i, call in enumerate(calls) if call[0] == "mv" and call[-1] == str(self.backup))
        importing = next(i for i, call in enumerate(calls) if call[0] == "import-identity")
        self.assertLess(publication, importing)
        self.assertNotIn("test-password", json.dumps(calls))
        self.assert_clean()

    def test_failed_backup_publication_leaves_no_partial_backup_and_can_retry(self):
        for failure in ("backup-export", "backup-copy", "backup-promote"):
            with self.subTest(failure=failure):
                self.reset_case()
                before = self.read_state()
                result = self.run_script(arguments=(), OILFIND_TEST_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.backup.exists())
                self.assertFalse(self.config.exists())
                self.assertEqual(self.read_state(), before)
                self.assertFalse(any(call[0] == "import-identity" for call in self.calls()))
                self.assert_clean()
                result = self.run_script(arguments=())
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_config()
                self.assert_clean()

    def test_failure_after_backup_retains_identity_and_recovery_does_not_regenerate(self):
        for failure in ("compile", "import", "identity-check", "config-promote"):
            with self.subTest(failure=failure):
                self.reset_case()
                before = self.read_state()
                result = self.run_script(arguments=(), OILFIND_TEST_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("security import", result.stderr)
                backup = self.backup.read_bytes()
                self.assertEqual(json.loads(backup), {"mock_encrypted_identity": FINGERPRINT})
                self.assertFalse(self.config.exists())
                if failure in ("compile", "import"):
                    self.assertEqual(self.read_state(), before)
                self.assert_clean()
                for arguments in ((), ("--local",)):
                    self.log.unlink(missing_ok=True)
                    retry = self.run_script(arguments=arguments)
                    if failure in ("compile", "import"):
                        self.assertNotEqual(retry.returncode, 0)
                        self.assertIn("security import", retry.stderr)
                    else:
                        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
                        self.assert_config()
                    self.assertEqual(self.backup.read_bytes(), backup)
                    self.assert_no_creation()
                    self.assert_clean()
                if failure in ("compile", "import"):
                    # Model the user restoring the retained identity, without a real import.
                    self.seed_identity()
                    restored = self.run_script()
                    self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
                    self.assert_config()
                    self.assert_no_creation()

    def test_configured_lowercase_identity_is_idempotent_and_reports_missing_backup(self):
        self.seed_identity()
        self.seed_config(FINGERPRINT.lower())
        config = self.config.read_bytes()
        state = self.read_state()
        for arguments in (("--local",), ()):
            result = self.run_script(arguments=arguments)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if not arguments:
                self.assertIn("no encrypted backup was created", result.stdout.lower())
            self.assertEqual(self.config.read_bytes(), config)
            self.assertEqual(self.read_state(), state)
            self.assertFalse(self.backup.exists())
            self.assert_no_creation()
            self.assert_clean()

    def test_reusing_identity_never_overwrites_backup_or_creates_new_keys(self):
        for existing_backup in (False, True):
            with self.subTest(existing_backup=existing_backup):
                self.reset_case()
                self.seed_identity()
                before = self.read_state()
                if existing_backup:
                    self.backup.parent.mkdir(parents=True, exist_ok=True)
                    self.backup.write_bytes(b"existing user backup")
                result = self.run_script(arguments=())
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_config()
                self.assertEqual(self.read_state(), before)
                if existing_backup:
                    self.assertEqual(self.backup.read_bytes(), b"existing user backup")
                    self.assertIn("not changed", result.stdout.lower())
                else:
                    self.assertFalse(self.backup.exists())
                    self.assertIn("no encrypted backup was created", result.stdout.lower())
                retry = self.run_script(arguments=())
                self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
                self.assertEqual(self.read_state(), before)
                if existing_backup:
                    self.assertEqual(self.backup.read_bytes(), b"existing user backup")
                else:
                    self.assertFalse(self.backup.exists())
                self.assert_no_creation()
                self.assert_clean()

    def test_invalid_existing_state_never_creates_replacement_or_removes_unsafe_work(self):
        protected = self.root / "protected data"
        protected.mkdir()
        sentinel = protected / "keep"
        sentinel.write_text("do not remove")
        for case in ("malformed config", "missing pinned identity", "multiple identities", "certificate only",
                     "security failure", "missing keychain", "work symlink", "work file"):
            with self.subTest(case=case):
                self.reset_case()
                environment = {}
                if case == "malformed config": self.config.write_bytes(b"not a plist")
                if case == "missing pinned identity": self.seed_config()
                if case == "multiple identities":
                    self.seed_identity()
                    self.seed_identity("F" * 40)
                if case == "certificate only":
                    state = self.read_state()
                    state["certificate_only"] = True
                    self.state.write_text(json.dumps(state))
                if case == "security failure": environment["OILFIND_TEST_FAIL"] = "security"
                if case == "missing keychain": environment["OILFIND_SIGNING_KEYCHAIN"] = str(self.root / "missing")
                if case == "work symlink": self.work.symlink_to(protected, target_is_directory=True)
                if case == "work file": self.work.write_text("unexpected file")
                previous_config = self.config.read_bytes() if self.config.exists() else None
                before = self.read_state()
                result = self.run_script(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.read_state(), before)
                self.assertEqual(self.config.read_bytes() if self.config.exists() else None, previous_config)
                self.assertEqual(sentinel.read_text(), "do not remove")
                self.assert_no_creation()
                if case == "work symlink":
                    self.assertTrue(self.work.is_symlink())
                    self.work.unlink()
                if case == "work file":
                    self.assertEqual(self.work.read_text(), "unexpected file")
                    self.work.unlink()
                self.assert_clean()

    def test_relative_keychain_with_spaces_is_saved_as_absolute_path(self):
        relative = self.keychain.relative_to(self.root)
        result = self.run_script(OILFIND_SIGNING_KEYCHAIN=str(relative))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_config()
        before = self.read_state()
        self.log.unlink(missing_ok=True)
        retry = self.run_script(OILFIND_SIGNING_KEYCHAIN=str(relative))
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual(self.read_state(), before)
        self.assert_no_creation()
        self.assert_clean()

    def start_held_configuration(self):
        process = subprocess.Popen(["/bin/bash", str(self.script), "--local"], cwd=self.root,
                                   env=dict(self.environment, OILFIND_TEST_HOLD_GENERATION="1"),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_held_configuration, process)
        deadline = time.monotonic() + 5
        while not (self.root / "generation-held").exists():
            if process.poll() is not None:
                stdout, stderr = process.communicate(timeout=2)
                self.fail("Configuration exited before taking the lock: " + stdout + stderr)
            if time.monotonic() >= deadline:
                self.fail("Timed out waiting for mock certificate generation")
            time.sleep(0.02)
        return process

    def stop_held_configuration(self, process):
        if process.poll() is None:
            process.kill()
        process.wait(timeout=2)
        process.communicate(timeout=3)

    def test_killed_lock_holder_releases_lock_and_retry_reclaims_private_work(self):
        process = self.start_held_configuration()
        self.assertTrue((self.work / "private.pem").exists())
        self.stop_held_configuration(process)
        self.assertTrue((self.work / "private.pem").exists())
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_config()
        self.assertEqual(sum(call[0] == "import-identity" for call in self.calls()), 1)
        self.assert_clean()

    def test_active_lock_holder_is_not_disrupted_by_second_configuration(self):
        process = self.start_held_configuration()
        before = {path.relative_to(self.work): path.read_bytes() for path in sorted(self.work.glob("*")) if path.is_file()}
        state = self.read_state()
        call_count = len(self.calls())
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("in progress", result.stderr.lower())
        self.assertIsNone(process.poll())
        self.assertEqual({path.relative_to(self.work): path.read_bytes() for path in sorted(self.work.glob("*")) if path.is_file()}, before)
        self.assertEqual(self.read_state(), state)
        self.assertFalse(self.config.exists())
        self.assertEqual(len(self.calls()), call_count)
        self.stop_held_configuration(process)


if __name__ == "__main__":
    unittest.main()
