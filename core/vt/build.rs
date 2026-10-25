// Links the libghostty-vt slice that matches the target from
// build/ghostty-vt.xcframework (built by scripts/ghostty-vt.sh).
use std::path::PathBuf;

fn main() {
    let target = std::env::var("TARGET").unwrap();
    let (slice, lib) = match target.as_str() {
        "aarch64-apple-ios" => ("ios-arm64", "ghostty-vt-fat"),
        "aarch64-apple-ios-sim" => ("ios-arm64-simulator", "ghostty-vt-fat"),
        "aarch64-apple-darwin" | "x86_64-apple-darwin" => ("macos-arm64_x86_64", "ghostty-vt"),
        other => panic!("vt: no libghostty-vt slice for target {other}"),
    };
    let xcframework = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../build/ghostty-vt.xcframework");
    let dir = xcframework.join(slice);
    let archive = dir.join(format!("lib{lib}.a"));
    assert!(
        archive.exists(),
        "vt: {} missing; run scripts/ghostty-vt.sh",
        archive.display()
    );
    println!("cargo:rerun-if-changed={}", archive.display());
    println!("cargo:rustc-link-search=native={}", dir.display());
    println!("cargo:rustc-link-lib=static={lib}");
    println!("cargo:rustc-link-lib=c++");
}
