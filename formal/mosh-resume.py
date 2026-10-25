#!/usr/bin/env python3
"""Pinned TLC + executable retention policy + reviewed-code correspondence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
FORMAL = ROOT / "formal"
CACHE = ROOT / "local" / "formal" / "mosh-resume"
VERSION = "1.8.0"
SHA256 = "d15655eeaff4b3f7b3d65c46b838bc0f35d131b2ef4b1e473689b62c98d4726f"
URL = f"https://github.com/tlaplus/tlaplus/releases/download/v{VERSION}/tla2tools.jar"
COVERAGE = {
    "core/mosh/src/lib.rs": ["resumed_sequence", "new", "receive", "latest_number", "next_send", "next_wake", "next_datagram", "resume", "save", "restore"],
    "core/mosh/src/state.rs": ["acknowledge", "add_sent", "assumed", "retain_from", "may_apply", "discard_before"],
    "core/termcore/src/remote.rs": ["new", "save", "suspend", "resume", "stop", "start_mosh", "mosh_bootstrap", "mosh_plan", "mosh_receive", "restore", "mosh_loop", "bind", "reconnect", "replace_remote", "abort_remote"],
    "core/termcore/src/lib.rs": ["term_session_save", "term_session_suspend", "term_session_resume", "term_session_restore", "term_session_free", "term_session_reconnect"],
    "core/termcore/src/session.rs": ["lock", "update"],
    "core/ssh/src/mosh.rs": ["mosh_bootstrap", "end_server_command"],
    "app/Sources/Terminal/Session.swift": ["save", "suspend", "resume", "reconnect"],
    "app/Sources/Shell/Tab.swift": ["saveState", "suspend", "resume", "reconnect", "wireAutoReconnect"],
    "app/Sources/Shell/AutoReconnect.swift": ["suspended", "probeHost", "evaluate"],
    "app/Sources/Shell/SessionRegistry.swift": ["suspendAll", "resumeAll", "restoreSaved", "clearSaved"],
}
SUSPEND_GUARD = (
    "                if matches!(&st.remote, Remote::Mosh(old) if old.suspended) {\n"
    '                    return Err("suspended".to_string());\n'
    "                }\n"
)
SUSPEND_ANCHOR = "                // must always name the client/server pair that remains alive.\n"


def function(text, name, normalize=True):
    bodies = []
    for match in re.finditer(r"\b(?:fn|func)\s+" + re.escape(name) + r"\s*(?:<|\()", text):
        start = match.start()
        opening = text.index("{", start)
        if ";" in text[start:opening]:
            continue  # trait declaration, not an implementation
        depth = 1
        end = opening + 1
        while depth:
            if text[end] == "{":
                depth += 1
            elif text[end] == "}":
                depth -= 1
            end += 1
        body = text[start:end]
        # Only these two exact mutations may reach TLC without a re-review.
        if normalize and name == "retain_from":
            body = body.replace("*num <= throwaway", "*num < throwaway")
        if normalize and name == "replace_remote":
            body = body.replace(SUSPEND_ANCHOR + SUSPEND_GUARD, SUSPEND_ANCHOR)
        bodies.append(body)
    if not bodies:
        raise ValueError(f"no implementation of {name}")
    return "\n\n".join(bodies)


def fingerprints():
    result = {}
    for filename, names in COVERAGE.items():
        text = (ROOT / filename).read_text()
        for name in names:
            result[f"{filename}:{name}"] = hashlib.sha256(function(text, name).encode()).hexdigest()
    return result


def tool():
    jar = CACHE / f"tla2tools-{VERSION}.jar"
    if not jar.exists():
        download = jar.with_suffix(".download")
        print(f"Fetching TLC {VERSION} from {URL}", flush=True)
        urllib.request.urlretrieve(URL, download)
        if hashlib.sha256(download.read_bytes()).hexdigest() != SHA256:
            download.unlink()
            raise RuntimeError("TLC checksum mismatch; do not accept a republished tag silently")
        download.replace(jar)
    if hashlib.sha256(jar.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError(f"TLC checksum mismatch: remove {jar.relative_to(ROOT)} and rerun")
    return jar


def probe():
    project = CACHE / "probe"
    (project / "src").mkdir(parents=True, exist_ok=True)
    manifest = '[package]\nname = "mosh-resume-policy-probe"\nversion = "0.0.0"\nedition = "2024"\n[workspace]\n[dependencies]\nmosh = { path = ' + json.dumps(str(ROOT / "core/mosh")) + ' }\n'
    (project / "Cargo.toml").write_text(manifest)
    shutil.copyfile(FORMAL / "mosh-resume-probe.rs", project / "src/main.rs")
    if not (project / "Cargo.lock").exists():
        shutil.copyfile(ROOT / "core/Cargo.lock", project / "Cargo.lock")
    target = os.environ.get("CARGO_TARGET_DIR", str(ROOT / "core/target"))
    command = ["cargo", "run", "--quiet", "--offline", "--manifest-path", str(project / "Cargo.toml"), "--target-dir", target]
    result = subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
    policy = result.stdout.strip()
    if policy not in ("KeepBoundary = TRUE", "KeepBoundary = FALSE"):
        raise RuntimeError(f"unrecognized policy probe output: {policy}")
    print(f"Actual mosh::state policy: {policy}; may_apply and resumed_sequence correspondence passed", flush=True)
    return policy


def reconnect_policy():
    body = function((ROOT / "core/termcore/src/remote.rs").read_text(), "replace_remote", normalize=False)
    count = body.count(SUSPEND_GUARD)
    if count not in (0, 1):
        raise RuntimeError("ambiguous suspension guard: review reconnect correspondence")
    policy = f"FreezeSuspended = {'TRUE' if count else 'FALSE'}"
    print(f"Reviewed source branch: {policy} (not an executable termcore probe)", flush=True)
    return policy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=("safe", "stale", "foreground", "reconnect", "reconnect-before"), default="safe")
    parser.add_argument("--record-reviewed-code", action="store_true", help="only after following the project skill's code/model review")
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    manifest = FORMAL / "mosh-resume-code.json"
    observed = fingerprints()
    if args.record_reviewed_code:
        manifest.write_text(json.dumps(observed, indent=2, sort_keys=True) + "\n")
        print("Recorded reviewed function bodies; advance the skill's sync commits only after the checks pass.")
        return 0
    recorded = json.loads(manifest.read_text())
    changed = [name for name in observed.keys() | recorded.keys() if observed.get(name) != recorded.get(name)]
    if changed:
        raise RuntimeError("Code/model correspondence needs review (.omp/skills/mosh-resume-formal/SKILL.md):\n  " + "\n  ".join(sorted(changed)))
    start = time.monotonic()
    jar = tool()
    policy = probe()
    scenarios = ("safe", "reconnect") if args.scenario == "safe" else (args.scenario,)
    for scenario in scenarios:
        result = check(scenario, jar, policy)
        if result:
            break
    print(f"Verification: exit {result}; {time.monotonic() - start:.2f}s", flush=True)
    return result


def check(scenario, jar, policy):
    start = time.monotonic()
    configuration = (FORMAL / f"resume-{scenario}.cfg").read_text().replace("KeepBoundary = TRUE", policy)
    if scenario == "reconnect":
        configuration = configuration.replace("FreezeSuspended = TRUE", reconnect_policy())
    cfg = CACHE / f"resume-{scenario}.cfg"
    cfg.write_text(configuration)
    metadata = CACHE / f"states-{os.getpid()}"
    log = CACHE / f"{scenario}.log"
    module = "MoshReconnect.tla" if scenario.startswith("reconnect") else "MoshResume.tla"
    command = ["java", "-Xmx2g", "-XX:+UseParallelGC", "-cp", str(jar), "tlc2.TLC", "-workers", "1", "-lncheck", "final", "-noGenerateSpecTE", "-fp", "0", "-seed", "1", "-metadir", str(metadata), "-config", str(cfg), str(FORMAL / module)]
    try:
        with log.open("w") as output:
            result = subprocess.run(command, cwd=CACHE, stdout=output, stderr=subprocess.STDOUT)
        text = log.read_text()
        # Keep the full counterexample; successful runs need only the result.
        if result.returncode:
            print(text)
        else:
            for line in text.splitlines():
                if any(marker in line for marker in ("TLC2 Version", "No error", "states generated,", "depth of", "Finished in")):
                    print(line)
        print(f"Scenario {scenario}: exit {result.returncode}; {time.monotonic() - start:.2f}s; log {log.relative_to(ROOT)}", flush=True)
        return result.returncode
    finally:
        shutil.rmtree(metadata, ignore_errors=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
