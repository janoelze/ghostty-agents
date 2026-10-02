#!/bin/bash
# Builds Ghostty Agents and installs it as /Applications/Ghostty.app. Re-run it to update.
#
#   ghostty-agents/install.sh                     pull main, build locally, install
#   ghostty-agents/install.sh --from-ci           install the latest successful CI build
#   ghostty-agents/install.sh --no-pull           build the current checkout as is
#   ghostty-agents/install.sh --restore-official  put the official Ghostty back
#
# The first install saves the official app to
# ~/Library/Application Support/ghostty-agents/Ghostty-official.zip.
#
# Signing: uses $GHOSTTY_AGENTS_SIGN_IDENTITY, or your only code signing identity if you
# have exactly one, else ad-hoc. A stable identity keeps macOS permissions (Accessibility,
# automation) granted across reinstalls.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
app_dest=/Applications/Ghostty.app
support="$HOME/Library/Application Support/ghostty-agents"
backup="$support/Ghostty-official.zip"
official_team=24VZTF6M5V

from_ci=0
pull=1
for arg in "$@"; do
  case "$arg" in
    --from-ci) from_ci=1 ;;
    --no-pull) pull=0 ;;
    --restore-official) restore=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

install_bundle() {
  # Copy next to the destination, then swap, so a failed copy never leaves a broken app.
  local src=$1
  rm -rf "$app_dest.new"
  ditto "$src" "$app_dest.new"
  rm -rf "$app_dest"
  mv "$app_dest.new" "$app_dest"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_dest" >/dev/null 2>&1 || true
}

if [ "${restore:-0}" = 1 ]; then
  [ -f "$backup" ] || die "no backup at $backup"
  tmp=$(mktemp -d)
  ditto -x -k "$backup" "$tmp"
  install_bundle "$tmp/Ghostty.app"
  rm -rf "$tmp"
  echo "Restored the official Ghostty. Quit and reopen Ghostty to switch."
  exit 0
fi

[ -w /Applications ] || die "/Applications is not writable by $(whoami)"

# ---------------------------------------------------------------------------
# Get the app

if [ "$from_ci" = 1 ]; then
  step "Downloading the latest CI build"
  command -v gh >/dev/null || die "gh is required for --from-ci"
  run=$(gh run list -R janoelze/ghostty-agents --workflow ghostty-agents-build.yml --branch main \
        --status success --limit 1 --json databaseId,headSha --jq '.[0] | "\(.databaseId) \(.headSha)"')
  [ -n "$run" ] || die "no successful CI build found"
  set -- $run
  build_dir=$(mktemp -d)
  gh run download "$1" -R janoelze/ghostty-agents -D "$build_dir"
  ditto -x -k "$build_dir"/*/Ghostty-Agents.zip "$build_dir"
  app="$build_dir/Ghostty.app"
  version=${2:0:9}
else
  cd "$repo"
  if [ "$pull" = 1 ]; then
    step "Updating the checkout"
    if [ -n "$(git status --porcelain)" ]; then
      echo "Working tree has changes; building it as is."
    else
      git pull --ff-only
    fi
  fi
  version=$(git rev-parse --short HEAD)

  step "Checking the toolchain"
  zig_version=$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)
  zig_dir="$HOME/.local/share/ghostty-agents/zig-$zig_version"
  if command -v zig >/dev/null && [ "$(zig version)" = "$zig_version" ]; then
    zig=$(command -v zig)
  elif [ -x "$zig_dir/zig" ]; then
    zig="$zig_dir/zig"
  else
    echo "Downloading Zig $zig_version"
    command -v jq >/dev/null || die "jq is required to download Zig (brew install jq)"
    arch=$(uname -m | sed 's/arm64/aarch64/')
    info=$(curl -fsSL https://ziglang.org/download/index.json | jq -r --arg v "$zig_version" --arg t "$arch-macos" '.[$v][$t] | "\(.tarball) \(.shasum)"')
    set -- $info
    [ "$1" != "null" ] || die "Zig $zig_version is not available for $arch-macos"
    tmp=$(mktemp -d)
    curl -fsSL "$1" -o "$tmp/zig.tar.xz"
    echo "$2  $tmp/zig.tar.xz" | shasum -a 256 -c - >/dev/null || die "Zig checksum mismatch"
    mkdir -p "$zig_dir"
    tar -xf "$tmp/zig.tar.xz" -C "$zig_dir" --strip-components 1
    rm -rf "$tmp"
    zig="$zig_dir/zig"
  fi
  echo "Zig: $zig"

  if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    # xcrun caches a failed lookup from before the toolchain was installed.
    xcrun --kill-cache
    xcrun -sdk macosx metal --version >/dev/null 2>&1 ||
      die "Metal Toolchain missing; run: xcodebuild -downloadComponent MetalToolchain"
  fi

  step "Building GhosttyKit"
  "$zig" build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast

  step "Building Ghostty.app"
  (cd macos && xcodebuild -target Ghostty -configuration ReleaseLocal -quiet \
    ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO SYMROOT="$repo/macos/build")
  app="$repo/macos/build/ReleaseLocal/Ghostty.app"
fi

[ -d "$app" ] || die "build produced no app at $app"

# Sparkle would replace this build with official Ghostty if it ever checked for updates.
checks=$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$app/Contents/Info.plist" 2>/dev/null || echo missing)
[ "$checks" = "false" ] || die "built app has SUEnableAutomaticChecks=$checks; refusing to install a build that may auto-update"

# ---------------------------------------------------------------------------
# Sign

step "Signing"
"$repo/ghostty-agents/sign.sh" "$app"

# ---------------------------------------------------------------------------
# Install

if [ -d "$app_dest" ] && [ ! -f "$backup" ]; then
  team=$(codesign -dv "$app_dest" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [ "$team" = "$official_team" ]; then
    step "Saving the official Ghostty"
    mkdir -p "$support"
    ditto -c -k --keepParent "$app_dest" "$backup"
    echo "Saved to $backup"
  fi
fi

step "Installing to $app_dest"
install_bundle "$app"
[ "$from_ci" = 1 ] && rm -rf "$build_dir"

step "Updating Claude Code hooks"
"$repo/ghostty-agents/install-claude-hooks.sh" >/dev/null
echo "$HOME/.claude"
for dir in "$HOME"/.claude-profiles/*/; do
  [ -f "$dir/settings.json" ] || continue
  CLAUDE_CONFIG_DIR="${dir%/}" "$repo/ghostty-agents/install-claude-hooks.sh" >/dev/null
  echo "${dir%/}"
done

printf '\nInstalled Ghostty Agents %s. Quit and reopen Ghostty to switch.\n' "$version"
