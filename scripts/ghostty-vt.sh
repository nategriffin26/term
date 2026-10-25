#!/bin/sh
# Builds libghostty-vt (static, iOS device + simulator + macOS) into
# build/ghostty-vt.xcframework from a pinned Ghostty commit and Zig release.
set -eu

GHOSTTY_COMMIT=cec8b92f1ecd176a20a56aa405021e7ae991b996
ZIG_VERSION=0.17.0
ZIG_SHA256=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a

root=$(cd "$(dirname "$0")/.." && pwd)
deps="$root/local/deps"
out="$root/build/ghostty-vt.xcframework"
mkdir -p "$deps" "$root/build"

zig="$deps/zig/zig"
if [ ! -x "$zig" ] || [ "$("$zig" version)" != "$ZIG_VERSION" ]; then
  rm -rf "$deps/zig"
  curl -fsSL -o "$deps/zig.tar.xz" "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz"
  echo "$ZIG_SHA256  $deps/zig.tar.xz" | shasum -a 256 -c -
  tar -C "$deps" -xf "$deps/zig.tar.xz"
  mv "$deps/zig-aarch64-macos-$ZIG_VERSION" "$deps/zig"
  rm "$deps/zig.tar.xz"
fi

src="$deps/ghostty"
if [ ! -d "$src/.git" ]; then
  git clone -q https://github.com/ghostty-org/ghostty.git "$src"
fi
if [ "$(git -C "$src" rev-parse HEAD)" != "$GHOSTTY_COMMIT" ]; then
  git -C "$src" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$src" checkout -q "$GHOSTTY_COMMIT"
fi

stamp="$out/.commit"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$GHOSTTY_COMMIT" ]; then
  exit 0
fi

(cd "$src" && "$zig" build -Demit-lib-vt=true -Demit-xcframework=true -Doptimize=ReleaseFast)
rm -rf "$out"
cp -R "$src/zig-out/lib/ghostty-vt.xcframework" "$out"
echo "$GHOSTTY_COMMIT" > "$stamp"
