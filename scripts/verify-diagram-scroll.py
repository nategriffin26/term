#!/usr/bin/env python3
"""Record the opt-in SSH/tmux scrolling test on a simulator built for testing."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("simulator", help="Simulator UDID")
parser.add_argument("label", help="Evidence filename prefix")
parser.add_argument("--derived-data", required=True)
parser.add_argument("--display", default="1", help="simctl screen ID; 1 is the Duo outer display")
parser.add_argument("--profile", action="store_true", help="Benchmark synchronous frame handlers instead of normal display-link coalescing")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
evidence = root / "local/diagram-scroll"
evidence.mkdir(parents=True, exist_ok=True)
lease = evidence / "recording.lock"
lease.mkdir()
env = dict(os.environ)
env.pop("OPENROUTER_API_KEY", None)
process = recorder = None
try:
    (evidence / "run").write_text(args.label)
    (evidence / "ready").unlink(missing_ok=True)
    if args.profile:
        (evidence / "profile").touch()
    else:
        (evidence / "profile").unlink(missing_ok=True)
    with (evidence / f"{args.label}.log").open("w") as log:
        process = subprocess.Popen([
            "xcodebuild", "test-without-building", "-project", "app/Term.xcodeproj", "-scheme", "Term",
            "-destination", f"platform=iOS Simulator,id={args.simulator}",
            "-derivedDataPath", args.derived_data, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never",
            "-only-testing:TermTests/DiagramScrollRecordingTests",
        ], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 150
        while process.poll() is None and time.monotonic() < deadline:
            marker = evidence / "ready"
            state = marker.read_text() if marker.exists() else ""
            if state == "ready" and recorder is None:
                recorder = subprocess.Popen([
                    "xcrun", "simctl", "io", args.simulator, "recordVideo", "--codec=h264",
                    f"--display={args.display}", str(evidence / f"{args.label}.mp4"),
                ], env=env)
            if state == "done":
                break
            time.sleep(0.1)
        if recorder:
            recorder.send_signal(signal.SIGINT)
            recorder.wait(timeout=20)
        result = process.wait(timeout=60)
    if result:
        raise SystemExit(f"Test failed ({result}); see {evidence / (args.label + '.log')}")
    if recorder is None or recorder.returncode:
        raise SystemExit("The test ran, but recording failed")
    video = evidence / f"{args.label}.mp4"
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "stream=nb_frames", "-of", "json", str(video),
    ]))
    if not any(int(stream.get("nb_frames", 0)) > 30 for stream in probe["streams"]):
        raise SystemExit("The selected display did not animate; select the active simctl display")
    print(video)
finally:
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=20)
    if recorder and recorder.poll() is None:
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=20)
    (evidence / "run").unlink(missing_ok=True)
    (evidence / "ready").unlink(missing_ok=True)
    (evidence / "profile").unlink(missing_ok=True)
    lease.rmdir()
