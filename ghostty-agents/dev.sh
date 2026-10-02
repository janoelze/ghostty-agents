#!/bin/bash
# Builds the macOS app from this checkout, signs it like the installed app, and (re)opens it
# as a separate dev instance next to your main Ghostty.
#
#   ghostty-agents/dev.sh            build Swift changes and relaunch the dev instance
#   ghostty-agents/dev.sh --core     also rebuild GhosttyKit (after Zig changes or a pull)
#
# Signing with the same identity as /Applications/Ghostty.app matters: both share a bundle
# id, and macOS keeps one permission record per app, so a differently signed dev build
# would reset your permissions.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
app="$repo/macos/build/ReleaseLocal/Ghostty.app"

if [ "${1:-}" = "--core" ] || [ ! -d "$repo/macos/GhosttyKit.xcframework" ]; then
  zig_version=$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' "$repo/build.zig.zon")
  zig="$HOME/.local/share/ghostty-agents/zig-$zig_version/zig"
  [ -x "$zig" ] || zig=$(command -v zig) || { echo "Zig $zig_version not found; run install.sh once" >&2; exit 1; }
  (cd "$repo" && "$zig" build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast)
fi

(cd "$repo/macos" && xcodebuild -target Ghostty -configuration ReleaseLocal -quiet \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO SYMROOT="$repo/macos/build")

"$repo/ghostty-agents/sign.sh" "$app"

# Quit a running dev instance (not the installed one), then open the new build.
if pgrep -f "$app/Contents/MacOS/ghostty" >/dev/null; then
  osascript -e "with timeout of 10 seconds" -e "tell application \"$app\" to quit" -e "end timeout" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -f "$app/Contents/MacOS/ghostty" >/dev/null || break; sleep 0.5; done
  if pgrep -f "$app/Contents/MacOS/ghostty" >/dev/null; then
    echo "The dev instance is still running (a quit confirmation may be waiting)." >&2
    exit 1
  fi
fi
open -n "$app"
echo "Opened $app"
