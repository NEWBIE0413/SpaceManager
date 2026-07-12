# SpaceManager

A terminal-centric IDE for the age of AI agents.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Why SpaceManager?

These days, when I do "vibe coding," I hardly look at the code. I'm always just talking to agents after running them in VS Code or a command shell. But VS Code is code-centric, not terminal-centric. Well, I guess that's natural since it's a traditional IDE.

**That's why I created an IDE exclusively for the CLI.**

Every workspace is a real tmux session, attached by name the moment you select it. Open a shell tab, a second tmux tab, a second window — the terminal is the whole interface.

**Happy vibe coding!**

## Features

- **Real Terminal**: xterm.js-based terminal (same engine as VS Code) — full mouse support, TUI apps, IME, native copy/paste
- **tmux-Native Workspaces**: Selecting a workspace auto-attaches to its tmux session by name. Pair with tmux-resurrect/continuum and everything survives reboots
- **Multi-Window**: Every window is a full IDE — put a different project on each Space
- **Terminal Tabs**: Plain shell tabs or extra tmux session tabs, drag to reorder
- **File Browser**: Read-only project tree in the sidebar for quick reference

## Demo

![SpaceManager Demo](demo.gif)

## Requirements

- macOS 14.0+
- Xcode 15.0+ (for building)
- [tmux](https://github.com/tmux/tmux) installed and on `PATH` (workspaces show a banner and fall back to plain shell tabs if it's missing)

## Installation

### Build from Source

```bash
git clone https://github.com/NEWBIE0413/SpaceManager.git
cd SpaceManager
swift build -c release
```

### Run

```bash
swift run SpaceManager
```

Or open in Xcode:
```bash
open Package.swift
```

## Usage

### Workspaces
- Click "+" next to WORKSPACES to create one — pick a root folder, optionally give it a custom name
- Selecting a workspace auto-attaches its terminal to a tmux session (created if it doesn't exist yet)
- Right-click a workspace → "Show in Finder" or "Delete"

### Tabs
- Click "+" in the tab bar to add a tab: a plain shell tab (no tmux, doesn't survive an app restart) or an extra tmux tab (its own named tmux session, restorable)
- The first tab of a workspace is always its main tmux session
- Drag tabs to reorder them

### tmux Session Name
- Right-click a workspace → "Edit tmux Session Name..." to point it at an existing tmux session instead of the auto-derived one — handy when migrating sessions you already had running before installing SpaceManager
- Leave it blank to fall back to the name derived from the workspace name

### Multi-Window
- `Cmd+N` opens a new window, each with its own sidebar selection and tabs
- Window layout (which workspaces/tabs are open, per window) is saved to `~/.space-manager/window-states.json` and restored on next launch
- Opening the same workspace in two windows attaches two tmux clients to the same session (mirrored) — see [tmux Integration](#tmux-integration) below

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Cmd+N` | New Window |
| `Cmd+Shift+N` | New Workspace |
| `Cmd+T` | New Shell Tab |
| `Cmd+Shift+T` | New tmux Tab |
| `Cmd+Opt+←` / `Cmd+Opt+→` | Previous / Next Tab |

## tmux Integration

SpaceManager doesn't manage tmux sessions itself — it just attaches to them by name, and leaves saving/restoring to your own tmux setup.

- **Session name rule**: a workspace's tmux session name is derived from its workspace name, sanitized — `.`, `:`, and spaces become `-`. Override it per-workspace via the sidebar context menu (see [tmux Session Name](#tmux-session-name) above).
- **Reboot recovery**: install [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) + [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) so your sessions survive a reboot on their own. SpaceManager just re-attaches by name after continuum restores them — it doesn't save or restore session contents.
- **Multi-window mirroring**: opening the same workspace in two windows attaches two tmux clients to one session, so both mirror the same screen. Add this to `~/.tmux.conf` so the shared session sizes itself to whichever client is actually being looked at, instead of clamping to the smallest window:

  ```
  set -g window-size latest
  ```

## Dependencies

None — the terminal is [xterm.js](https://github.com/xtermjs/xterm.js) (the engine VS Code uses), vendored directly in `Sources/SpaceManager/Terminal/Resources/` and rendered in a `WKWebView`. PTY handling is a small local C shim (`Sources/CPty`).

## Project Structure

```
Sources/
├── CPty/                        # forkpty-based PTY shim (C)
└── SpaceManager/
    ├── SpaceManagerApp.swift    # App entry point, window scenes, menu commands
    ├── Models/
    │   ├── Workspace.swift      # Workspace & Project models
    │   ├── TerminalSession.swift    # Tab model (shell / tmux main / tmux extra)
    │   ├── TabSnapshot.swift    # Persisted tab/window state
    │   ├── TmuxBootstrap.swift  # Session name rule, attach/create script, tmux detection
    │   └── DirectoryWatcher.swift   # Sidebar file browser live updates
    ├── Storage/
    │   └── WorkspaceStorage.swift   # JSON persistence (workspaces, window states)
    ├── Terminal/
    │   ├── PTYProcess.swift     # forkpty process wrapper
    │   ├── TerminalWebView.swift    # WKWebView ↔ xterm.js bridge
    │   ├── TerminalSpikeView.swift  # manual verification harness (SM_SPIKE=1)
    │   └── Resources/           # vendored xterm.js, xterm.css, terminal.html
    ├── ViewModels/
    │   └── AppState.swift       # Per-window app state (sessions, tabs, workspace selection)
    └── Views/
        ├── ContentView.swift    # Main two-pane layout
        ├── Theme.swift
        ├── Sidebar/             # Workspace list, project/file browser
        └── TerminalArea/        # Tab bar, terminal view
```

## Contributing

This application is still a work in progress. I look forward to your contributions!

Feel free to submit a Pull Request or open an Issue.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [xterm.js](https://github.com/xtermjs/xterm.js) for the terminal engine
