#!/bin/sh
# Installs (or with --uninstall, removes) the Claude Code hooks that feed the
# Ghostty Agents sidebar. Safe to run repeatedly; other hooks are left alone.
#
#   ghostty-agents/install-claude-hooks.sh [--uninstall] [settings.json]
#
# The hook script is copied to ~/.claude/hooks/ so it keeps working when this
# repository moves, and so sandboxed Claude Code sessions can always reach it.
set -eu

uninstall=0
if [ "${1:-}" = "--uninstall" ]; then
  uninstall=1
  shift
fi

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
settings="${1:-$claude_dir/settings.json}"
hook="$claude_dir/hooks/ghostty-agents-status.sh"
here=$(cd "$(dirname "$0")" && pwd)

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

[ -f "$settings" ] || echo '{}' >"$settings"
cp "$settings" "$settings.bak-ghostty-agents"

# Drop any entries pointing at our hook, then remove event lists that became empty.
filter='
  def strip: map(.hooks |= map(select(.command | tostring | contains("ghostty-agents-status.sh") | not)))
             | map(select(.hooks | length > 0));
  .hooks = ((.hooks // {}) | with_entries(.value |= strip) | with_entries(select(.value | length > 0)))
  | if .hooks == {} then del(.hooks) else . end
'

if [ "$uninstall" = 1 ]; then
  jq "$filter" "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  rm -f "$hook"
  echo "Removed Ghostty Agents hooks from $settings"
  exit 0
fi

mkdir -p "$(dirname "$hook")"
cp "$here/hooks/claude-status.sh" "$hook"
chmod +x "$hook"

jq --arg cmd "$hook" "$filter"'
  | def entry($m): if $m then {matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 5}]}
                   else {hooks: [{type: "command", command: $cmd, timeout: 5}]} end;
  reduce (
    ["SessionStart", false], ["SessionEnd", false], ["UserPromptSubmit", false],
    ["PreToolUse", true], ["PostToolUse", true], ["Notification", false],
    ["Stop", false], ["PreCompact", false]
  ) as [$event, $m] (.; .hooks[$event] = ((.hooks[$event] // []) + [entry($m)]))
' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"

echo "Installed Ghostty Agents hooks into $settings (backup: $settings.bak-ghostty-agents)"
echo "Restart running Claude Code sessions to pick them up."
