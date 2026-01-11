# SpaceManager

A native macOS workspace manager with integrated terminal for AI CLI tools.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- **Workspace Management**: Organize multiple projects into workspaces
- **Integrated Terminal**: Full terminal emulation powered by SwiftTerm
- **Multi-Agent Support**: Run multiple AI agents side-by-side with auto-splitting panes
- **Quick Launcher**: TUI-based launcher for AI CLI tools (Claude, Codex, Gemini)
- **Session Modes**: Start new sessions or resume previous ones
- **Customizable**: Add your own models and commands

## Screenshots

```
┌─────────────────┬───────────────────────────────────────────────────┐
│                 │  [Agent 1] [Agent 2] [+]                          │
│  WORKSPACES     ├─────────────────────┬─────────────────────────────┤
│  ▶ my-project   │  Agent 1            │  Agent 2                    │
│    work-stuff   │  $ claude           │  $ codex                    │
│                 │  > Hello!           │  > Ready...                 │
│  ─────────────  │                     │                             │
│  PROJECTS       │                     │                             │
│  ├─ src/        │                     │                             │
│  └─ lib/        │                     │                             │
└─────────────────┴─────────────────────┴─────────────────────────────┘
```

## Requirements

- macOS 14.0+
- Xcode 15.0+ (for building)

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

Or open in Xcode and build:
```bash
open Package.swift
```

## Usage

### Workspaces
- Click "+" to create a new workspace
- Select a root folder for your workspace
- Add project folders within the workspace

### Agents
- Click "+" in the tab bar to add a new agent
- Use the TUI launcher to select an AI model
- Choose "New Session" or "Resume" mode
- Multiple agents auto-split the terminal pane

### Keyboard Shortcuts (in Launcher)
- `1-4` - Quick select model
- `N` - New session
- `R` - Resume session
- `C` - Custom command
- `ESC` - Go back

### Settings
- Configure model commands in Settings (gear icon)
- Add custom models with new/resume commands

## Supported AI CLI Tools

| Model | New Session | Resume |
|-------|-------------|--------|
| Claude | `claude` | `claude --resume` |
| Codex | `codex` | `codex --continue` |
| Gemini | `gemini` | `gemini --resume` |
| Shell | (raw shell) | - |

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - Terminal emulation

## Project Structure

```
Sources/SpaceManager/
├── SpaceManagerApp.swift        # App entry point
├── Models/
│   ├── Workspace.swift          # Workspace & Project models
│   ├── CommandPreset.swift      # Model configurations
│   └── AgentSession.swift       # Terminal session management
├── Storage/
│   └── WorkspaceStorage.swift   # JSON persistence
├── ViewModels/
│   └── AppState.swift           # App state management
└── Views/
    ├── ContentView.swift        # Main layout
    ├── Sidebar/                 # Workspace/Project list
    └── TerminalArea/            # Terminal & launcher views
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza for the excellent terminal emulation library
