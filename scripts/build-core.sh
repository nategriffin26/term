#!/bin/sh
# Builds the Rust core (termcore, with libghostty-vt bundled inside
# libtermcore.a) for iOS device and simulator into build/TermCore.xcframework.
# The app links C++ for Ghostty and CoreFoundation for SFTP's chrono dependency.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET=27.0
out="$root/build/TermCore.xcframework"

"$root/scripts/ghostty-vt.sh"

cd "$root/core"
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  cargo build --release -p termcore --target "$target"
  lib="target/$target/release/libtermcore.a"
  # The static=ghostty-vt-fat link must have been bundled, not left to the app.
  if ! nm -g "$lib" 2>/dev/null | grep -q ' T _ghostty_terminal_new$'; then
    echo "build-core: $lib does not contain libghostty-vt" >&2
    exit 1
  fi
done

headers=$(mktemp -d)
trap 'rm -rf "$headers"' EXIT
cp termcore/include/term.h "$headers/"
printf 'module TermCore {\n  header "term.h"\n  link framework "CoreFoundation"\n  export *\n}\n' > "$headers/module.modulemap"

rm -rf "$out"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libtermcore.a -headers "$headers" \
  -library target/aarch64-apple-ios-sim/release/libtermcore.a -headers "$headers" \
  -output "$out" >/dev/null

# Every function term.h declares must link from both slices with the declared libraries.
probe="$headers/probe.c"
{
  echo '#include "term.h"'
  echo 'void *term_probe[] = {'
  grep -oE '\bterm_[a-z_]+\(' termcore/include/term.h | tr -d '(' | sort -u | sed 's/.*/  (void *)&,/'
  echo '};'
  echo 'int main(void) { return term_probe[0] == 0; }'
} > "$probe"
for slice in ios-arm64:iphoneos:arm64-apple-ios27.0 ios-arm64-simulator:iphonesimulator:arm64-apple-ios27.0-simulator; do
  dir="$out/${slice%%:*}"
  rest=${slice#*:}
  xcrun -sdk "${rest%%:*}" clang -target "${rest#*:}" -I "$dir/Headers" "$probe" \
    -L "$dir" -ltermcore -lc++ -framework CoreFoundation -o "$headers/probe"
done
echo "$out"
