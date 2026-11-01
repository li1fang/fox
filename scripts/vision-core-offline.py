"""Bounded public XCTest projection; never a replacement for verify:public.

Stage on the source host, then transfer only the resulting bundle to Linux.
The bundle has no private fixture support, external dependencies or Apple targets.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time

CORE = Path("apps/ipad/FoxTrainingCore")
CLASSES = ("PoseStartGateTests", "PoseSessionTests", "MotionStrategyTests", "PoseTests", "LatPulldownTests")
PACKAGE = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FoxOfflinePublicCore", targets: [
    .target(name: "FoxTrainingCore", resources: [.process("Resources")]),
    .testTarget(name: "FoxTrainingCoreTests", dependencies: ["FoxTrainingCore"])
])
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def stage(root, destination, classes=CLASSES):
    root, destination = Path(root).resolve(), Path(destination).absolute()
    if not classes or len(set(classes)) != len(classes) or any(not re.fullmatch(r"\w+Tests", name) for name in classes):
        raise ValueError("Invalid or duplicate test classes")
    if destination.exists():
        raise FileExistsError(destination)
    catalogue_bytes = (root / "tests/verification/catalogue.json").read_bytes()
    catalogue = json.loads(catalogue_bytes)
    if catalogue["schema"] != "fox.test_catalogue.v1":
        raise ValueError("Unknown catalogue")
    rows = catalogue["tests"]
    by_id = {row["id"]: row for row in rows}
    if len(by_id) != len(rows):
        raise ValueError("Duplicate catalogue IDs")
    selected, payloads = [], {}
    for name in classes:
        relative = CORE / "Tests/FoxTrainingCoreTests" / f"{name}.swift"
        source = root / relative
        if source.is_symlink():
            raise ValueError("Unexpected symlink")
        data = source.read_bytes()
        dependencies = set(re.findall(r"\b(\w+Tests)\.", data.decode())) - set(classes)
        if dependencies:
            raise ValueError(f"Missing shared test dependency: {sorted(dependencies)}")
        methods = re.findall(r"\bfunc\s+(test\w+)\s*\(", data.decode())
        ids = [f"FoxTrainingCoreTests/{name}/{method}" for method in methods]
        registered = [row["id"] for row in rows if row["file"] == str(relative)]
        if not ids or len(ids) != len(set(ids)) or sorted(ids) != sorted(registered):
            raise ValueError(f"Unclassified or missing test in {relative}")
        for test_id in ids:
            if by_id[test_id]["scope"] != "public" or by_id[test_id]["surface"] != "host":
                raise ValueError(f"Non-public host test: {test_id}")
            for fixture_name in by_id[test_id].get("fixtures", []):
                fixture = Path(fixture_name)
                base = CORE / "Tests/FoxTrainingCoreTests/Fixtures"
                if fixture.is_absolute() or '..' in fixture.parts or not fixture.is_relative_to(base):
                    raise ValueError("Invalid public test fixture")
                if any((root / Path(*fixture.parts[:i])).is_symlink() for i in range(1, len(fixture.parts)+1)):
                    raise ValueError("Unexpected fixture symlink")
                file = root / fixture
                if not file.is_file() or file.stat().st_size > 1024*1024:
                    raise ValueError("Missing or oversized public fixture")
                payloads[str(fixture.relative_to(CORE))] = file.read_bytes()
        selected.extend(ids)
        payloads[str(relative.relative_to(CORE))] = data
    source_dir = root / CORE / "Sources/FoxTrainingCore"
    for source in sorted(source_dir.rglob("*")):
        if source.is_symlink():
            raise ValueError(f"Unexpected symlink: {source}")
        if source.is_file():
            payloads[str(source.relative_to(root / CORE))] = source.read_bytes()
    if not any(name.endswith(".swift") and name.startswith("Sources/") for name in payloads):
        raise ValueError("No core sources")
    payloads["Package.swift"] = PACKAGE.encode()
    payloads["driver.py"] = Path(__file__).read_bytes()
    manifest = dict(schema="fox.offline_core_bundle.v1", scope="public-core-subset",
                    catalogueSHA256=digest(catalogue_bytes), expectedTests=selected,
                    excludedTests=[dict(id=row["id"], scope=row["scope"], reason="Outside explicit offline subset")
                                   for row in rows if row["id"] not in selected],
                    files=[dict(path=name, sha256=digest(data)) for name, data in sorted(payloads.items())])
    # Exclusive directory creation prevents overwriting any prior attempt or source.
    destination.mkdir(parents=True, exist_ok=False)
    for name, data in payloads.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    save(destination / "manifest.json", manifest)
    return manifest


def verify_bundle(bundle):
    manifest = json.loads((bundle / "manifest.json").read_text())
    if manifest["schema"] != "fox.offline_core_bundle.v1" or not manifest["expectedTests"]:
        raise ValueError("Invalid manifest")
    if {p.name for p in bundle.glob("Package*.swift")} != {"Package.swift"}:
        raise ValueError("Unexpected SwiftPM manifest inventory")
    paths = [row["path"] for row in manifest["files"]]
    if len(paths) != len(set(paths)) or not {"Package.swift", "driver.py"}.issubset(paths):
        raise ValueError("Missing required build descriptor or duplicate manifest path")
    for row in manifest["files"]:
        target = bundle / row["path"]
        if target.is_symlink() or bundle.resolve() not in target.resolve().parents:
            raise ValueError("Unsafe manifest path")
        if digest(target.read_bytes()) != row["sha256"]:
            raise ValueError(f"Source digest mismatch: {row['path']}")
    expected = {row["path"] for row in manifest["files"]}
    actual = {str(p.relative_to(bundle)) for folder in ("Sources", "Tests") for p in (bundle / folder).rglob("*") if p.is_file()}
    if actual != {name for name in expected if name.startswith(("Sources/", "Tests/"))}:
        raise ValueError("Source inventory mismatch")
    return manifest


def audit(output, expected):
    pattern = r"^Test Case '(?:-\[([\w.]+) (\w+)\]|([\w.]+))' (passed|skipped|failed) "
    rows = []
    for match in re.finditer(pattern, output, re.M):
        parts = match[1].split(".") + [match[2]] if match[1] else match[3].split(".")
        rows.append(("/".join(parts[-2:]), match[4]))
    wanted = sorted("/".join(test.split("/")[-2:]) for test in expected)
    if not rows or any(state != "passed" for _, state in rows) or sorted(name for name, _ in rows) != wanted:
        raise ValueError("XCTest coverage missing, duplicate, unexpected, failed or skipped")
    return sorted(name for name, _ in rows)


def settle_group(group, timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        rows = subprocess.check_output(["ps", "-axo", "pgid=,stat="], text=True, timeout=3).splitlines()
        live = [row for row in rows if row.split() and row.split()[0] == str(group) and not row.split()[1].startswith("Z")]
        if not live:
            return
        try: os.killpg(group, signal.SIGKILL)
        except ProcessLookupError: pass
        if time.monotonic() >= deadline:
            raise RuntimeError("Process-group cleanup unconfirmed; retain receipt and inspect worker")
        time.sleep(0.025)


def run(bundle, receipt_dir, swift="swift", jobs=2, timeout=600):
    bundle, receipt_dir = Path(bundle).resolve(), Path(receipt_dir).absolute()
    receipt_dir.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    receipt = dict(schema="fox.offline_core_receipt.v1", status="running", scope="public-core-subset",
                   platform=platform.system(), architecture=platform.machine(), deviceVerified=False,
                   nativeUIVerified=False, jobs=jobs, testsExecuted=0, firstFailureStage=None)
    save(receipt_dir / "receipt.json", receipt)
    def cancelled(signum, _frame):
        raise KeyboardInterrupt(f"Cancelled by signal {signum}")
    previous_handler = signal.signal(signal.SIGTERM, cancelled)
    phase = "platform-admission"
    try:
        if platform.system() == "Darwin":
            raise ValueError("Mac native runs require verify:workstream vision/client resource admission; standalone run is Linux-only")
        phase = "source-integrity"
        manifest = verify_bundle(bundle)
        receipt["manifestSHA256"] = digest((bundle / "manifest.json").read_bytes())
        receipt["expectedTests"] = manifest["expectedTests"]
        receipt["excludedTests"] = manifest["excludedTests"]
        phase = "toolchain"
        receipt["swiftVersion"] = subprocess.check_output([swift, "--version"], text=True, timeout=30).strip()
        phase = "compile-and-test"
        command = [swift, "test", "--package-path", str(bundle), "--scratch-path", str(receipt_dir / "build"), "--jobs", str(jobs)]
        receipt["command"] = command
        env = {k: v for k, v in os.environ.items() if not k.startswith(("FOX_PRIVATE", "FOX_GUIDANCE", "FOX_R2", "FOX_M3"))}
        with (receipt_dir / "swift-test.log").open("x") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            finally:
                # Also clean descendants after a nonzero exit, not only timeout.
                try: os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: process.wait(timeout=1)
                except subprocess.TimeoutExpired: pass
                # The group leader may have exited while compiler descendants
                # remain alive. Always clean the group, not just its leader.
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                process.wait(timeout=5)
                settle_group(process.pid)
        output = (receipt_dir / "swift-test.log").read_text()
        receipt["exitCode"] = code
        receipt["testsExecuted"] = len(re.findall(r"^Test Case .+ (?:passed|failed|skipped) ", output, re.M))
        if code != 0:
            raise ValueError(f"swift test exited {code}; see retained log")
        phase = "coverage-audit"
        receipt["passedTests"] = audit(output, manifest["expectedTests"])
        phase = "source-integrity-after-run"
        verify_bundle(bundle)
        if receipt["manifestSHA256"] != digest((bundle / "manifest.json").read_bytes()):
            raise ValueError("Manifest changed during execution")
        receipt["status"] = "public_core_subset_passed"
    except BaseException as error:
        receipt.update(status="cancelled" if isinstance(error, KeyboardInterrupt) else "failed",
                       firstFailureStage=phase, error=f"{type(error).__name__}: {error}")
    finally:
        log = receipt_dir / "swift-test.log"
        if log.exists():
            output = log.read_text(errors="replace")
            receipt["testsExecuted"] = len(re.findall(r"^Test Case .+ (?:passed|failed|skipped) ", output, re.M))
            receipt["testLogSHA256"] = digest(log.read_bytes())
        receipt["elapsedSeconds"] = round(time.monotonic() - started, 3)
        save(receipt_dir / "receipt.json", receipt)
        signal.signal(signal.SIGTERM, previous_handler)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    staging = sub.add_parser("stage")
    staging.add_argument("destination", type=Path)
    staging.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    staging.add_argument("--class", dest="classes", action="append")
    checking = sub.add_parser("check")
    checking.add_argument("bundle", type=Path)
    running = sub.add_parser("run")
    running.add_argument("bundle", type=Path)
    running.add_argument("receipt_dir", type=Path)
    running.add_argument("--swift", default="swift")
    running.add_argument("--jobs", type=int, choices=range(1, 5), default=2)
    running.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if args.action == "stage":
        result = stage(args.root, args.destination, classes=args.classes or CLASSES)
        print(json.dumps(dict(bundle=str(args.destination), selectedTests=len(result["expectedTests"]))))
        return 0
    if args.action == "check":
        result = verify_bundle(args.bundle)
        print(json.dumps(dict(status="bundle_verified", selectedTests=len(result["expectedTests"]))))
        return 0
    result = run(args.bundle, args.receipt_dir, args.swift, args.jobs, args.timeout)
    print(json.dumps({k: result.get(k) for k in ("status", "testsExecuted", "elapsedSeconds", "firstFailureStage", "error")}))
    return 0 if result["status"] == "public_core_subset_passed" else 1


if __name__ == "__main__":
    sys.exit(main())
