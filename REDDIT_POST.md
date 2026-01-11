# Reddit Promotional Post

**Title:** I made an IDE that has no code editor - just terminals for AI agents

**Tag:** Showcase

---

**Body:**

I built a macOS app specifically for "vibe coding" - where you're not actually looking at code, just talking to AI agents all day.

The interesting part: VS Code is code-centric (file trees, editors, IntelliSense). But when I'm vibe coding, I literally never use any of that. I just run `claude` or `codex` in a terminal and talk to agents. So I built an IDE that's terminal-centric instead.

**What makes it different:**

- No file explorer - when you select a project, you only see terminals
- No code editor - your agents write all the code
- Multi-agent support - run Claude, Codex, Gemini side-by-side with auto-splitting panes
- **Persistent workspaces** - unlike VS Code or standard shells, your workspace and agents are perfectly preserved when switching between workspaces, and persist even after restarting the app. It's truly built for CLI-based agents.
- TUI launcher - press `1` for Claude, `2` for Codex, `3` for Gemini (like a fighting game character select)

**How I actually use it:**

1. Open a workspace
2. Press `+` to spawn agents
3. Give each agent a different task
4. Watch them work in parallel
5. That's it. That's the whole workflow.

**Features:**

- Drag & drop tabs to reorder agents
- New session or resume previous conversations
- Add custom models with your own commands
- Workspaces to organize multiple projects

The whole point is to stop pretending we need a traditional IDE when we're just prompting AI all day. If your workflow is 90% talking to agents, why have 90% of your screen dedicated to code you're not reading?

Built with Swift/SwiftUI. Native macOS app, no Electron.

Demo GIF and source code: [https://github.com/NEWBIE0413/SpaceManager](https://github.com/NEWBIE0413/SpaceManager)

---

**Suggested Subreddits:**
- r/ClaudeAI
- r/ChatGPTCoding
- r/MacApps
- r/Swift
- r/LocalLLaMA (if you add local model support)
