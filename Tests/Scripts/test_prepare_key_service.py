import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
FINGERPRINT = "0123456789ABCDEF0123456789ABCDEF01234567"
IDENTIFIER = "com.oiloil.find.clipboard-key-service"


class PrepareKeyServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="oilfind-key-service-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "Test Home"
        self.home.mkdir()
        self.signing = self.home / "Local Signing"
        self.signing.mkdir()
        self.keychain = self.signing / "mock keychain.keychain-db"
        self.keychain.write_bytes(b"untouched mock keychain")
        self.cache = self.signing / "clipboard-key-service"
        self.service = self.cache / "OilFindClipboardKeyService.xpc"
        self.executable = self.service / "Contents/MacOS/OilFindClipboardKeyService"
        self.manifest = self.cache / "manifest.plist"
        self.receipt = self.signing / "key-service-identity.plist"
        self.log = self.root / "calls.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = {
            "HOME": str(self.home),
            "PATH": str(self.bin) + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "OILFIND_LOCAL_SIGNING_CONFIG": str(self.signing / "unused-test-config.plist"),
            "OILFIND_TEST_LOG": str(self.log),
        }
        project = self.root / "project"
        self.script = project / "scripts/prepare-key-service.sh"
        self.script.parent.mkdir(parents=True)
        self.shared_source = project / "Sources/OilFindApp/ClipboardKeyAccess.swift"
        self.shared_source.parent.mkdir(parents=True)
        self.helper_source = project / "scripts/clipboard-key-service.swift"
        self.sources = (self.shared_source, self.helper_source)
        for path in self.sources:
            shutil.copyfile(PROJECT / path.relative_to(project), path)
        self.original_sources = {path: path.read_bytes() for path in self.sources}
        stub = self.bin / "stub"
        stub.write_text(f"#!{sys.executable}\n" + r'''
import hashlib, json, os, plistlib, re, signal, sys
from pathlib import Path

name, args = Path(sys.argv[0]).name, sys.argv[1:]
failure = os.environ.get("OILFIND_TEST_FAIL", "")
with open(os.environ["OILFIND_TEST_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")

def argument(flag):
    return args[args.index(flag) + 1]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if name == "xcrun":
    if not args or args[0] != "swiftc": sys.exit(70)
    output = Path(argument("-o"))
    output.write_bytes(b"mock compiled key service\n")
    output.chmod(0o755)
    if failure == "compile": sys.exit(1)
    if failure == "interrupt": os.kill(os.getppid(), signal.SIGTERM)
elif name == "strip":
    if failure == "strip": sys.exit(1)
elif name == "codesign":
    service = Path(args[-1])
    executable = service / "Contents/MacOS/OilFindClipboardKeyService"
    info = service / "Contents/Info.plist"
    signature = service / ".stub-signature.json"
    if "--force" in args:
        if failure == "sign": sys.exit(1)
        signature.write_text(json.dumps({
            "certificate": argument("--sign"), "identifier": argument("--identifier"),
            "executable": digest(executable), "info": digest(info),
        }))
    elif "--verify" in args:
        if failure == "verify": sys.exit(1)
        try:
            signed = json.loads(signature.read_text())
            requirement = argument("--test-requirement")
            match = re.search(r'certificate leaf = H"([0-9A-F]{40})"', requirement)
            valid = (
                match is not None and match.group(1) == signed["certificate"]
                and f'identifier "{signed["identifier"]}"' in requirement
                and signed["executable"] == digest(executable)
                and signed["info"] == digest(info)
            )
            sys.exit(0 if valid else 1)
        except (OSError, ValueError, KeyError):
            sys.exit(1)
    else:
        sys.exit(71)
elif name == "plutil":
    path = Path(args[-1])
    if failure == "manifest" and path.name == "manifest.plist": sys.exit(1)
    if args[0] == "-create":
        value = {}
    elif args[0] == "-insert":
        value = plistlib.loads(path.read_bytes())
        value[args[1]] = args[3]
    else:
        sys.exit(72)
    path.write_bytes(plistlib.dumps(value))
elif name == "PlistBuddy":
    try:
        value = plistlib.loads(Path(args[-1]).read_bytes())
        for field in argument("-c").split(":", 1)[1].split(":"):
            value = value[field]
        print(("true" if value else "false") if isinstance(value, bool) else value)
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        sys.exit(1)
elif name == "mv":
    if failure == "promote": sys.exit(1)
    if failure == "receipt" and Path(args[-1]).name == "key-service-identity.plist": sys.exit(1)
    os.replace(args[-2], args[-1])
else:
    # Unexpected tools never fall through to real builds or keychain operations.
    sys.exit(73)
''')
        stub.chmod(0o755)
        for name in ("xcrun", "strip", "codesign", "plutil", "PlistBuddy", "mv", "security", "swift", "swiftc"):
            (self.bin / name).symlink_to(stub)
        source = (PROJECT / "scripts/prepare-key-service.sh").read_text()
        # Keep real lockf and hashing; rewrite dangerous tools only in this copy.
        for name in ("xcrun", "codesign", "security", "swift", "swiftc", "plutil", "strip"):
            source = source.replace("/usr/bin/" + name, str(self.bin / name))
        source = source.replace("/usr/libexec/PlistBuddy", str(self.bin / "PlistBuddy"))
        self.script.write_text(source)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def run_script(self, arguments=None, **environment):
        if arguments is None:
            arguments = (FINGERPRINT, self.keychain, self.signing)
        result = subprocess.run(["/bin/bash", str(self.script), *map(str, arguments)], cwd=self.root,
                                env=dict(self.environment, **environment), capture_output=True, text=True, timeout=15)
        self.assertEqual(self.keychain.read_bytes(), b"untouched mock keychain")
        self.assertFalse(any(call[0] in ("security", "swift", "swiftc") for call in self.calls()))
        return result

    def cache_snapshot(self):
        return {str(path.relative_to(self.cache)): (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
                for path in sorted(self.cache.glob("**/*")) if path.is_file()}

    def assert_no_stage(self):
        self.assertEqual(sorted(self.signing.glob(".key-service-stage.*")), [])
        self.assertEqual(sorted(self.signing.glob(".key-service-identity.*")), [])

    def assert_no_build_or_sign(self):
        self.assertFalse(any(call[0] == "xcrun" or call[:2] == ["codesign", "--force"] for call in self.calls()))

    def create_cache(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.service))
        self.assertEqual(self.receipt.read_bytes(), self.manifest.read_bytes())
        self.assert_no_stage()

    def reset_case(self):
        if self.cache.exists():
            shutil.rmtree(self.cache)
        self.receipt.unlink(missing_ok=True)
        for source, contents in self.original_sources.items():
            source.write_bytes(contents)
        self.log.unlink(missing_ok=True)

    def test_cold_creation_publishes_signed_service_and_matching_manifest(self):
        self.create_cache()
        manifest = plistlib.loads(self.manifest.read_bytes())
        self.assertEqual(manifest["certificateSHA1"], FINGERPRINT)
        self.assertEqual(manifest["executableSHA256"], hashlib.sha256(self.executable.read_bytes()).hexdigest())
        source_hashes = "".join(hashlib.sha256(path.read_bytes()).hexdigest() + "\n" for path in self.sources)
        self.assertEqual(manifest["sourceSHA256"], hashlib.sha256(source_hashes.encode()).hexdigest())
        info = plistlib.loads((self.service / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], IDENTIFIER)
        self.assertEqual(info["OilFindKeyServiceSourceSHA256"], manifest["sourceSHA256"])
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.manifest.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.receipt.stat().st_mode), 0o600)
        calls = self.calls()
        self.assertEqual(sum(call[0] == "xcrun" for call in calls), 1)
        self.assertEqual(sum(call[:2] == ["codesign", "--force"] for call in calls), 1)
        verification = next(i for i, call in enumerate(calls) if call[:2] == ["codesign", "--verify"])
        publication = next(i for i, call in enumerate(calls) if call[0] == "mv")
        self.assertLess(verification, publication)
        receipt_publication = next(i for i, call in enumerate(calls)
                                   if call[0] == "mv" and call[-1] == str(self.receipt))
        self.assertLess(publication, receipt_publication)
        receipt_stage = Path(calls[receipt_publication][-2])
        self.assertEqual(receipt_stage.parent, self.signing)
        self.assertNotEqual(receipt_stage, self.receipt)
        self.assertNotEqual(receipt_stage, self.manifest)

    def test_hot_reuse_preserves_bytes_without_compiling_or_resigning(self):
        for missing_receipt in (False, True):
            with self.subTest(missing_receipt=missing_receipt):
                self.reset_case()
                self.create_cache()
                previous = self.cache_snapshot()
                pinned_bytes = self.receipt.read_bytes()
                if missing_receipt:
                    self.receipt.unlink()
                self.log.unlink()
                result = self.run_script(arguments=(FINGERPRINT.lower(), self.keychain, self.signing))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), str(self.service))
                self.assertEqual(self.cache_snapshot(), previous)
                self.assertEqual(self.receipt.read_bytes(), pinned_bytes)
                self.assert_no_build_or_sign()
                calls = self.calls()
                verification = next(i for i, call in enumerate(calls) if call[:2] == ["codesign", "--verify"])
                receipt_publications = [i for i, call in enumerate(calls)
                                        if call[0] == "mv" and call[-1] == str(self.receipt)]
                if missing_receipt:
                    self.assertEqual(len(receipt_publications), 1)
                    self.assertLess(verification, receipt_publications[0])
                else:
                    self.assertEqual(receipt_publications, [])
                self.assert_no_stage()

    def test_changed_or_invalid_cache_fails_without_rebuilding_or_replacing_it(self):
        for case in ("shared source", "helper source", "certificate", "executable", "manifest hash",
                     "signature", "missing manifest", "malformed manifest", "sealed info",
                     "session false", "session missing", "receipt malformed", "receipt reserialized",
                     "missing cache", "legacy signature", "legacy source", "legacy session",
                     "receipt publication"):
            with self.subTest(case=case):
                self.reset_case()
                self.create_cache()
                arguments = None
                environment = {}
                if case == "shared source": self.shared_source.write_bytes(self.shared_source.read_bytes() + b"\n// changed\n")
                if case == "helper source": self.helper_source.write_bytes(self.helper_source.read_bytes() + b"\n// changed\n")
                if case == "certificate": arguments = ("F" * 40, self.keychain, self.signing)
                if case == "executable": self.executable.write_bytes(b"tampered executable")
                if case == "manifest hash":
                    manifest = plistlib.loads(self.manifest.read_bytes())
                    manifest["executableSHA256"] = "F" * 64
                    self.manifest.write_bytes(plistlib.dumps(manifest))
                if case == "signature": environment["OILFIND_TEST_FAIL"] = "verify"
                if case in ("legacy signature", "legacy source", "legacy session", "receipt publication"):
                    self.receipt.unlink()
                    if case == "legacy signature": environment["OILFIND_TEST_FAIL"] = "verify"
                    if case == "legacy source": self.shared_source.write_bytes(self.shared_source.read_bytes() + b"\n// changed\n")
                    if case == "receipt publication": environment["OILFIND_TEST_FAIL"] = "receipt"
                if case == "receipt malformed": self.receipt.write_bytes(b"not a plist")
                if case == "receipt reserialized":
                    self.receipt.write_bytes(plistlib.dumps(plistlib.loads(self.manifest.read_bytes()),
                                                           fmt=plistlib.FMT_BINARY))
                    self.assertEqual(plistlib.loads(self.receipt.read_bytes()), plistlib.loads(self.manifest.read_bytes()))
                    self.assertNotEqual(self.receipt.read_bytes(), self.manifest.read_bytes())
                if case == "missing cache": shutil.rmtree(self.cache)
                if case == "missing manifest": self.manifest.unlink()
                if case == "malformed manifest": self.manifest.write_bytes(b"not a plist")
                if case == "sealed info":
                    info_path = self.service / "Contents/Info.plist"
                    info = plistlib.loads(info_path.read_bytes())
                    info["CFBundleIdentifier"] = "wrong.identifier"
                    info_path.write_bytes(plistlib.dumps(info))
                if case in ("session false", "session missing", "legacy session"):
                    info_path = self.service / "Contents/Info.plist"
                    info = plistlib.loads(info_path.read_bytes())
                    if case in ("session false", "legacy session"):
                        info["XPCService"]["JoinExistingSession"] = False
                    else:
                        info["XPCService"].pop("JoinExistingSession")
                    info_path.write_bytes(plistlib.dumps(info))
                    # Model a validly signed legacy cache, so signature rejection
                    # cannot hide a missing session check.
                    signature_path = self.service / ".stub-signature.json"
                    signature = json.loads(signature_path.read_text())
                    signature["info"] = hashlib.sha256(info_path.read_bytes()).hexdigest()
                    signature_path.write_text(json.dumps(signature))
                previous = self.cache_snapshot()
                previous_receipt = self.receipt.read_bytes() if self.receipt.exists() else None
                self.log.unlink()
                result = self.run_script(arguments=arguments, **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(str(self.service), result.stdout)
                self.assertEqual(self.cache_snapshot(), previous)
                self.assertEqual(self.receipt.read_bytes() if self.receipt.exists() else None, previous_receipt)
                if case == "missing cache": self.assertFalse(self.cache.exists())
                self.assert_no_build_or_sign()
                self.assert_no_stage()
                if case == "receipt publication":
                    self.log.unlink()
                    self.create_cache()
                    self.assertEqual(self.cache_snapshot(), previous)
                    self.assert_no_build_or_sign()

    def test_cold_failures_and_interruption_clean_stage_and_allow_retry(self):
        for failure in ("compile", "strip", "sign", "verify", "manifest", "promote", "interrupt"):
            with self.subTest(failure=failure):
                self.reset_case()
                result = self.run_script(OILFIND_TEST_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.cache.exists())
                self.assert_no_stage()
                self.create_cache()

    def test_concurrent_lock_blocks_cold_and_hot_work_without_disturbing_cache(self):
        lock_path = self.signing / ".key-service.lock"
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("in progress", result.stderr.lower())
            self.assertEqual(self.calls(), [])
            self.assertFalse(self.cache.exists())
            self.assert_no_stage()
        self.create_cache()
        previous = self.cache_snapshot()
        self.log.unlink()
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), [])
            self.assertEqual(self.cache_snapshot(), previous)
            self.assert_no_stage()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.cache_snapshot(), previous)
        self.assert_no_build_or_sign()

    def test_invalid_inputs_fail_before_cache_or_tool_access(self):
        for arguments in ((), (FINGERPRINT, self.keychain),
                          ("A" * 39, self.keychain, self.signing), ("G" * 40, self.keychain, self.signing),
                          (FINGERPRINT, self.signing / "missing keychain", self.signing),
                          (FINGERPRINT, self.keychain, self.root / "missing signing directory")):
            with self.subTest(arguments=arguments):
                result = self.run_script(arguments=arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.cache.exists())
                self.assert_no_stage()


if __name__ == "__main__":
    unittest.main()
