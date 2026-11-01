import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("offline", ROOT / "scripts/vision-core-offline.py")
offline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(offline)


class OfflineCoreTests(unittest.TestCase):
    def test_declared_public_fixture_is_staged_and_escaping_fixture_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root,out=Path(tmp)/"source",Path(tmp)/"bundle"
            catalogue,rows=self.fixture(root)
            relative=offline.CORE/"Tests/FoxTrainingCoreTests/Fixtures/oracle.json"
            fixture=root/relative;fixture.parent.mkdir();fixture.write_text('{"synthetic":true}')
            rows[0]['fixtures']=[str(relative)]
            catalogue.write_text(json.dumps(dict(schema='fox.test_catalogue.v1',tests=rows)))
            offline.stage(root,out,classes=(offline.CLASSES[0],))
            self.assertEqual((out/relative.relative_to(offline.CORE)).read_bytes(),fixture.read_bytes())
            rows[0]['fixtures']=['../private.json']
            catalogue.write_text(json.dumps(dict(schema='fox.test_catalogue.v1',tests=rows)))
            with self.assertRaises(ValueError):offline.stage(root,Path(tmp)/'invalid',classes=(offline.CLASSES[0],))
    def test_macos_standalone_runner_refuses_to_bypass_native_admission(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out, receipt = Path(tmp) / "source", Path(tmp) / "bundle", Path(tmp) / "run"
            self.fixture(root)
            offline.stage(root, out)
            with patch.object(offline.platform, "system", return_value="Darwin"), patch.object(offline.subprocess, "check_output") as command, patch.object(offline.subprocess, "Popen", side_effect=AssertionError("Native compiler forbidden in fixture")):
                result = offline.run(out, receipt)
                command.assert_not_called()
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["firstFailureStage"], "platform-admission")
            self.assertEqual(result["testsExecuted"], 0)

    def test_required_build_descriptors_cannot_be_removed_from_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "source", Path(tmp) / "bundle"
            self.fixture(root)
            manifest = offline.stage(root, out)
            manifest["files"] = [r for r in manifest["files"] if r["path"] != "Package.swift"]
            (out / "manifest.json").write_text(json.dumps(manifest))
            (out / "Package.swift").write_text("changed build rules")
            with self.assertRaisesRegex(ValueError, "required|descriptor"):
                offline.verify_bundle(out)

    def test_explicit_client_projection_uses_the_same_source_without_private_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "source", Path(tmp) / "bundle"
            self.fixture(root)
            selected = (offline.CLASSES[0],)
            manifest = offline.stage(root, out, classes=selected)
            self.assertEqual(len(manifest["expectedTests"]), 1)
            self.assertEqual(len(list((out / "Tests/FoxTrainingCoreTests").glob("*.swift"))), 1)
            self.assertEqual((out / "Sources/FoxTrainingCore/Core.swift").read_bytes(), b"import Foundation\n")
            self.assertNotIn("FoxTestSupport", (out / "Package.swift").read_text())
            for classes in ((), ("../escape",), (selected[0], selected[0])):
                with self.assertRaises(ValueError):
                    offline.stage(root, Path(tmp) / "invalid", classes=classes)

    def fixture(self, root):
        core = root / offline.CORE
        (core / "Sources/FoxTrainingCore/Resources").mkdir(parents=True)
        (core / "Sources/FoxTrainingCore/Core.swift").write_text("import Foundation\n")
        (core / "Sources/FoxTrainingCore/Resources/default.json").write_text("{}")
        tests = core / "Tests/FoxTrainingCoreTests"
        tests.mkdir(parents=True)
        rows = []
        for name in offline.CLASSES:
            file = tests / f"{name}.swift"
            file.write_text(f"import XCTest\nfinal class {name}: XCTestCase {{ func testPublic() {{}} }}\n")
            rows.append(dict(id=f"FoxTrainingCoreTests/{name}/testPublic", file=str(file.relative_to(root)), scope="public", surface="host"))
        catalogue = root / "tests/verification/catalogue.json"
        catalogue.parent.mkdir(parents=True)
        catalogue.write_text(json.dumps(dict(schema="fox.test_catalogue.v1", tests=rows)))
        return catalogue, rows

    def test_stage_copies_bytes_and_lists_exact_public_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "source"
            self.fixture(root)
            out = Path(tmp) / "bundle"
            manifest = offline.stage(root, out)
            self.assertEqual(len(manifest["expectedTests"]), len(offline.CLASSES))
            self.assertEqual((out / "Sources/FoxTrainingCore/Core.swift").read_bytes(), b"import Foundation\n")
            self.assertEqual(offline.verify_bundle(out), manifest)
            (out / "Sources/FoxTrainingCore/Core.swift").write_text("changed")
            with self.assertRaisesRegex(ValueError, "digest"):
                offline.verify_bundle(out)

    def test_private_or_unclassified_tests_fail_before_staging(self):
        for mode in ("private", "missing", "duplicate"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root, out = Path(tmp) / "source", Path(tmp) / "bundle"
                catalogue, rows = self.fixture(root)
                if mode == "private": rows[0]["scope"] = "private"
                elif mode == "missing": rows.pop()
                else: rows.append(rows[0])
                catalogue.write_text(json.dumps(dict(schema="fox.test_catalogue.v1", tests=rows)))
                with self.assertRaises(ValueError): offline.stage(root, out)
                self.assertFalse(out.exists())

    def test_existing_output_and_symlink_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "source", Path(tmp) / "bundle"
            self.fixture(root)
            out.mkdir()
            with self.assertRaises(FileExistsError): offline.stage(root, out)
            link = root / offline.CORE / "Sources/FoxTrainingCore/leak.swift"
            link.symlink_to("Core.swift")
            with self.assertRaisesRegex(ValueError, "symlink"):
                offline.stage(root, Path(tmp) / "fresh")

    def test_audit_requires_exactly_once_pass_without_skips(self):
        expected = ["FoxTrainingCoreTests/A/testOne", "FoxTrainingCoreTests/A/testTwo"]
        good = "Test Case 'A.testOne' passed (0.0 seconds).\nTest Case '-[Module.A testTwo]' passed (0.0 seconds).\n"
        self.assertEqual(offline.audit(good, expected), ["A/testOne", "A/testTwo"])
        for bad in ("", good.splitlines()[0], good + good, good.replace("passed", "skipped", 1), good.replace("testTwo", "testOther")):
            with self.subTest(log=bad), self.assertRaises(ValueError): offline.audit(bad, expected)

    def test_failure_retains_receipt_and_never_overwrites_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out, receipt = Path(tmp) / "source", Path(tmp) / "bundle", Path(tmp) / "run"
            self.fixture(root)
            offline.stage(root, out)
            with patch.object(offline.platform, "system", return_value="Linux"), patch.object(offline.subprocess, "check_output", side_effect=FileNotFoundError("missing Swift")):
                result = offline.run(out, receipt)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["firstFailureStage"], "toolchain")
            self.assertEqual(result["testsExecuted"], 0)
            before = (receipt / "receipt.json").read_bytes()
            with self.assertRaises(FileExistsError): offline.run(out, receipt)
            self.assertEqual((receipt / "receipt.json").read_bytes(), before)

    def test_added_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "source", Path(tmp) / "bundle"
            self.fixture(root)
            offline.stage(root, out)
            (out / "Tests/FoxTrainingCoreTests/Extra.swift").write_text("import XCTest")
            with self.assertRaisesRegex(ValueError, "inventory"):
                offline.verify_bundle(out)

    def test_missing_shared_test_helper_is_reported_before_compilation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "source", Path(tmp) / "bundle"
            self.fixture(root)
            file = root / offline.CORE / "Tests/FoxTrainingCoreTests/PoseTests.swift"
            file.write_text(file.read_text() + "\nlet helper = MissingTests.frame()\n")
            with self.assertRaisesRegex(ValueError, "test dependency"):
                offline.stage(root, out)

    def test_version_specific_manifest_cannot_change_the_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "source", Path(tmp) / "bundle"
            self.fixture(root)
            offline.stage(root, out)
            (out / "Package@swift-6.2.swift").write_text("// changed manifest")
            with self.assertRaisesRegex(ValueError, "manifest inventory"):
                offline.verify_bundle(out)

    def test_sigterm_stops_child_and_preserves_partial_execution_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out, receipt = Path(tmp) / "source", Path(tmp) / "bundle", Path(tmp) / "run"
            self.fixture(root)
            offline.stage(root, out)
            fake = Path(tmp) / "swift"
            pidfile = Path(tmp) / "child.pid"
            grandchild_pidfile = Path(tmp) / "grandchild.pid"
            grandchild_code = f"import os,signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path({str(grandchild_pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)"
            fake.write_text(f'''#!{sys.executable}
import os, sys, time, subprocess
from pathlib import Path
if "--version" in sys.argv:
    print("fake Swift for cancellation regression")
else:
    Path({str(pidfile)!r}).write_text(str(os.getpid()))
    subprocess.Popen([sys.executable, "-c", {grandchild_code!r}])
    while not Path({str(grandchild_pidfile)!r}).exists(): time.sleep(0.01)
    print("Test Case 'PoseTests.testPublic' passed (0.0 seconds).", flush=True)
    time.sleep(60)
''')
            fake.chmod(0o700)
            # Test only: exercise the Linux runner with a fake compiler on every
            # host, without adding a production bypass for Mac resource admission.
            launcher = f"import runpy,platform,sys; platform.system=lambda:'Linux'; sys.argv={['driver.py', 'run', str(out), str(receipt), '--swift', str(fake)]!r}; runpy.run_path({str(ROOT / 'scripts/vision-core-offline.py')!r},run_name='__main__')"
            child = subprocess.Popen([sys.executable, "-c", launcher], stdout=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    log = receipt / "swift-test.log"
                    if log.exists() and "passed" in log.read_text(): break
                    time.sleep(0.02)
                else: self.fail("Fake compiler did not start")
                child.terminate()
                self.assertEqual(child.wait(timeout=5), 1)
                result = json.loads((receipt / "receipt.json").read_text())
                self.assertEqual(result["status"], "cancelled")
                self.assertEqual(result["testsExecuted"], 1)
                with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()), 0)
                descendant = int(grandchild_pidfile.read_text())
                # An orphan may briefly be a zombie until the host init reaps it;
                # it must no longer execute or hold build resources.
                state = subprocess.run(["ps", "-o", "stat=", "-p", str(descendant)], capture_output=True, text=True).stdout.strip()
                self.assertTrue(not state or state.startswith("Z"), state)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
                if pidfile.exists():
                    try: os.kill(int(pidfile.read_text()), 9)
                    except ProcessLookupError: pass
                if grandchild_pidfile.exists():
                    try: os.kill(int(grandchild_pidfile.read_text()), 9)
                    except ProcessLookupError: pass

    def test_nonzero_compiler_exit_cleans_live_child_and_retains_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, out, receipt = Path(tmp) / "source", Path(tmp) / "bundle", Path(tmp) / "run"
            self.fixture(root)
            offline.stage(root, out)
            pidfile, fake = Path(tmp) / "child.pid", Path(tmp) / "fake-swift"
            child_code = f"import os,time; from pathlib import Path; Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)"
            fake.write_text(f'''#!{sys.executable}
import subprocess,sys,time
from pathlib import Path
if "--version" in sys.argv: print("fake Swift")
else:
    subprocess.Popen([sys.executable, "-c", {child_code!r}], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    while not Path({str(pidfile)!r}).exists(): time.sleep(0.01)
    sys.exit(3)
''')
            fake.chmod(0o700)
            try:
                with patch.object(offline.platform, "system", return_value="Linux"):
                    result = offline.run(out, receipt, swift=str(fake), timeout=3)
                self.assertEqual(result["status"], "failed")
                self.assertEqual(result["exitCode"], 3)
                state = subprocess.run(["ps", "-o", "stat=", "-p", pidfile.read_text()], capture_output=True, text=True).stdout.strip()
                self.assertTrue(not state or state.startswith("Z"), state)
            finally:
                if pidfile.exists():
                    try: os.kill(int(pidfile.read_text()), 9)
                    except ProcessLookupError: pass


if __name__ == "__main__":
    unittest.main()
