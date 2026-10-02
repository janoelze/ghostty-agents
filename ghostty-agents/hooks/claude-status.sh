#!/bin/sh
# Reports Claude Code hook events to the Ghostty Agents sidebar.
#
# Ghostty Agents starts every terminal with GHOSTTY_AGENTS_SURFACE_ID=<uuid>. This hook
# stores the raw hook payload under that UUID so the sidebar can show the state of the
# agent in that exact split. Outside Ghostty Agents the variable is unset and this is a
# no-op. It never fails or blocks the hook, and needs no process inspection, so it also
# works when Claude Code runs inside a sandbox.
#
# Install with ghostty-agents/install-claude-hooks.sh.

payload=$(cat)

id=$GHOSTTY_AGENTS_SURFACE_ID
case "$id" in
  "" | *[!0-9A-Fa-f-]*) exit 0 ;;
esac

base=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || base="${TMPDIR:-/tmp}/"
dir="${base%/}/ghostty-agents/$id"

event=$(printf '%s\n' "$payload" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | head -n 1)
[ -n "$event" ] || exit 0

if [ "$event" = "SessionEnd" ]; then
  rm -rf "$dir"
  exit 0
fi

mkdir -p "$dir" 2>/dev/null || exit 0
tmp="$dir/.$event.$$"
printf '{"agent":"claude","ts":%s,"event":%s}\n' "$(date +%s)" "$payload" >"$tmp" 2>/dev/null &&
  mv -f "$tmp" "$dir/$event.json" 2>/dev/null
exit 0
