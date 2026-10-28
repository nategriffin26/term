#!/bin/sh
# Copy Term's diagnostic log (Library/Logs/term.log and the rotated term.1.log)
# off a phone into local/device-logs/<time>/ and print its last 80 lines.
# The phone must be awake and reachable (USB or the same network).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEVICE=${1:-${TERM_DEVICE:-}}
if [ -z "$DEVICE" ]; then
  echo "Usage: scripts/pull-device-log.sh <device UDID or name>  (or set TERM_DEVICE)" >&2
  exit 64
fi
# The app's bundle id lives in the git-ignored Local.xcconfig (see app/Config/Signing.xcconfig).
BUNDLE_ID=$(sed -n 's/^[[:space:]]*TERM_BUNDLE_ID[[:space:]]*=[[:space:]]*\([^[:space:]/;]*\).*/\1/p' \
  "$ROOT/app/Config/Local.xcconfig" 2>/dev/null | tail -n 1)
BUNDLE_ID=${BUNDLE_ID:-com.example.term}
OUT="$ROOT/local/device-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

copy() {
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "Library/Logs/$1" --destination "$OUT/$1" >"$OUT/devicectl.txt" 2>&1
}

if ! copy term.log; then
  cat "$OUT/devicectl.txt" >&2
  echo "Could not copy term.log from $DEVICE: wake and unlock the phone, and check it is on this Mac's network." >&2
  exit 1
fi
# The previous log exists only once term.log has reached 2 MB.
copy term.1.log || true
rm -f "$OUT/devicectl.txt"

echo "$OUT"
tail -n 80 "$OUT/term.log"
