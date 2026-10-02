# Ghostty Agents

A soft fork of [Ghostty](https://github.com/ghostty-org/ghostty) for working with many coding
agents at once (Claude Code, Codex, Gemini, Aider, …). It adds a sidebar that lists the agents
running in your tabs and splits, shows what each one is doing, and finds and resumes past
sessions. Everything else is stock Ghostty, merged from upstream automatically.

macOS only: the sidebar is part of the macOS app.

## The sidebar

The sidebar sits on the left of every terminal window and lists the agents running in any
window, tab or split.

- **Grouped by project.** Agents are grouped under their git repository, with the branch in
  the header. Click a header to collapse the folder; a collapsed folder still shows how many
  agents it holds and whether any of them needs you. Collapsed folders are remembered.
- **Two lines per agent.** The first line is the task (the agent's title, the session's
  title, or your last prompt). The second line depends on the state:
  - working: what it's doing right now ("Editing AgentMonitor.swift", "Running tests")
  - needs input: the question or permission prompt, in orange
  - finished: "Done", with how long ago
- **Status dots.** Pulsing: working. Orange: needs input. Green: finished and you haven't
  looked yet; green ring: finished and seen. Gray ring: running, no status (see below).
- **Tab and split order.** Rows follow the order of your tabs and splits.
- **Project colors.** Each project gets a stable color that also tints its tabs (Agents →
  Color Tabs by Project). Tabs you colored yourself are left alone.
- **Cat Mode.** Agents → Cat Mode shows each agent as a small pixel cat: it walks while the
  agent works, meows when it needs you, grooms when it finished, and sleeps once you've looked.
  The sprite sheets aren't in this repository (their license is unknown); put `cat-<color>.png`
  sheets (32×32 frames, one animation per row) in
  `~/Library/Application Support/ghostty-agents/`.
- **Status line.** The bottom line summarizes your agents ("4 agents · 1 working · 1 waiting").
  Right-click it to search or rebuild the search index.
- **Theme.** Colors follow your Ghostty theme, including `background-opacity`. Drag the
  sidebar's edge to resize it (double-click resets).

### Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌃⌘S | Show or hide the sidebar |
| ⌃⌘J | Jump to the next agent needing attention (waiting on input first, then finished) |
| ⌃⌘1 … ⌃⌘9 | Jump to the agent at that position |
| ⌃⌘K | Search past sessions |

All of them are in the **Agents** menu. They are regular menu shortcuts, so a Ghostty keybind
on the same key wins, and you can remap them in System Settings → Keyboard → Keyboard
Shortcuts → App Shortcuts.

## Session search

The search field at the top of the sidebar searches every past Claude Code and Codex session
(`~/.claude`, `$CLAUDE_CONFIG_DIR`, `~/.claude-profiles/*`, `~/.codex`) and resumes one in a
new tab.

- **Made for half-remembered sessions.** Your words can come from different messages of the
  same session. Words match as you type (`sidb` → sidebar), misspellings are tolerated when
  what you typed is rare in your history (`monitr`, `safehose`), and compound names are split
  (`monitor` finds `AgentMonitor`). Use `"quotes"` for exact phrases and `-word` to exclude.
- **Ranking.** Exact matches come before typo matches. Titles and your own prompts count more
  than replies and tool calls. Recent sessions get a boost.
- **Results** show the session title, project, branch, age, and the matching passage with your
  words highlighted.
- **Keys.** ↑/↓ select, Return asks to confirm, Return again resumes, Escape backs out one
  step (confirmation, query, then back to the terminal).
- **Resuming** opens a new tab in the session's folder and types `claude --resume <id>` (or
  `codex resume <id>`) into your shell, so your shell functions and wrappers apply. If the
  session is already open, it switches to that tab instead.
- **The index** is SQLite FTS5 in `~/Library/Caches/ghostty-agents/sessions.sqlite`. It indexes
  titles, prompts, replies and tool calls (commands, file paths), not tool output. It builds
  in the background (seconds for gigabytes of transcripts), follows changes with FSEvents, and
  shows its progress at the right end of the search field. Agents → Rebuild Search Index
  starts over. Transcript formats are parsed loosely and fall back to collecting any text, so
  format changes in the agents degrade search rather than break it.

## Agent status

Agents are recognized from each terminal's foreground process, including through wrapper
scripts. Detailed status (working, needs input, finished, current activity) comes from Claude
Code hooks:

```sh
ghostty-agents/install-claude-hooks.sh                       # ~/.claude/settings.json
CLAUDE_CONFIG_DIR=~/.claude-profiles/work ghostty-agents/install-claude-hooks.sh
ghostty-agents/install-claude-hooks.sh --uninstall
```

`install.sh` installs them for `~/.claude` and every `~/.claude-profiles/*` automatically.

How it works: every terminal is started with `GHOSTTY_AGENTS_SURFACE_ID=<uuid>` (the same id as
the AppleScript `terminal` id). The hook writes each event's payload to
`$(getconf DARWIN_USER_TEMP_DIR)ghostty-agents/<uuid>/<Event>.json`, and the sidebar reads it.
No process inspection is needed, so it works inside sandboxes, and the hook does nothing outside
Ghostty Agents. Other agents can report status the same way.

If agents run through a sandbox wrapper that cleans the environment, let
`GHOSTTY_AGENTS_SURFACE_ID` through, or the sidebar only shows "Running". For Agent Safehouse:
`safehouse --env-pass=GHOSTTY_AGENTS_SURFACE_ID …`.

## Installing

```sh
ghostty-agents/install.sh                     # pull, build, install as /Applications/Ghostty.app
ghostty-agents/install.sh --from-ci           # install the latest CI build instead
ghostty-agents/install.sh --restore-official  # put the official Ghostty back
```

Re-run it to update. It downloads the Zig version upstream needs, builds, refuses builds that
could auto-update themselves to official Ghostty, signs the app (see below), saves the official
app once to `~/Library/Application Support/ghostty-agents/Ghostty-official.zip`, and refreshes
the Claude Code hooks. Quit and reopen Ghostty to switch.

Building needs Xcode 26 with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
If the build can't find `metal` right after installing it, run `xcrun --kill-cache`.

### Signing and macOS permissions

The fork keeps Ghostty's bundle id, so settings carry over. macOS keeps one permission record
(files and folders, Accessibility, automation) per bundle id and remembers which signature it
was granted to. Every build is therefore signed by `ghostty-agents/sign.sh` with the same
identity: `$GHOSTTY_AGENTS_SIGN_IDENTITY`, or your only code signing identity. Running a
differently signed copy (official Ghostty, an ad-hoc or CI build) makes macOS ask again and
resets the permissions for the others.

## Developing

```sh
ghostty-agents/dev.sh          # build Swift changes, sign, (re)open a dev instance
ghostty-agents/dev.sh --core   # also rebuild GhosttyKit (after Zig changes or a pull)
```

The dev instance runs next to your installed Ghostty. Its code lives in
`macos/Sources/Features/AgentSidebar/` (search in `Search/`).

## Staying compatible with upstream

The fork is kept small so upstream merges stay automatic:

- New code lives in new files: `macos/Sources/Features/AgentSidebar/` and this folder. The
  Xcode project uses folder-synced groups, so `project.pbxproj` is untouched.
- Upstream files have three small edits:
  - `macos/Sources/Features/Terminal/TerminalController.swift` wraps `TerminalView` in
    `AgentSidebarLayout` (one line).
  - `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` adds
    `.withAgentSurfaceID(id)` to the surface configuration (one line).
  - `README.md` starts with a short section about this fork.
- The Agents menu is added at runtime, not in `MainMenu.xib`.
- Same config file (`~/.config/ghostty/config`) and bundle id, so settings, themes and keybinds
  carry over. Source builds have Sparkle's update checks off; don't use "Check for Updates…",
  it would replace this build with official Ghostty.

`.github/workflows/ghostty-agents-sync.yml` merges upstream `main` every three hours, builds the
result on macOS with `ghostty-agents-build.yml`, and fast-forwards `main` only if it builds.
Conflicts and build failures open an issue labeled `upstream-sync`. It needs a `SYNC_TOKEN`
secret: a fine-grained token for this repository with Contents and Workflows write access.
Upstream's own workflows are disabled in the fork because they run on upstream's private
runners.

Please don't report issues with this fork to the Ghostty project.
