#!/bin/bash
# Signs a built Ghostty.app with a stable identity, keeping its entitlements.
#
#   ghostty-agents/sign.sh path/to/Ghostty.app
#
# macOS remembers privacy permissions (files and folders, Accessibility, automation) per
# app signature. Every build, the installed one and dev builds alike, must therefore be
# signed by the same identity, or macOS treats each as a new app and asks again.
#
# Uses $GHOSTTY_AGENTS_SIGN_IDENTITY, or your only code signing identity if you have
# exactly one, else ad-hoc (which changes with every build).
set -euo pipefail

app=${1:?usage: sign.sh path/to/Ghostty.app}

identity=${GHOSTTY_AGENTS_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  identities=$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p')
  if [ -n "$identities" ] && [ "$(printf '%s\n' "$identities" | wc -l | tr -d ' ')" = 1 ]; then
    identity=$identities
  else
    identity=-
  fi
fi
echo "Identity: $([ "$identity" = - ] && echo "ad-hoc (permissions won't persist across builds)" || echo "$identity")"

entitlements=$(mktemp)
codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null || true
# Nested code (Sparkle, XPC services) first, then the app with its own entitlements.
codesign --force --deep --sign "$identity" "$app"
if [ -s "$entitlements" ]; then
  codesign --force --sign "$identity" --entitlements "$entitlements" "$app"
fi
rm -f "$entitlements"
codesign --verify --deep "$app"
