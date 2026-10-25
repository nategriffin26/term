#!/usr/bin/env python3
"""Check real mosh fragments with sampled fallback or pinned Kani."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import time

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get("MOSH_FORMAL_CACHE", ROOT / "local/formal/mosh-fragment")).resolve()
VERSION = "0.68.0"
INSTALLER_SHA = "842fabd2ba8b13babab862e21fef2946b581d493f23062d5ce86266630f1d1ae"
BUNDLES = {
    ("Darwin", "arm64"): ("aarch64-apple-darwin", "a5d39a5d5e748253a553aa62f295c6c397287927a28e5e32691d7ff2eda0c398"),
    ("Darwin", "x86_64"): ("x86_64-apple-darwin", "b1367f694c1350abcae133701f78b3be3fd6e9beb66681a22ea0bcac0cc34808"),
    ("Linux", "x86_64"): ("x86_64-unknown-linux-gnu", "32e2b484d73ede0bbf64a2cf0879c4259422497d8aec4ee67d448de9ae7843d3"),
    ("Linux", "aarch64"): ("aarch64-unknown-linux-gnu", "0042d2688bf1550270def4a79c96aaeea138631818cb4ab5480120f2d51a942c"),
}
GREEN = ["arbitrary_packets_never_panic", "bounded_split_never_panics", "reordered_duplicates_preserve_payload", "interleaved_ids_never_mix_payloads", "reyielded_instruction_is_rejected_by_apply_gate"]


def run(args, env):
    print("+", " ".join(map(str, args)), flush=True)
    start = time.monotonic()
    try:
        subprocess.run(list(map(str, args)), env=env, cwd=ROOT, check=True)
    finally:
        print(f"Command elapsed: {time.monotonic() - start:.2f}s", flush=True)


def download(url, filename, sha):
    path = CACHE / "downloads" / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        subprocess.run(["curl", "--fail", "--location", "--output", str(path), url], check=True)
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != sha:
        raise RuntimeError(f"SHA-256 mismatch for {filename}: {actual}; remove the cached file and retry")
    return path


def setup():
    target, checksum = BUNDLES[(platform.system(), platform.machine())]
    env = dict(os.environ, CARGO_HOME=str(CACHE / "cargo"), KANI_HOME=str(CACHE / "kani"))
    proxy = CACHE / "install/bin/cargo-kani"
    if not proxy.exists():
        archive = download(f"https://static.crates.io/crates/kani-verifier/kani-verifier-{VERSION}.crate", f"kani-verifier-{VERSION}.crate", INSTALLER_SHA)
        source = CACHE / "installer-source"
        source.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as bundle:
            bundle.extractall(source, filter="data")
        run(["cargo", "install", "--locked", "--path", source / f"kani-verifier-{VERSION}", "--root", CACHE / "install", "--target-dir", CACHE / "installer-target"], env)
    env["RUSTUP_HOME"] = str(CACHE / "rustup")
    if not (CACHE / "setup-complete").exists():
        filename = f"kani-{VERSION}-{target}.tar.gz"
        archive = download(f"https://github.com/model-checking/kani/releases/download/kani-{VERSION}/{filename}", filename, checksum)
        run([proxy, "setup", "--use-local-bundle", archive], env)
        (CACHE / "setup-complete").touch()
    return proxy, env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["check", "finding", "setup", "fallback", "fallback-finding"], nargs="?", default="fallback")
    parser.add_argument("--harness", choices=GREEN)
    args = parser.parse_args()
    start = time.monotonic()
    if args.mode.startswith("fallback"):
        print("PROPTEST FALLBACK: generated real-code tests, not an exhaustive formal proof.", flush=True)
        env = dict(os.environ, CARGO_HOME=str(CACHE / "cargo"), CARGO_TARGET_DIR=str(CACHE / "native-target"))
        env.setdefault("PROPTEST_RNG_SEED", "20261025")
        command = ["cargo", "test", "--locked", "--manifest-path", ROOT / "formal/fragment-proptest/Cargo.toml"]
        if args.mode == "fallback-finding":
            command += ["finding_completed_instruction_replay", "--", "--ignored", "--nocapture"]
        elif args.harness:
            command += [args.harness]
        run(command, env)
    else:
        proxy, env = setup()
        if args.mode != "setup":
            harnesses = ["finding_completed_instruction_replay"] if args.mode == "finding" else ([args.harness] if args.harness else GREEN)
            for harness in harnesses:
                run([proxy, "kani", "--manifest-path", ROOT / "core/Cargo.toml", "-p", "mosh", "--lib", "--target-dir", CACHE / "target", "--harness", harness, "--jobs", "1", "--output-format", "terse", "-Z", "unstable-options", "--harness-timeout", "180s"], env)
    print(f"Elapsed: {time.monotonic() - start:.2f}s", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError, KeyError) as error:
        print(f"mosh fragment check failed: {error}", file=sys.stderr)
        sys.exit(1)
