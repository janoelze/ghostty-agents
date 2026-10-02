#!/bin/sh
# One-off: lets GHOSTTY_AGENTS_SURFACE_ID through the safehouse wrapper in ~/.zshrc.
# Idempotent; keeps a backup at ~/.zshrc.bak-ghostty-agents.
set -eu
rc="${1:-$HOME/.zshrc}"
if grep -q 'env-pass=GHOSTTY_AGENTS_SURFACE_ID' "$rc"; then
  echo "Already patched: $rc"; exit 0
fi
grep -q 'gl-fix.sb ] && extra+=' "$rc" || { echo "Anchor line (gl-fix.sb) not found in $rc; add the line manually." >&2; exit 1; }
cp "$rc" "$rc.bak-ghostty-agents"
awk '
  { print }
  /gl-fix\.sb \] && extra\+=/ && !done {
    print "    # Ghostty Agents: let the agent status hook see which terminal it runs in."
    print "    [ -n \"$GHOSTTY_AGENTS_SURFACE_ID\" ] && extra+=(--env-pass=GHOSTTY_AGENTS_SURFACE_ID)"
    done = 1
  }
' "$rc.bak-ghostty-agents" > "$rc"
zsh -n "$rc" && echo "Patched $rc (backup: $rc.bak-ghostty-agents). Open a new tab, then start claude."
