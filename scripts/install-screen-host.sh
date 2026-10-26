#!/bin/sh
# Install or remove the per-user Screen host; privacy grants belong to its signed app.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec /usr/bin/python3 - "$ROOT" "$@" <<'PY'
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
arguments = sys.argv[2:]
if arguments not in ([], ["--uninstall"]):
    sys.exit("Usage: scripts/install-screen-host.sh [--uninstall]")
home = pathlib.Path.home()
app = home / "Applications/Term Screen Host.app"
agent_directory = home / "Library/LaunchAgents"
configuration = root / "app/Config/Local.xcconfig"
values = {}
if configuration.exists():
    for line in configuration.read_text().splitlines():
        match = re.match(r"\s*(TERM_BUNDLE_ID|DEVELOPMENT_TEAM)\s*=\s*([^/;\s]+)", line)
        if match:
            values[match[1]] = match[2].strip('"')
bundle_id = values.get("TERM_BUNDLE_ID", "com.example.term") + ".screen-host"
old_id = bundle_id
info = app / "Contents/Info.plist"
if info.exists():
    old_id = plistlib.loads(info.read_bytes())["CFBundleIdentifier"]
domain = "gui/" + str(os.getuid())

def stop(label):
    subprocess.run(["launchctl", "bootout", domain + "/" + label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (agent_directory / (label + ".plist")).unlink(missing_ok=True)

if arguments == ["--uninstall"]:
    stop(old_id)
    if old_id != bundle_id:
        stop(bundle_id)
    if app.exists():
        shutil.rmtree(app)
    print("Term Screen Host uninstalled.")
    sys.exit(0)

environment = dict(os.environ)
environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
package = root / "mac/ScreenHost"
subprocess.run(["swift", "build", "-c", "release", "--product", "term-screen-host"], cwd=package, env=environment, check=True)
binaries = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=package, env=environment, text=True).strip()
identity = "-"
team = values.get("DEVELOPMENT_TEAM")
if team:
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    available = {match[1].upper() for match in re.finditer(r'([0-9A-Fa-f]{40})\s+"Apple Development:[^"]+"', identities)}
    certificates = subprocess.check_output(["security", "find-certificate", "-a", "-p"], text=True)
    for certificate in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.S):
        details = subprocess.check_output(
            ["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253", "-fingerprint", "-sha1"],
            input=certificate, text=True)
        fingerprint = re.search(r"Fingerprint=([0-9A-Fa-f:]+)", details)
        if fingerprint and re.search(r"(?:^|,)OU=" + re.escape(team) + r"(?:,|$)", details, re.M):
            candidate = fingerprint[1].replace(":", "").upper()
            if candidate in available:
                identity = candidate
                break
if identity == "-":
    print("Warning: ad-hoc signing resets privacy grants on each install.", file=sys.stderr)

stop(old_id)
if old_id != bundle_id:
    stop(bundle_id)
if app.exists():
    shutil.rmtree(app)
executable_directory = app / "Contents/MacOS"
executable_directory.mkdir(parents=True)
shutil.copy2(pathlib.Path(binaries) / "term-screen-host", executable_directory / "term-screen-host")
info.write_bytes(plistlib.dumps({
    "CFBundleIdentifier": bundle_id,
    "CFBundleName": "Term Screen Host",
    "CFBundleDisplayName": "Term Screen Host",
    "CFBundleExecutable": "term-screen-host",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "LSMinimumSystemVersion": "15.0",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
}))
subprocess.run(["codesign", "--force", "--sign", identity, "--identifier", bundle_id, str(app)], check=True)
agent_directory.mkdir(parents=True, exist_ok=True)
agent = agent_directory / (bundle_id + ".plist")
agent.write_bytes(plistlib.dumps({
    "Label": bundle_id,
    "ProgramArguments": [str(executable_directory / "term-screen-host")],
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Interactive",
    "LimitLoadToSessionType": "Aqua",
}))
os.chmod(agent, 0o600)
subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
print("Term Screen Host installed and started.")
print("Approve Term Screen Host in System Settings > Privacy & Security:")
print("  Screen & System Audio Recording")
print("  Accessibility")
print("  Paste from Other Apps: Always Allow")
print("On the first Screen connection, allow the Mac's paste alert; then choose Always Allow in that pane.")
PY
