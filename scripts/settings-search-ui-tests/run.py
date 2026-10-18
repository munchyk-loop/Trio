#!/usr/bin/env python3
"""Exercise the toolbar close button using Trio's actual search helpers."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile

fixture = Path(__file__).resolve().parent
repo = fixture.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--destination", help="iOS 26+ simulator UUID (defaults to an available modern iPhone)")
parser.add_argument("--app-bundle", type=Path, help="Current Debug simulator Trio.app; runs the full-app regression")
parser.add_argument("--prepare-only", action="store_true", help="Prepare the isolated Xcode project for testing in Xcode")
parser.add_argument("--cycles", type=int, default=3, help="Open/close cycles (default 3, maximum 15)")
parser.add_argument("--timeout", type=int, default=300, help="Maximum test duration in seconds (default 300)")
args = parser.parse_args()
if not 1 <= args.cycles <= 15:
    parser.error("--cycles must be between 1 and 15")
if args.timeout < 1:
    parser.error("--timeout must be positive")

if not args.destination:
    def simctl(*arguments):
        return json.loads(subprocess.check_output(["xcrun", "simctl", *arguments, "--json"], text=True))
    runtimes = simctl("list", "runtimes")["runtimes"]
    supported = {runtime["identifier"] for runtime in runtimes
                 if runtime.get("isAvailable") and runtime.get("platform") == "iOS"
                 and int(runtime["version"].split(".")[0]) >= 26}
    devices = simctl("list", "devices", "available")["devices"]
    candidates = [device for runtime, values in devices.items() if runtime in supported
                  for device in values if "iPhone" in device["name"]]
    if not candidates:
        parser.error("Install an iOS 26+ iPhone simulator runtime in Xcode first.")
    candidates.sort(key=lambda device: device["state"] != "Booted")
    args.destination = candidates[0]["udid"]

workspace = Path(tempfile.mkdtemp(prefix="trio-search-toolbar-"))
project = workspace / "SearchProbe.xcodeproj"
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True)
shutil.copyfile(fixture / "project.pbxproj", project / "project.pbxproj")
shutil.copyfile(fixture / "SearchProbe.xcscheme", schemes / "SearchProbe.xcscheme")
source = (repo / "Trio/Sources/Views/SettingsRedesign/SettingsFlowRootView.swift").read_text()
# Compile production helpers, rather than maintaining a duplicate implementation.
helpers = source[source.index("struct SettingsSearchSession:"):]
(workspace / "SearchProbe.swift").write_text((fixture / "ProbeApp.swift").read_text() + helpers)
if args.app_bundle:
    with (args.app_bundle / "Info.plist").open("rb") as info:
        bundle_id = plistlib.load(info)["CFBundleIdentifier"]
    if not args.prepare_only:
        subprocess.run(["xcrun", "simctl", "install", args.destination, str(args.app_bundle)], check=True)
    tests = (fixture / "FullTrioTests.swift").read_text().replace(
        '"__TRIO_TEST_BUNDLE_IDENTIFIER__"', json.dumps(bundle_id))
else:
    tests = (fixture / "ToolbarSearchTests.swift").read_text()
(workspace / "SearchProbeTests.swift").write_text(tests.replace("0 ..< 15", "0 ..< " + str(args.cycles)))
log = workspace / "test.log"
result = workspace / "TestResults.xcresult"
command = ["xcodebuild", "-project", str(project), "-scheme", "SearchProbe",
           "-destination", "platform=iOS Simulator,id=" + args.destination,
           "-derivedDataPath", str(workspace / "DerivedData"), "-resultBundlePath", str(result),
           "-parallel-testing-enabled", "NO", "-jobs", "1", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "test"]
if args.prepare_only:
    print(project, flush=True)
    raise SystemExit(0)
print("Testing toolbar close on simulator " + args.destination, flush=True)
print("Mode: " + ("full Trio app" if args.app_bundle else "isolated helper smoke test"), flush=True)
print("Log: " + str(log), flush=True)
with log.open("w") as output:
    process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        status = 124
        print("Stopped: test duration exceeded " + str(args.timeout) + " seconds.", flush=True)
print("PASSED" if status == 0 else "FAILED")
print("Log: " + str(log))
print("Results: " + str(result))
if status:
    print("\n".join(log.read_text().splitlines()[-35:]))
raise SystemExit(status)
