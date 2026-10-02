# Ghostty Agents

A soft fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds a sidebar listing
the coding agents (Claude Code, Codex, Gemini, Aider, …) running in any tab or split, with
their status, so you can jump between agent sessions instead of hunting through tabs.

Everything else is stock Ghostty, merged from upstream automatically.

## Using it

| Shortcut | Action |
| --- | --- |
| ⌃⌘S | Show/hide the agent sidebar |
| ⌃⌘J | Jump to the next agent needing attention (waiting on input first, then finished) |
| ⌃⌘1 … ⌃⌘9 | Jump to the agent at that position |

All three are in the **Agents** menu. They're regular menu shortcuts, so a Ghostty keybind on
the same key wins, and you can remap them in System Settings → Keyboard → Keyboard Shortcuts →
App Shortcuts. Drag the sidebar's edge to resize it (double-click resets); width and visibility
are remembered. Colors follow your Ghostty theme, including `background-opacity`.

Status dots:

- **pulsing** — working
- **orange** — needs input (permission prompt or question)
- **green** — finished its turn and you haven't looked yet; **green ring** — finished, seen
- **gray ring** — running, no status hooks (e.g. agents other than Claude Code)

### Status from Claude Code

Agents are detected from each terminal's foreground process. Detailed status comes from
Claude Code hooks:

```sh
ghostty-agents/install-claude-hooks.sh            # adds hooks to ~/.claude/settings.json
ghostty-agents/install-claude-hooks.sh --uninstall
```

The hook is a no-op outside Ghostty Agents. It works inside sandboxes because it needs no
process inspection: every terminal is started with `GHOSTTY_AGENTS_SURFACE_ID=<uuid>` (the
same id as the AppleScript `terminal` id), and the hook writes the raw hook payload to
`$(getconf DARWIN_USER_TEMP_DIR)ghostty-agents/<uuid>/<Event>.json`. Other agents can report
status the same way.

If agents run through a sandbox wrapper that cleans the environment, let
`GHOSTTY_AGENTS_SURFACE_ID` through, or the sidebar only shows "Running". For
Agent Safehouse: `safehouse --env-pass=GHOSTTY_AGENTS_SURFACE_ID …`.

## Installing

```sh
ghostty-agents/install.sh                     # pull, build, install as /Applications/Ghostty.app
ghostty-agents/install.sh --from-ci           # install the latest CI build instead
ghostty-agents/install.sh --restore-official  # put the official Ghostty back
```

Re-run it to update. It downloads the Zig version upstream needs, refuses builds that could
auto-update to official Ghostty, signs with your code signing identity (set
`GHOSTTY_AGENTS_SIGN_IDENTITY` if you have several) so macOS permissions stick, saves the
official app once, and refreshes the Claude Code hooks.

## Developing

```sh
ghostty-agents/dev.sh          # build Swift changes, sign, (re)open a dev instance
ghostty-agents/dev.sh --core   # also rebuild GhosttyKit (after Zig changes or a pull)
```

Every build is signed by `ghostty-agents/sign.sh` with the same identity as the installed
app. macOS keeps one permission record per bundle id, and all builds share Ghostty's, so a
differently signed build (ad-hoc, CI, official Ghostty) makes macOS ask for permissions
again and resets them for the others.

## Building

Needs Xcode 26 with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) and
the Zig version in `build.zig.zon` (`minimum_zig_version`).

```sh
zig build -Demit-macos-app=false -Dxcframework-target=native
cd macos && xcodebuild -target Ghostty -configuration ReleaseLocal
open build/ReleaseLocal/Ghostty.app
```

## Staying compatible with upstream

The fork is kept small so upstream merges stay automatic:

- All new code lives in new files: `macos/Sources/Features/AgentSidebar/` and this folder.
  The Xcode project uses folder-synced groups, so `project.pbxproj` is untouched.
- Exactly two one-line hooks into upstream files:
  - `macos/Sources/Features/Terminal/TerminalController.swift` wraps `TerminalView` in
    `AgentSidebarLayout`.
  - `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` adds
    `.withAgentSurfaceID(id)` to the surface configuration.
- The Agents menu is added at runtime, not in `MainMenu.xib`.
- Same config file (`~/.config/ghostty/config`) and same bundle identifier, so settings,
  themes and keybinds carry over. Source builds have Sparkle auto-checks off; don't use
  "Check for Updates…", it would replace this build with official Ghostty.

`.github/workflows/ghostty-agents-sync.yml` merges upstream `main` every three hours, builds
the result on macOS and fast-forwards `main` if it builds. Conflicts or build failures open an
issue labeled `upstream-sync`. It needs a `SYNC_TOKEN` secret (fine-grained token for this
repo with Contents and Workflows write access). Upstream's own workflows are disabled in the
fork because they run on upstream's private runners.

Please don't report issues with this fork to the Ghostty project.
