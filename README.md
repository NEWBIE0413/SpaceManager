# SpaceManager

[![SpaceManager demo](demo.gif)](docs/demo.mp4)

<p align="center"><a href="docs/demo.mp4"><strong>전체 데모 영상 보기 (MP4)</strong></a></p>

**tmux 기반 smux 스킬 멀티 에이전트 오케스트레이션을 위한 macOS IDE.**

SpaceManager는 프로젝트와 에이전트를 터미널 pane 단위로 운영하는 네이티브 작업 공간입니다. 앱이 tmux를 대체하거나 소유하지 않고, 이미 살아 있는 세션을 이름으로 따라가며 여러 창에서 일관되게 보여줍니다.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## 주요 기능

- **워크스페이스 = tmux 세션 팔로워** — 폴더를 선택하면 같은 이름의 tmux 세션에 attach합니다. 세션 저장과 복원은 tmux-resurrect/continuum에 맡기고 SpaceManager는 기존 서버를 소유하거나 종료하지 않습니다.
- **에이전트 pane 오케스트레이션** — [`tmux-bridge`](https://github.com/shownpana)를 통해 Claude, Codex, Gemini 같은 CLI 에이전트가 pane을 찾고 읽고 메시지를 주고받습니다. 여러 프로젝트와 에이전트의 상태를 한 화면에서 확인할 수 있습니다.
- **Hermes 퀵 창** — 프로젝트를 만들지 않고 `~/cld`에서 일상 Claude 대화를 시작합니다. transcript의 `ai-title`로 탭과 창 제목이 갱신되며, 최근 대화를 클릭해 바로 이어갈 수 있습니다.
- **Claude + Codex 모델 선택** — 모델과 effort를 컴포저에서 선택합니다. Claude는 직접 실행하고, 선택적 로컬 Claude proxy를 사용하면 Codex 구독 OAuth 모델도 같은 UI에서 시작하거나 proxy 세션 안에서 전환할 수 있습니다.
- **transcript 기반 활동 표시** — Claude, Codex, Gemini transcript를 스캔해 워크스페이스별 최근 활동과 실제 생성 중 상태를 사이드바 dot으로 보여줍니다.
- **네이티브 멀티 윈도우** — 창마다 독립적인 워크스페이스 상태를 유지하며, 다른 창이 소유한 워크스페이스로도 한 번에 점프합니다.
- **터미널 중심 UI** — xterm.js WebGL 렌더링, PTY, 마우스 입력, TUI, 한글 IME, 네이티브 복사·붙여넣기를 지원합니다. 유리 사이드바와 떠 있는 터미널 카드가 작업 공간을 분리합니다.

## Architecture

```text
SwiftUI + AppKit window chrome
├── per-window AppState and workspace registry
├── transcript scanners (Claude / Codex / Gemini)
├── Hermes quick conversations and model catalog
└── terminal card
    ├── WKWebView + vendored xterm.js (terminal surface only)
    ├── local forkpty shim
    └── tmux client attach
```

- 창, 사이드바, 상태 관리는 **SwiftUI + AppKit** 네이티브 코드입니다.
- 웹 기술은 터미널 표면의 **WKWebView + xterm.js**에만 사용합니다.
- PTY는 작은 로컬 C shim이 담당합니다.
- tmux는 진실원입니다. SpaceManager는 순수 팔로워로 attach하며 세션 수명주기를 가로채지 않습니다.

## Requirements

- macOS 14.0+
- Xcode 15.0+ 또는 호환 Swift toolchain
- [`tmux`](https://github.com/tmux/tmux)
- 재부팅 복원이 필요하면 [`tmux-resurrect`](https://github.com/tmux-plugins/tmux-resurrect) + [`tmux-continuum`](https://github.com/tmux-plugins/tmux-continuum)

## Build

```bash
git clone https://github.com/NEWBIE0413/SpaceManager.git
cd SpaceManager
swift build -c release
swift run SpaceManager
```

터미널 의존성은 저장소에 포함되어 있어 별도 JavaScript 설치 과정이 없습니다.

## Quick Start

1. `WORKSPACES` 옆 `+`에서 프로젝트 루트 폴더를 추가합니다.
2. 워크스페이스를 선택하면 메인 tmux 세션에 자동으로 attach됩니다.
3. 사이드바의 `+`로 shell 또는 추가 tmux 탭을 열고, `smux`로 에이전트 pane을 연결합니다.
4. `Cmd+Opt+N`으로 Hermes를 열면 폴더 설정 없이 새 대화를 시작하거나 최근 대화를 재개할 수 있습니다.

| 단축키 | 동작 |
|---|---|
| `Cmd+N` | 새 워크스페이스 창 |
| `Cmd+Opt+N` | Hermes 퀵 창 |
| `Cmd+Shift+N` | 새 워크스페이스 추가 |
| `Cmd+T` | 새 shell 탭 / Hermes 즉시 대화 |
| `Cmd+Shift+T` | 새 tmux 탭 |
| `Cmd+Opt+←` / `Cmd+Opt+→` | 이전 / 다음 탭 |

동일 워크스페이스를 여러 창에서 열면 하나의 tmux 세션에 여러 client가 attach됩니다. 화면 크기는 현재 보고 있는 client를 따르도록 다음 설정을 권장합니다.

```tmux
set -g window-size latest
```

## Credits

- Demo recorded with [OpenScreen](https://github.com/siddharthvaddem/openscreen).
- Agent orchestration powered by the `smux` skill by [shownpana](https://github.com/shownpana).
- Terminal rendering powered by [xterm.js](https://github.com/xtermjs/xterm.js).

## License

[MIT](LICENSE)
