# SpaceManager

[![SpaceManager demo](demo.gif)](docs/demo.mp4)

<p align="center"><a href="docs/demo.mp4"><strong>Watch the full demo (MP4)</strong></a></p>

A macOS IDE for tmux-based multi-agent work with the `smux` skill.

## Why I built this

I keep dozens of tmux sessions running and use Claude Code, Codex, and Gemini CLI agents in parallel. The working hierarchy is usually project → tmux session → agent pane.

I built SpaceManager to see that hierarchy in one window. It shows the workspace attached to each session, the panes inside it, and recent agent activity. It is a personal tool for this workflow rather than a general replacement for a code editor or terminal emulator.

## Why it is designed this way

### tmux remains the owner

SpaceManager only attaches to tmux sessions by name. It does not own the tmux server and does not terminate it when the app closes. Session persistence belongs to tmux, with `tmux-resurrect` and `tmux-continuum` handling save and restore.

This boundary was added after real session-loss incidents. App deployment, window restoration, and tmux restoration now remain separate concerns.

### Native window management, web terminal surface

Windows, sidebars, state, and navigation use SwiftUI and AppKit. Only the terminal surface uses `WKWebView` with vendored xterm.js and its WebGL renderer. A small C `forkpty` shim connects xterm.js to local processes.

This keeps macOS window behavior native while retaining terminal behavior required by tmux and CLI TUIs.

### Activity comes from transcripts

The activity dots do not poll agent processes and do not infer activity from terminal repainting. SpaceManager scans Claude, Codex, and Gemini transcript files. Recent modification time drives recency, and short-interval file stats indicate that a response is currently being written.

### The session-based window does not use tmux

The app includes a session-based quick window for everyday Claude conversations that do not need a project. It starts Claude Code directly in a PTY with `~/cld` as its working directory. Quick tabs are intentionally transient and are not restored after an app restart. Claude Code transcripts remain available for resume.

The session-based window reuses Claude Code's `ai-title` records for tab and window titles. Its recent conversation list reads the same transcripts and resumes a session by ID.

### Model catalogs come from installed CLIs

Claude model IDs are extracted from the installed Claude executable. Codex models and supported reasoning levels come from `~/.codex/models_cache.json`. These CLI-owned catalogs are the normal source of truth, with a small fallback list used only when discovery fails.

An optional local proxy exposes Codex models through the Anthropic Messages interface used by Claude Code. It reuses Codex subscription OAuth from `~/.codex/auth.json`. A proxy-backed session can switch between Claude and Codex with `/model`.

### Glass is limited to the sidebar

The sidebar uses a behind-window `NSVisualEffectView`. The main canvas is opaque. Earlier builds applied behind-window blur and glass effects to more surfaces; measurement with several large windows showed high WindowServer CPU use, so the effect was reduced to the sidebar.

## How to use

### Requirements and current assumptions

- macOS 14 or later
- Swift 5.9 / Xcode 15 or later for building
- `tmux`; `tmux-resurrect` and `tmux-continuum` are recommended for reboot recovery
- Claude Code CLI

This repository reflects a personal setup. The session-based window currently expects a `ccv` wrapper at `~/myworld/ccv` and uses `~/cld` for quick conversations. The optional Codex router is a separate sibling project at `~/myworld/claude-codex-router`. These paths must be adapted before treating the app as a general distribution.

### Build and run

```sh
git clone https://github.com/NEWBIE0413/SpaceManager.git
cd SpaceManager
swift test
swift build -c release
.build/release/SpaceManager
```

SwiftPM produces the executable and its resource bundle. This repository does not currently include a general-purpose `.app` packaging script.

The development machine uses an existing `/Applications/WorkspaceManager.app` bundle. To refresh that bundle after a release build:

```sh
APP=/Applications/WorkspaceManager.app
cp .build/release/SpaceManager "$APP/Contents/MacOS/SpaceManager"
rm -rf "$APP/Contents/Resources/SpaceManager_SpaceManager.bundle"
cp -R .build/release/SpaceManager_SpaceManager.bundle "$APP/Contents/Resources/"
codesign --force -s - "$APP"
```

Ad-hoc re-signing may require macOS Accessibility and Screen Recording permissions to be checked again.

### Basic workflow

1. Add a project folder from the `WORKSPACES` sidebar.
2. Select it. SpaceManager attaches to the tmux session derived from the workspace name, creating that session only when it does not already exist.
3. Use tmux panes for agents and [`tmux-bridge`](https://github.com/ShawnPana/smux) for cross-pane messages. The CLI is included in the smux repository.
4. Open another workspace window with `Command-N`.
5. Open the session-based window with `Command-Option-N`. Choose a model, effort level, and direct or proxy mode in the composer.
6. Click a recent conversation to resume its transcript-backed session.

| Shortcut | Action |
|---|---|
| `Command-N` | Open a workspace window |
| `Command-Option-N` | Open a session-based window |
| `Command-Shift-N` | Add a workspace |
| `Command-T` | Open a shell tab, or an immediate quick conversation |
| `Command-Shift-T` | Open another tmux tab |
| `Command-Option-Left/Right` | Select the previous or next tab |

When the same tmux session is attached from more than one window, this tmux setting makes the active client determine the session size:

```tmux
set -g window-size latest
```

### Optional Codex router

The router binds to `127.0.0.1:4141` and is not installed as a service. Start it manually:

```sh
cd ~/myworld/claude-codex-router
./scripts/start-background.sh
```

Stop it with:

```sh
./scripts/stop.sh
```

When the router is unavailable, the session-based window keeps the direct Claude model choices and disables proxy-only choices.

## Credits

- Demo recorded with [OpenScreen](https://github.com/siddharthvaddem/openscreen).
- Agent orchestration uses the [smux](https://github.com/ShawnPana/smux) skill by [ShawnPana](https://github.com/ShawnPana). The development of SpaceManager itself was coordinated through this protocol.
- Terminal rendering uses [xterm.js](https://github.com/xtermjs/xterm.js).
- Session management and recovery use [tmux](https://github.com/tmux/tmux), [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum).

SpaceManager is released under the [MIT License](LICENSE).
