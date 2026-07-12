# SpaceManager 재설계 구현 플랜: 순수 터미널 + tmux 중심 + 멀티윈도우

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SpaceManager의 터미널을 xterm.js+WKWebView로 교체하고, 워크스페이스를 tmux 세션에 이름 규칙으로 자동 연결하며, VS Code식 멀티윈도우를 지원한다.

**Architecture:** 기존 뼈대(AppState/WorkspaceStorage/사이드바/탭바) 유지 + 수술. 터미널 하나 = `PTYProcess`(forkpty) + `TerminalWebView`(WKWebView에 번들된 xterm.js) 한 쌍을 `TerminalSession`이 소유. `WorkspaceStorage.shared`는 전역, `AppState`는 창마다 1개. tmux 세션의 저장/복원은 유저의 tmux-resurrect/continuum이 담당하고 앱은 이름으로 attach만 한다.

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit / WebKit(WKWebView) / xterm.js 5.5.0 (vendored) / SPM. SwiftTerm 의존성은 완전 제거.

**Spec:** `docs/superpowers/specs/2026-07-12-tmux-terminal-redesign-design.md`

## Global Constraints

- macOS 14.0+, swift-tools-version 5.9 (기존 Package.swift 유지)
- 런타임 네트워크 의존 금지 — xterm.js는 고정 버전 vendored, CDN 사용 금지
- 기존 소스 뼈대 유지 — 파일 신설·삭제는 이 플랜에 명시된 것만
- 매 태스크 종료 시 `swift build` 성공(그린) 상태로 커밋
- tmux 세션명 금지 문자: `.` `:` (공백도 `-`로 치환). 빈 결과는 `"workspace"` 폴백
- 저장 경로: `~/.space-manager/` (기존). 신규 파일은 `window-states.json`만. `models.json`·`agent-states.json`은 로드 중단하되 삭제하지 않음
- 셸 스폰 규약(기존 계승): 실행 파일 `$SHELL`(폴백 `/bin/zsh`), argv[0]은 `-zsh` 형태(로그인 셸), tmux 실행은 `-lc <script>` 경유 (로그인 셸 PATH로 homebrew tmux를 찾기 위함)
- 커밋 메시지 끝에 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` 추가

## 최종 파일 구조

```
Package.swift                                  # 수정: SwiftTerm 제거, CPty 타겟·리소스·테스트 타겟 추가
Sources/CPty/                                  # 신규: forkpty/ioctl C 심
├── include/CPty.h
└── shim.c
Sources/SpaceManager/
├── SpaceManagerApp.swift                      # 수정: 멀티윈도우, 커맨드 재편
├── Models/
│   ├── Workspace.swift                        # 수정: tmuxSessionName 추가, orchestratorEnabled 제거
│   ├── TerminalSession.swift                  # 신규(AgentSession.swift 대체): 탭 세션
│   ├── TmuxBootstrap.swift                    # 신규: 세션명 sanitize·부트스트랩 스크립트·tmux 감지
│   ├── TabSnapshot.swift                      # 신규(AgentSessionSnapshot.swift 대체): 탭/창 영속 모델
│   └── DirectoryWatcher.swift                 # 유지
├── Terminal/
│   ├── PTYProcess.swift                       # 신규
│   ├── TerminalWebView.swift                  # 신규
│   └── Resources/                             # 신규: terminal.html, xterm.js, xterm.css, addon-fit.js, addon-webgl.js
├── Storage/WorkspaceStorage.swift             # 수정: 모델·에이전트 상태 제거, WindowState 추가
├── ViewModels/AppState.swift                  # 수정: 다이어트 + 탭/창 상태
├── Views/
│   ├── ContentView.swift                      # 수정: 시트 정리, per-window AppState
│   ├── Theme.swift                            # 신규: warmPink 색상 이동
│   ├── Sidebar/ (SidebarView, WorkspaceListView, ProjectListView)  # 소폭 수정/유지
│   └── TerminalArea/
│       ├── AgentTabBar.swift                  # 수정: "+" 메뉴
│       ├── TerminalAreaView.swift             # 수정: 단일 뷰만
│       └── AgentTerminalView.swift            # 수정: WKWebView 래핑
Tests/SpaceManagerTests/                       # 신규
├── PTYProcessTests.swift
├── TmuxBootstrapTests.swift
└── StorageRoundtripTests.swift
삭제: Models/{PlanOrchestrator,CommandPreset,AgentSession,AgentSessionSnapshot}.swift,
      Views/TerminalArea/{LauncherTUIView,CommandPresetBar}.swift, Packages/SwiftTerm/
```

**태스크 순서 (스파이크 우선으로 리스크 소거):**
1. xterm 에셋 vendoring → 2. PTYProcess+테스트 → 3. TerminalWebView 브릿지 → 4. 스파이크 수동검증 게이트 → 5. 기능 다이어트 → 6. tmux 유틸+테스트 → 7. TerminalSession 교체(SwiftTerm 제거) → 8. 탭 UI → 9. 창 상태 영속화+테스트 → 10. 멀티윈도우 → 11. 최종 검증·마이그레이션

---

### Task 1: xterm.js 에셋 vendoring + SPM 리소스 등록

**Files:**
- Create: `Sources/SpaceManager/Terminal/Resources/{xterm.js, xterm.css, addon-fit.js, addon-webgl.js, terminal.html}`
- Modify: `Package.swift`

**Interfaces:**
- Produces: `terminal.html`이 로드 완료 시 `window.webkit.messageHandlers.bridge.postMessage({type:"ready", payload:{cols,rows}})`를 보냄. Swift가 호출할 JS 전역 함수: `smWrite(b64)`, `smPaste(text)`, `smGetSelection()`, `smSelectAll()`, `smSetTheme(theme)`, `smFocus()`. JS→Swift 메시지 타입: `ready`, `input`(payload: string), `resize`(payload: {cols, rows})
- 리소스는 `Bundle.module.url(forResource:withExtension:subdirectory: "Resources")`로 접근

- [ ] **Step 1: xterm.js 배포판 다운로드 (고정 버전, npm pack)**

```bash
WORK=$(mktemp -d) && cd "$WORK"
npm pack @xterm/xterm@5.5.0 @xterm/addon-fit@0.10.0 @xterm/addon-webgl@0.18.0
mkdir xterm fit webgl
tar xzf xterm-xterm-5.5.0.tgz -C xterm
tar xzf xterm-addon-fit-0.10.0.tgz -C fit
tar xzf xterm-addon-webgl-0.18.0.tgz -C webgl
RES=/Users/tmdgus/myworld/WorkspaceManager/Sources/SpaceManager/Terminal/Resources
mkdir -p "$RES"
cp xterm/package/lib/xterm.js xterm/package/css/xterm.css "$RES/"
cp fit/package/lib/addon-fit.js "$RES/"
cp webgl/package/lib/addon-webgl.js "$RES/"
ls -la "$RES"
```

Expected: 4개 파일 복사됨. (UMD 빌드라 `window.Terminal`, `window.FitAddon.FitAddon`, `window.WebglAddon.WebglAddon` 전역 노출)

- [ ] **Step 2: terminal.html 작성**

`Sources/SpaceManager/Terminal/Resources/terminal.html`:

```html
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<link rel="stylesheet" href="xterm.css">
<style>
  html, body { margin: 0; padding: 0; height: 100%; overflow: hidden; background: transparent; }
  #terminal { width: 100%; height: 100%; }
</style>
</head>
<body>
<div id="terminal"></div>
<script src="xterm.js"></script>
<script src="addon-fit.js"></script>
<script src="addon-webgl.js"></script>
<script>
  const term = new Terminal({
    allowProposedApi: true,
    cursorBlink: true,
    cursorStyle: 'bar',
    fontSize: 13,
    fontFamily: '"D2Coding", "NanumGothicCoding", "Noto Sans Mono CJK KR", "SF Mono", Menlo, monospace',
    scrollback: 10000,
    macOptionIsMeta: false,
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById('terminal'));
  try { term.loadAddon(new WebglAddon.WebglAddon()); } catch (e) { /* webgl 불가 시 canvas 폴백 */ }
  fit.fit();

  function post(type, payload) {
    window.webkit.messageHandlers.bridge.postMessage({ type: type, payload: payload === undefined ? null : payload });
  }

  // 키입력·IME 조합 결과·마우스 리포트 전부 onData로 들어온다
  term.onData(function (d) { post('input', d); });
  term.onResize(function (s) { post('resize', { cols: s.cols, rows: s.rows }); });

  // Cmd+C/V/A는 네이티브(Swift)가 처리하므로 xterm이 삼키지 않게 통과시킨다
  term.attachCustomKeyEventHandler(function (e) {
    if (e.metaKey && ['c', 'v', 'a'].indexOf(e.key.toLowerCase()) >= 0) { return false; }
    return true;
  });

  new ResizeObserver(function () { fit.fit(); }).observe(document.getElementById('terminal'));

  // Swift가 호출하는 API
  window.smWrite = function (b64) {
    const raw = atob(b64);
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i); }
    term.write(bytes); // 바이트 단위 write — 멀티바이트(UTF-8) 경계는 xterm 디코더가 처리
  };
  window.smPaste = function (text) { term.paste(text); };
  window.smGetSelection = function () { return term.getSelection(); };
  window.smSelectAll = function () { term.selectAll(); };
  window.smFocus = function () { term.focus(); };
  window.smSetTheme = function (theme) { term.options.theme = theme; };

  post('ready', { cols: term.cols, rows: term.rows });
</script>
</body>
</html>
```

- [ ] **Step 3: Package.swift에 리소스 등록**

`Package.swift`의 executableTarget을 다음으로 교체 (SwiftTerm 의존성은 Task 7에서 제거하므로 아직 유지):

```swift
.executableTarget(
    name: "SpaceManager",
    dependencies: [
        .product(name: "SwiftTerm", package: "SwiftTerm")
    ],
    path: "Sources/SpaceManager",
    resources: [
        .copy("Terminal/Resources")
    ]
),
```

- [ ] **Step 4: 빌드 및 번들 확인**

```bash
cd /Users/tmdgus/myworld/WorkspaceManager && swift build 2>&1 | tail -5
ls .build/debug/SpaceManager_SpaceManager.bundle/Resources/
```

Expected: 빌드 성공, 번들 안에 terminal.html 포함 5개 파일.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpaceManager/Terminal/Resources Package.swift
git commit -m "feat: vendor xterm.js 5.5.0 assets and terminal.html bridge page"
```

---

### Task 2: CPty 심 + PTYProcess + 테스트 타겟

**Files:**
- Create: `Sources/CPty/include/CPty.h`, `Sources/CPty/shim.c`
- Create: `Sources/SpaceManager/Terminal/PTYProcess.swift`
- Create: `Tests/SpaceManagerTests/PTYProcessTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: 없음 (독립 모듈)
- Produces:
  ```swift
  final class PTYProcess {
      var onOutput: ((Data) -> Void)?   // 백그라운드 큐에서 호출됨
      var onExit: ((Int32) -> Void)?    // exit code, 백그라운드 큐에서 호출됨
      func start(executable: String, execName: String, arguments: [String],
                 environment: [String: String], workingDirectory: String,
                 cols: UInt16, rows: UInt16) throws
      func write(_ data: Data)
      func resize(cols: UInt16, rows: UInt16)
      func terminate()
      private(set) var isRunning: Bool
  }
  enum PTYError: Error { case forkFailed(Int32), alreadyStarted }
  ```

- [ ] **Step 1: C 심 작성 (forkpty와 winsize ioctl은 Swift에 노출되지 않으므로)**

`Sources/CPty/include/CPty.h`:

```c
#ifndef CPTY_H
#define CPTY_H

#include <util.h>
#include <sys/ioctl.h>

static inline int cpty_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

#endif
```

`Sources/CPty/shim.c`:

```c
#include "include/CPty.h"
```

- [ ] **Step 2: Package.swift에 CPty·테스트 타겟 추가**

targets 배열을 다음으로 교체:

```swift
targets: [
    .target(
        name: "CPty",
        path: "Sources/CPty"
    ),
    .executableTarget(
        name: "SpaceManager",
        dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            "CPty"
        ],
        path: "Sources/SpaceManager",
        resources: [
            .copy("Terminal/Resources")
        ]
    ),
    .testTarget(
        name: "SpaceManagerTests",
        dependencies: ["SpaceManager"],
        path: "Tests/SpaceManagerTests"
    )
]
```

- [ ] **Step 3: 실패하는 테스트 작성**

`Tests/SpaceManagerTests/PTYProcessTests.swift`:

```swift
import XCTest
@testable import SpaceManager

final class PTYProcessTests: XCTestCase {
    func testEchoProducesOutputAndExits() throws {
        let pty = PTYProcess()
        let gotOutput = expectation(description: "output")
        gotOutput.assertForOverFulfill = false
        let exited = expectation(description: "exit")
        var collected = Data()
        let lock = NSLock()

        pty.onOutput = { data in
            lock.lock(); collected.append(data); lock.unlock()
            gotOutput.fulfill()
        }
        pty.onExit = { _ in exited.fulfill() }

        try pty.start(
            executable: "/bin/echo", execName: "echo", arguments: ["hello-pty"],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: NSHomeDirectory(), cols: 80, rows: 24
        )
        wait(for: [gotOutput, exited], timeout: 10)
        lock.lock()
        let text = String(data: collected, encoding: .utf8) ?? ""
        lock.unlock()
        XCTAssertTrue(text.contains("hello-pty"))
    }

    func testWriteReachesChildProcess() throws {
        let pty = PTYProcess()
        let sawEcho = expectation(description: "cat echoes input")
        pty.onOutput = { data in
            if let s = String(data: data, encoding: .utf8), s.contains("ping-42") {
                sawEcho.fulfill()
            }
        }
        try pty.start(
            executable: "/bin/cat", execName: "cat", arguments: [],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: NSHomeDirectory(), cols: 80, rows: 24
        )
        pty.write(Data("ping-42\n".utf8))
        wait(for: [sawEcho], timeout: 10)
        pty.terminate()
    }
}
```

- [ ] **Step 4: 테스트 실패 확인**

```bash
swift test --filter PTYProcessTests 2>&1 | tail -5
```

Expected: 컴파일 실패 — "cannot find 'PTYProcess' in scope"

- [ ] **Step 5: PTYProcess 구현**

`Sources/SpaceManager/Terminal/PTYProcess.swift`:

```swift
import Foundation
import CPty

enum PTYError: Error {
    case forkFailed(Int32)
    case alreadyStarted
}

/// forkpty로 유저 셸을 스폰하고 마스터 fd 입출력을 중계한다.
final class PTYProcess {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var isRunning = false

    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let ioQueue = DispatchQueue(label: "space-manager.pty.io")

    func start(executable: String, execName: String, arguments: [String],
               environment: [String: String], workingDirectory: String,
               cols: UInt16, rows: UInt16) throws {
        guard pid == -1 else { throw PTYError.alreadyStarted }

        // fork 이후 child에서는 async-signal-safe 함수만 안전하므로
        // argv/envp C 배열은 fork 전에 만들어 둔다.
        var argv: [UnsafeMutablePointer<CChar>?] = ([execName] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        let cwd = strdup(workingDirectory)
        let exe = strdup(executable)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(cwd)
            free(exe)
        }

        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &ws)
        if child < 0 {
            throw PTYError.forkFailed(errno)
        }
        if child == 0 {
            // 자식: 작업 디렉토리 이동 후 즉시 exec
            _ = chdir(cwd)
            _ = execve(exe, argv, envp)
            _exit(127)
        }

        masterFD = master
        pid = child
        isRunning = true

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(self.masterFD, &buffer, buffer.count)
            if n > 0 {
                self.onOutput?(Data(bytes: buffer, count: n))
            } else {
                self.readSource?.cancel()
            }
        }
        readSource.resume()
        self.readSource = readSource

        let exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: ioQueue)
        exitSource.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
            self.isRunning = false
            self.readSource?.cancel()
            self.exitSource?.cancel()
            self.onExit?(code)
        }
        exitSource.resume()
        self.exitSource = exitSource
    }

    func write(_ data: Data) {
        ioQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(self.masterFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        _ = cpty_set_winsize(masterFD, rows, cols)
    }

    func terminate() {
        guard pid > 0, isRunning else { return }
        kill(pid, SIGHUP)
    }

    deinit {
        readSource?.cancel()
        exitSource?.cancel()
        if masterFD >= 0 { close(masterFD) }
        if pid > 0, isRunning { kill(pid, SIGHUP) }
    }
}
```

- [ ] **Step 6: 테스트 통과 확인**

```bash
swift test --filter PTYProcessTests 2>&1 | tail -5
```

Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
git add Sources/CPty Sources/SpaceManager/Terminal/PTYProcess.swift Tests Package.swift
git commit -m "feat: add PTYProcess (forkpty-based) with CPty shim and tests"
```

---

### Task 3: TerminalWebView (WKWebView ↔ xterm.js 브릿지)

**Files:**
- Create: `Sources/SpaceManager/Terminal/TerminalWebView.swift`

**Interfaces:**
- Consumes: Task 1의 terminal.html JS API (`smWrite` 등), 메시지 타입 `ready`/`input`/`resize`
- Produces:
  ```swift
  final class TerminalWebView: NSView {
      var onUserInput: ((Data) -> Void)?          // 메인 큐
      var onResize: ((UInt16, UInt16) -> Void)?   // (cols, rows), 메인 큐
      var onReady: (() -> Void)?                  // 페이지 로드/리로드마다 호출
      var onWebProcessCrash: (() -> Void)?
      func feed(_ data: Data)        // PTY 출력 → 8ms 배칭 → xterm (스레드 세이프)
      func focusTerminal()
      func reloadPage()              // 크래시 복구용
  }
  ```
- Cmd+C/V/A는 이 뷰의 `performKeyEquivalent`가 네이티브 NSPasteboard로 처리 (스펙 §4)

- [ ] **Step 1: TerminalWebView 구현**

`Sources/SpaceManager/Terminal/TerminalWebView.swift`:

```swift
import AppKit
import WebKit

/// WKWebView에 번들된 xterm.js 페이지를 띄우고 PTY와 중계한다.
/// 출력은 8ms 코얼레싱 배칭 후 base64로 전달한다 (폭주 출력 시 브릿지 병목 방지).
final class TerminalWebView: NSView {
    var onUserInput: ((Data) -> Void)?
    var onResize: ((UInt16, UInt16) -> Void)?
    var onReady: (() -> Void)?
    var onWebProcessCrash: (() -> Void)?

    private let webView: WKWebView
    private var isReady = false
    private var pendingOutput = Data()
    private var flushScheduled = false

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: frame, configuration: config)
        super.init(frame: frame)

        config.userContentController.add(BridgeProxy(owner: self), name: "bridge")
        webView.navigationDelegate = navigationProxy
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        loadPage()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private lazy var navigationProxy = NavigationProxy(owner: self)

    private func loadPage() {
        guard let html = Bundle.module.url(forResource: "terminal", withExtension: "html", subdirectory: "Resources") else {
            assertionFailure("terminal.html missing from bundle")
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func reloadPage() {
        isReady = false
        loadPage()
    }

    // MARK: - PTY → JS (배칭)

    func feed(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingOutput.append(data)
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) {
                self.flushScheduled = false
                self.flushOutput()
            }
        }
    }

    private func flushOutput() {
        guard isReady, !pendingOutput.isEmpty else { return }
        let b64 = pendingOutput.base64EncodedString()
        pendingOutput.removeAll(keepingCapacity: true)
        webView.evaluateJavaScript("window.smWrite('\(b64)')", completionHandler: nil)
    }

    // MARK: - 포커스/테마

    func focusTerminal() {
        window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.smFocus()", completionHandler: nil)
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        super.mouseDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme: String
        if dark {
            theme = #"{"background":"#1e1e1e","foreground":"#d4d4d4","cursor":"#d4d4d4","selectionBackground":"#264f78"}"#
        } else {
            theme = #"{"background":"#ffffff","foreground":"#1e1e1e","cursor":"#1e1e1e","selectionBackground":"#b5d5ff"}"#
        }
        webView.evaluateJavaScript("window.smSetTheme(\(theme))", completionHandler: nil)
    }

    // MARK: - 클립보드 (네이티브 단일 경로, 스펙 §4)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c":
            webView.evaluateJavaScript("window.smGetSelection()") { result, _ in
                guard let text = result as? String, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        case "v":
            if let text = NSPasteboard.general.string(forType: .string),
               let data = try? JSONEncoder().encode([text]),
               let json = String(data: data, encoding: .utf8) {
                // 배열로 인코딩해 JS 문자열 이스케이프를 JSON에 위임
                webView.evaluateJavaScript("window.smPaste(\(json)[0])", completionHandler: nil)
            }
            return true
        case "a":
            webView.evaluateJavaScript("window.smSelectAll()", completionHandler: nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - JS → Swift

    fileprivate func handleBridgeMessage(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            applyTheme()
            flushOutput()
            onReady?()
        case "input":
            if let s = dict["payload"] as? String {
                onUserInput?(Data(s.utf8))
            }
        case "resize":
            if let p = dict["payload"] as? [String: Any],
               let cols = p["cols"] as? Int, let rows = p["rows"] as? Int {
                onResize?(UInt16(cols), UInt16(rows))
            }
        default:
            break
        }
    }

    fileprivate func handleWebProcessCrash() {
        isReady = false
        onWebProcessCrash?()
    }
}

/// WKUserContentController는 핸들러를 강참조하므로 weak 프록시로 순환 참조를 끊는다.
private final class BridgeProxy: NSObject, WKScriptMessageHandler {
    weak var owner: TerminalWebView?
    init(owner: TerminalWebView) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleBridgeMessage(message.body)
    }
}

private final class NavigationProxy: NSObject, WKNavigationDelegate {
    weak var owner: TerminalWebView?
    init(owner: TerminalWebView) { self.owner = owner }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.handleWebProcessCrash()
    }
}
```

- [ ] **Step 2: 빌드 확인**

```bash
swift build 2>&1 | tail -3
```

Expected: Build complete. (경고가 있으면 수정)

- [ ] **Step 3: Commit**

```bash
git add Sources/SpaceManager/Terminal/TerminalWebView.swift
git commit -m "feat: add TerminalWebView with batched xterm.js bridge and native clipboard"
```

---

### Task 4: 스파이크 모드 — 엔진 수동 검증 게이트

**Files:**
- Create: `Sources/SpaceManager/Terminal/TerminalSpikeView.swift`
- Modify: `Sources/SpaceManager/SpaceManagerApp.swift` (body의 WindowGroup 내부만)

**Interfaces:**
- Consumes: `PTYProcess`, `TerminalWebView` (Task 2·3의 시그니처 그대로)
- Produces: 없음 (검증용, Task 11에서 유지 여부 결정 — 환경변수 없으면 완전 무해)

- [ ] **Step 1: 스파이크 뷰 작성**

`Sources/SpaceManager/Terminal/TerminalSpikeView.swift`:

```swift
import SwiftUI

/// SM_SPIKE=1 환경변수로 실행 시 앱 대신 뜨는 검증용 단일 터미널.
/// 홈 디렉토리에서 sm-spike라는 tmux 세션에 attach한다.
struct TerminalSpikeView: NSViewRepresentable {
    final class Holder {
        let pty = PTYProcess()
        let view = TerminalWebView(frame: .zero)
        var started = false
    }

    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> TerminalWebView {
        let holder = context.coordinator
        let view = holder.view
        let pty = holder.pty

        view.onUserInput = { pty.write($0) }
        view.onResize = { cols, rows in pty.resize(cols: cols, rows: rows) }
        pty.onOutput = { [weak view] data in view?.feed(data) }
        view.onReady = {
            guard !holder.started else { return }
            holder.started = true
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            let script = "if tmux has-session -t sm-spike 2>/dev/null; then exec tmux attach-session -t sm-spike; else exec tmux new-session -s sm-spike; fi"
            try? pty.start(
                executable: shell,
                execName: "-" + (shell as NSString).lastPathComponent,
                arguments: ["-lc", script],
                environment: env,
                workingDirectory: NSHomeDirectory(),
                cols: 80, rows: 24
            )
        }
        return view
    }

    func updateNSView(_ nsView: TerminalWebView, context: Context) {}
}
```

- [ ] **Step 2: 앱 진입점에 스파이크 분기 추가**

`SpaceManagerApp.swift`의 `WindowGroup` 내부를:

```swift
WindowGroup {
    if ProcessInfo.processInfo.environment["SM_SPIKE"] == "1" {
        TerminalSpikeView()
            .frame(minWidth: 900, minHeight: 600)
    } else {
        ContentView()
            .environmentObject(appState)
            .frame(minWidth: 900, minHeight: 600)
    }
}
```

- [ ] **Step 3: 스파이크 실행 + 수동 체크리스트 (스펙 §8의 1~4)**

```bash
swift build && SM_SPIKE=1 swift run SpaceManager
```

유저(또는 실행자)가 직접 확인 — **전부 통과해야 다음 태스크 진행**:
1. tmux 마우스: `tmux split-window`로 패널 2개 → 클릭 전환, 휠 스크롤(copy-mode 진입·스크롤), 경계 드래그 리사이즈
2. 드래그로 텍스트 선택 → Cmd+C → 메모장에 붙여넣기 확인 / 메모장에서 복사 → Cmd+V 확인
3. 한글 입력: `echo 안녕하세요` 조합 표시·백스페이스·Enter 정상
4. `claude` 또는 `vim`, `htop` 실행 → 풀스크린 TUI 렌더링·창 리사이즈 추종 확인

실패 항목이 있으면 여기서 수정 후 재검증한다 (이 게이트가 엔진 리스크 소거 지점).

- [ ] **Step 4: Commit**

```bash
git add Sources/SpaceManager/Terminal/TerminalSpikeView.swift Sources/SpaceManager/SpaceManagerApp.swift
git commit -m "feat: add SM_SPIKE terminal verification mode (engine checklist passed)"
```

---

### Task 5: 기능 다이어트 — 런처·프리셋·오케스트레이터·설정 제거

**Files:**
- Delete: `Sources/SpaceManager/Views/TerminalArea/LauncherTUIView.swift`, `Sources/SpaceManager/Views/TerminalArea/CommandPresetBar.swift`, `Sources/SpaceManager/Models/PlanOrchestrator.swift`, `Sources/SpaceManager/Models/CommandPreset.swift`
- Create: `Sources/SpaceManager/Views/Theme.swift`, `Sources/SpaceManager/Support/Notifications.swift`
- Modify: `AppState.swift`(전체 교체), `ContentView.swift`(전체 교체), `TerminalAreaView.swift`(전체 교체), `AgentTerminalView.swift`(전체 교체), `AgentTabBar.swift`(2곳), `WorkspaceListView.swift`(오케스트레이터 제거), `Workspace.swift`(전체 교체), `WorkspaceStorage.swift`(축소), `SpaceManagerApp.swift`(커맨드)

**Interfaces:**
- Consumes: 없음
- Produces: 축소된 `AppState`(아래 시그니처) — Task 7이 이 위에서 AgentSession→TerminalSession 치환. `Color.warmPink`/`.warmPinkMuted`는 `Views/Theme.swift`로 이동. `Notification.Name.agentSelectionRequested`는 `Support/Notifications.swift`로 이동
- 참고: 이 시점까지 앱은 여전히 SwiftTerm 터미널로 동작해야 한다 (빌드·실행 그린 유지)

- [ ] **Step 1: 워킹트리 베이스라인 커밋**

워킹트리에 선행 실험(AgentSession tmux 부트스트랩, 탭바 색상 등)이 미커밋 상태다. 이후 커밋이 오염되지 않게 먼저 묶는다:

```bash
cd /Users/tmdgus/myworld/WorkspaceManager
git add Sources && git commit -m "wip: baseline uncommitted terminal/tmux experiments"
```

(주의: `SpaceManager.app/`, `*.dmg`, `*.mov`, `Packages/SwiftTerm` 변경은 추가하지 않는다)

- [ ] **Step 2: Notification.Name 정의 위치 확인**

```bash
grep -rn "Notification.Name(" Sources/SpaceManager/
```

`.agentSelectionRequested`, `.sendTerminalCommand`, `.openSettings` 등의 extension 정의 위치를 확인한다. 삭제 대상 파일(LauncherTUIView/CommandPresetBar)에 있다면 다음 단계의 새 파일이 대체한다.

- [ ] **Step 3: 파일 삭제 및 신규 파일 생성**

```bash
git rm Sources/SpaceManager/Views/TerminalArea/LauncherTUIView.swift \
       Sources/SpaceManager/Views/TerminalArea/CommandPresetBar.swift \
       Sources/SpaceManager/Models/PlanOrchestrator.swift \
       Sources/SpaceManager/Models/CommandPreset.swift
```

`Sources/SpaceManager/Views/Theme.swift`:

```swift
import SwiftUI

extension Color {
    /// Warm pink for active/selected text
    static let warmPink = Color(red: 0.95, green: 0.45, blue: 0.50)
    /// Slightly muted warm pink for section headers
    static let warmPinkMuted = Color(red: 0.78, green: 0.48, blue: 0.50)
}
```

`Sources/SpaceManager/Support/Notifications.swift`:

```swift
import Foundation

extension Notification.Name {
    /// 터미널 클릭 시 해당 탭 선택 요청 (ManagedTerminalView가 게시)
    static let agentSelectionRequested = Notification.Name("agentSelectionRequested")
}
```

(Step 2에서 다른 파일에 중복 정의가 발견되면 그쪽을 지운다. `.sendTerminalCommand`/`.openSettings`는 사용처가 이 태스크에서 사라지므로 정의도 함께 삭제)

- [ ] **Step 4: Workspace.swift 전체 교체 (orchestratorEnabled 제거)**

```swift
import Foundation

/// Represents a single project (folder) in the workspace
struct Project: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var path: String
    var name: String

    init(id: UUID = UUID(), path: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

/// Represents a workspace containing multiple projects
struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var rootPath: String
    var customName: String?
    var additionalProjects: [Project]
    var createdAt: Date
    var updatedAt: Date

    var name: String {
        customName ?? URL(fileURLWithPath: rootPath).lastPathComponent
    }

    var projects: [Project] {
        var all = [Project(path: rootPath)]
        all.append(contentsOf: additionalProjects)
        return all
    }

    init(id: UUID = UUID(), rootPath: String, customName: String? = nil, additionalProjects: [Project] = []) {
        self.id = id
        self.rootPath = rootPath
        self.customName = customName
        self.additionalProjects = additionalProjects
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id, rootPath, customName, additionalProjects, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        additionalProjects = try container.decodeIfPresent([Project].self, forKey: .additionalProjects) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    mutating func addProject(_ project: Project) {
        guard project.path != rootPath,
              !additionalProjects.contains(where: { $0.path == project.path }) else { return }
        additionalProjects.append(project)
        updatedAt = Date()
    }

    mutating func removeProject(id: UUID) {
        additionalProjects.removeAll { $0.id == id }
        updatedAt = Date()
    }

    mutating func rename(to newName: String?) {
        customName = newName?.isEmpty == true ? nil : newName
        updatedAt = Date()
    }

    static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.id == rhs.id
    }
}
```

(기존 저장 JSON의 `orchestratorEnabled` 키는 JSONDecoder가 무시하므로 호환됨)

- [ ] **Step 5: WorkspaceStorage.swift 축소**

다음 심볼과 그 본문을 삭제: `@Published var modelConfigs`, `@Published var agentStates`, `modelConfigsFile`, `agentStatesFile`, `loadModelConfigs()`, `saveModelConfigs()`, `addModelConfig()`, `updateModelConfig()`, `deleteModelConfig()`, `moveModelConfig()`, `reassignShortcuts()`, `resetModelConfigs()`, `loadAgentStates()`, `saveAgentStates()`, `updateAgentState()`, `removeAgentState()`, 그리고 `// MARK: - Model Configs`·`// MARK: - Agent States` 섹션 전체.

`private init()`은 다음으로 교체:

```swift
    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        ensureStorageDirectoryExists()
        loadWorkspaces()
        // models.json·agent-states.json은 더 이상 로드하지 않는다 (파일은 남겨둠 — 롤백 안전)
    }
```

- [ ] **Step 6: AppState.swift 전체 교체 (플랫한 탭 목록, 그룹·분할·오케스트레이터·영속화 제거)**

```swift
import Foundation
import SwiftUI
import Combine

/// 창 하나의 상태. 워크스페이스 목록 자체는 WorkspaceStorage.shared(전역)가 소유한다.
class AppState: ObservableObject {
    @Published var storage = WorkspaceStorage.shared

    @Published var selectedWorkspace: Workspace?
    @Published var selectedProject: Project?

    @Published var agentSessions: [AgentSession] = []
    @Published var selectedAgentSession: AgentSession?
    private var agentSessionsByWorkspace: [UUID: [AgentSession]] = [:]
    private var selectedAgentIdByWorkspace: [UUID: UUID] = [:]

    @Published var showNewWorkspaceSheet = false
    @Published var showAddProjectSheet = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        storage.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .agentSelectionRequested)
            .compactMap { $0.userInfo?["id"] as? UUID }
            .sink { [weak self] sessionId in self?.selectAgentSession(id: sessionId) }
            .store(in: &cancellables)

        if let first = storage.workspaces.first {
            selectWorkspace(first)
        }
    }

    // MARK: - Workspace Management

    func createWorkspace(rootPath: String, customName: String? = nil) {
        let workspace = Workspace(rootPath: rootPath, customName: customName)
        storage.addWorkspace(workspace)
        selectWorkspace(workspace)
    }

    func renameWorkspace(_ workspace: Workspace, to newName: String?) {
        guard var ws = storage.workspace(id: workspace.id) else { return }
        ws.rename(to: newName)
        storage.updateWorkspace(ws)
        if selectedWorkspace?.id == ws.id {
            selectedWorkspace = ws
        }
    }

    func deleteWorkspace(_ workspace: Workspace) {
        storage.deleteWorkspace(workspace)
        if let sessions = agentSessionsByWorkspace[workspace.id] {
            for session in sessions { session.cleanup() }
        }
        agentSessionsByWorkspace[workspace.id] = nil
        selectedAgentIdByWorkspace[workspace.id] = nil
        if selectedWorkspace?.id == workspace.id {
            if let next = storage.workspaces.first {
                selectWorkspace(next)
            } else {
                selectedWorkspace = nil
                selectedProject = nil
                agentSessions = []
                selectedAgentSession = nil
            }
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
        if let current = selectedWorkspace {
            agentSessionsByWorkspace[current.id] = agentSessions
            selectedAgentIdByWorkspace[current.id] = selectedAgentSession?.id
        }
        selectedWorkspace = workspace
        selectedProject = Project(path: workspace.rootPath, name: workspace.name)
        ensureSessions(for: workspace)
    }

    // MARK: - Project Management

    func addProject(path: String) {
        guard var workspace = selectedWorkspace else { return }
        workspace.addProject(Project(path: path))
        storage.updateWorkspace(workspace)
        selectedWorkspace = workspace
    }

    func removeProject(_ project: Project) {
        guard var workspace = selectedWorkspace else { return }
        workspace.removeProject(id: project.id)
        storage.updateWorkspace(workspace)
        selectedWorkspace = workspace
        if selectedProject?.id == project.id {
            selectedProject = workspace.projects.first
        }
    }

    func selectProject(_ project: Project) {
        selectedProject = project
    }

    // MARK: - Terminal Sessions

    func addAgentSession() {
        guard let workspace = selectedWorkspace else { return }
        let session = AgentSession(
            name: "Terminal \(agentSessions.count + 1)",
            workingDirectory: workspace.rootPath
        )
        agentSessions.append(session)
        agentSessionsByWorkspace[workspace.id] = agentSessions
        selectAgentSession(session)
    }

    func removeAgentSession(_ session: AgentSession) {
        session.cleanup()
        agentSessions.removeAll { $0.id == session.id }
        if let workspace = selectedWorkspace {
            agentSessionsByWorkspace[workspace.id] = agentSessions
        }
        if selectedAgentSession?.id == session.id {
            selectedAgentSession = agentSessions.first
        }
    }

    func selectAgentSession(_ session: AgentSession) {
        guard selectedAgentSession?.id != session.id else {
            session.focusTerminal()
            return
        }
        selectedAgentSession = session
        if let workspace = selectedWorkspace {
            selectedAgentIdByWorkspace[workspace.id] = session.id
        }
        session.focusTerminal()
    }

    func selectAgentSession(id: UUID) {
        guard let session = agentSessions.first(where: { $0.id == id }) else { return }
        selectAgentSession(session)
    }

    func moveAgentSession(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < agentSessions.count,
              destinationIndex >= 0, destinationIndex <= agentSessions.count else { return }
        var sessions = agentSessions
        sessions.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
        agentSessions = sessions
        if let workspace = selectedWorkspace {
            agentSessionsByWorkspace[workspace.id] = sessions
        }
    }

    func selectNextAgentSession() {
        guard !agentSessions.isEmpty else { return }
        guard let current = selectedAgentSession,
              let index = agentSessions.firstIndex(where: { $0.id == current.id }) else {
            selectAgentSession(agentSessions[0])
            return
        }
        selectAgentSession(agentSessions[(index + 1) % agentSessions.count])
    }

    func selectPreviousAgentSession() {
        guard !agentSessions.isEmpty else { return }
        guard let current = selectedAgentSession,
              let index = agentSessions.firstIndex(where: { $0.id == current.id }) else {
            selectAgentSession(agentSessions[0])
            return
        }
        selectAgentSession(agentSessions[(index - 1 + agentSessions.count) % agentSessions.count])
    }

    private func ensureSessions(for workspace: Workspace) {
        agentSessions = agentSessionsByWorkspace[workspace.id] ?? []
        if agentSessions.isEmpty {
            addAgentSession()
        } else {
            let storedId = selectedAgentIdByWorkspace[workspace.id]
            selectedAgentSession = agentSessions.first(where: { $0.id == storedId }) ?? agentSessions.first
        }
    }
}
```

- [ ] **Step 7: ContentView.swift 전체 교체**

기존 파일에서 `NewWorkspaceSheet`·`AddProjectSheet` 구조체는 **그대로 유지**하고, `ContentView`를 아래로 교체하며 `ModelConfigEditorSheet`·`SettingsSheet`·`ModelSettingsRow` 구조체를 삭제한다:

```swift
import SwiftUI
import AppKit

/// Main content view with two-pane layout
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 200)
        } detail: {
            TerminalAreaView()
        }
        .sheet(isPresented: $appState.showNewWorkspaceSheet) {
            NewWorkspaceSheet()
        }
        .sheet(isPresented: $appState.showAddProjectSheet) {
            AddProjectSheet()
        }
        .navigationTitle(appState.selectedWorkspace?.name ?? "SpaceManager")
    }
}
```

(`.navigationTitle`이 기존 `NSApp.keyWindow` 타이틀 핵을 대체 — 멀티윈도우 안전)

- [ ] **Step 8: TerminalAreaView.swift 전체 교체**

```swift
import SwiftUI

/// Right pane containing terminal tabs and the selected terminal
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            AgentTabBar()
            SingleTerminalView()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Single terminal view for the selected session
struct SingleTerminalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let session = appState.selectedAgentSession {
            SessionContentView(session: session)
                .id(session.id)
        } else {
            VStack {
                Text("No terminal")
                    .foregroundColor(.secondary)
                Button("New Terminal") {
                    appState.addAgentSession()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SessionContentView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        AgentTerminalView(session: session)
    }
}
```

- [ ] **Step 9: AgentTerminalView.swift 전체 교체 (focusMode·프리셋 알림 제거)**

```swift
import SwiftUI
import SwiftTerm
import AppKit

/// Terminal view for a single session.
/// Uses the terminal owned by the session to ensure persistence.
struct AgentTerminalView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        SessionTerminalWrapper(session: session)
    }
}

struct SessionTerminalWrapper: NSViewRepresentable {
    let session: AgentSession

    func makeNSView(context: Context) -> ManagedTerminalView {
        let terminal = session.getOrCreateTerminal()
        terminal.sessionId = session.id
        session.startTerminalIfNeeded()
        return terminal
    }

    func updateNSView(_ nsView: ManagedTerminalView, context: Context) {
        nsView.sessionId = session.id
        session.focusTerminal()
    }
}
```

(AgentSession.swift의 `ManagedTerminalView`에서 `setHoverFocusEnabled`·`setSelectionActive`·키 모니터 관련 코드는 그대로 둬도 미호출로 무해 — Task 7에서 파일째 사라진다)

- [ ] **Step 10: AgentTabBar.swift 수정 (2곳)**

`ForEach(appState.activeAgentSessions)` → `ForEach(appState.agentSessions)`, `.help("New Agent Tab (auto-splits)")` → `.help("New Terminal Tab")`

- [ ] **Step 11: WorkspaceListView.swift 오케스트레이터 제거**

`WorkspaceRow` 호출부를 다음으로 교체:

```swift
                    WorkspaceRow(
                        workspace: workspace,
                        isSelected: appState.selectedWorkspace?.id == workspace.id
                    )
```

`WorkspaceRow` 선언부에서 `isOrchestratorEnabled`·`onToggleOrchestrator` 프로퍼티와 안테나 `Button(action: onToggleOrchestrator) { ... }` 블록(`.help(...)` 포함)을 삭제.

- [ ] **Step 12: SpaceManagerApp.swift 커맨드 정리**

`.commands` 블록을 다음으로 교체 (WindowGroup의 스파이크 분기는 유지):

```swift
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    appState.showNewWorkspaceSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Terminal Tab") {
                    appState.addAgentSession()
                }
                .keyboardShortcut("t", modifiers: .command)
            }

            CommandMenu("Tabs") {
                Button("Previous Tab") {
                    appState.selectPreviousAgentSession()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("Next Tab") {
                    appState.selectNextAgentSession()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
        }
```

- [ ] **Step 13: 빌드·스모크 테스트**

```bash
swift build 2>&1 | tail -3
swift run SpaceManager
```

Expected: 빌드 성공. 앱 실행 후 — 사이드바에 워크스페이스·파일 트리 표시, 워크스페이스 선택 시 터미널(SwiftTerm, tmux attach) 표시, 탭 추가/닫기/드래그 정상, 설정 기어·런처·그룹 탭 없음.

- [ ] **Step 14: Commit**

```bash
git add -A Sources Tests
git commit -m "refactor: remove launcher/presets/orchestrator/settings — terminal-only diet"
```

---

### Task 6: TmuxBootstrap 유틸 + Workspace.tmuxSessionName + 테스트

**Files:**
- Create: `Sources/SpaceManager/Models/TmuxBootstrap.swift`
- Create: `Tests/SpaceManagerTests/TmuxBootstrapTests.swift`
- Modify: `Sources/SpaceManager/Models/Workspace.swift`, `Sources/SpaceManager/Models/AgentSession.swift`(shQuoted 중복 제거)

**Interfaces:**
- Consumes: 없음
- Produces:
  ```swift
  enum TmuxBootstrap {
      static func sanitizeSessionName(_ raw: String) -> String
      static func attachOrCreateScript(sessionName: String, workingDirectory: String) -> String
      static let isTmuxAvailable: Bool   // 로그인 셸 PATH 기준, 앱 시작 후 첫 접근 시 1회 평가
  }
  extension String { var shQuoted: String }          // internal
  extension Workspace {
      var tmuxSessionName: String?                    // 저장 필드 (커스텀 세션명)
      var effectiveTmuxSessionName: String            // 커스텀 ?? sanitize(name)
  }
  ```

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/SpaceManagerTests/TmuxBootstrapTests.swift`:

```swift
import XCTest
@testable import SpaceManager

final class TmuxBootstrapTests: XCTestCase {
    func testSanitizeReplacesForbiddenChars() {
        XCTAssertEqual(TmuxBootstrap.sanitizeSessionName("my.proj: v2"), "my-proj--v2")
    }

    func testSanitizeEmptyFallsBack() {
        XCTAssertEqual(TmuxBootstrap.sanitizeSessionName("   "), "workspace")
    }

    func testSanitizeKeepsKorean() {
        XCTAssertEqual(TmuxBootstrap.sanitizeSessionName("한글 이름"), "한글-이름")
    }

    func testScriptQuotesSingleQuotes() {
        let s = TmuxBootstrap.attachOrCreateScript(sessionName: "a'b", workingDirectory: "/tmp/it's")
        XCTAssertTrue(s.contains("'a'\"'\"'b'"))
        XCTAssertTrue(s.contains("exec tmux attach-session -t"))
        XCTAssertTrue(s.contains("exec tmux new-session -s"))
    }

    func testWorkspaceEffectiveSessionName() {
        var ws = Workspace(rootPath: "/tmp/My.Project")
        XCTAssertEqual(ws.effectiveTmuxSessionName, "My-Project")
        ws.tmuxSessionName = "legacy-session"
        XCTAssertEqual(ws.effectiveTmuxSessionName, "legacy-session")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
swift test --filter TmuxBootstrapTests 2>&1 | tail -5
```

Expected: 컴파일 실패 — "cannot find 'TmuxBootstrap' in scope"

- [ ] **Step 3: TmuxBootstrap 구현**

`Sources/SpaceManager/Models/TmuxBootstrap.swift`:

```swift
import Foundation

/// tmux 세션명 규칙과 attach/create 부트스트랩.
/// 세션의 저장·복원은 유저의 tmux-resurrect/continuum이 담당하고, 앱은 이름으로 attach만 한다.
enum TmuxBootstrap {
    /// tmux가 금지하는 `.` `:` 및 공백을 `-`로 치환. 빈 결과는 "workspace" 폴백.
    static func sanitizeSessionName(_ raw: String) -> String {
        let mapped = raw.trimmingCharacters(in: .whitespacesAndNewlines).map { ch -> Character in
            (ch == "." || ch == ":" || ch == " ") ? "-" : ch
        }
        let result = String(mapped)
        return result.isEmpty ? "workspace" : result
    }

    /// 있으면 attach, 없으면 해당 디렉토리에서 생성. (`tmux new -A`와 동등, 기존 검증 로직 계승)
    static func attachOrCreateScript(sessionName: String, workingDirectory: String) -> String {
        let name = sessionName.shQuoted
        let dir = workingDirectory.shQuoted
        return """
        if tmux has-session -t \(name) 2>/dev/null; then
          exec tmux attach-session -t \(name)
        else
          exec tmux new-session -s \(name) -c \(dir)
        fi
        """
    }

    /// 로그인 셸 PATH 기준 tmux 존재 여부 (homebrew 경로 포함). 첫 접근 시 1회 평가 후 캐시.
    static let isTmuxAvailable: Bool = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v tmux >/dev/null 2>&1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }()
}

extension String {
    /// POSIX 셸 단일 인용 이스케이프
    var shQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
```

- [ ] **Step 4: AgentSession.swift의 private shQuoted 제거**

`AgentSession.swift` 하단의 `private extension String { var shQuoted ... }` 블록을 삭제한다 (TmuxBootstrap.swift의 internal 버전과 중복되어 모호성 에러 발생).

- [ ] **Step 5: Workspace에 tmuxSessionName 추가**

`Workspace.swift`의 struct에 프로퍼티 추가:

```swift
    var tmuxSessionName: String?      // 커스텀 tmux 세션명 (nil이면 이름에서 파생)
```

`CodingKeys`에 `tmuxSessionName` 추가, `init(from:)`에 추가:

```swift
        tmuxSessionName = try container.decodeIfPresent(String.self, forKey: .tmuxSessionName)
```

멤버와이즈 init에는 `tmuxSessionName: String? = nil` 파라미터와 대입 추가. 그리고 computed 프로퍼티 추가:

```swift
    /// 실제 사용할 tmux 세션명 — 커스텀 값이 있으면 그것, 없으면 이름에서 파생
    var effectiveTmuxSessionName: String {
        if let custom = tmuxSessionName,
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return TmuxBootstrap.sanitizeSessionName(name)
    }
```

- [ ] **Step 6: 테스트 통과 확인**

```bash
swift test --filter TmuxBootstrapTests 2>&1 | tail -5
```

Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
git add Sources/SpaceManager/Models Tests
git commit -m "feat: add TmuxBootstrap (session name rule, attach script, tmux detection)"
```

---

### Task 7: TerminalSession 교체 + SwiftTerm 완전 제거

**Files:**
- Create: `Sources/SpaceManager/Models/TerminalSession.swift`
- Delete: `Sources/SpaceManager/Models/AgentSession.swift`, `Sources/SpaceManager/Models/AgentSessionSnapshot.swift`, `Sources/SpaceManager/Support/Notifications.swift`, `Packages/SwiftTerm/`
- Modify: `Package.swift`(SwiftTerm 제거), `Sources/SpaceManager/Terminal/TerminalWebView.swift`(lastCols/lastRows), `ViewModels/AppState.swift`(타입 치환+탭 API), `Views/TerminalArea/AgentTerminalView.swift`(전체 교체), `Views/TerminalArea/AgentTabBar.swift`(타입 치환), `Views/TerminalArea/TerminalAreaView.swift`(타입 치환)

**Interfaces:**
- Consumes: `PTYProcess`, `TerminalWebView`, `TmuxBootstrap`, `Workspace.effectiveTmuxSessionName` (Task 2·3·6 시그니처)
- Produces:
  ```swift
  enum TabKind: String, Codable { case tmuxMain, shell, tmuxExtra }
  final class TerminalSession: Identifiable, ObservableObject, Equatable {
      let id: UUID
      let kind: TabKind
      @Published var name: String
      @Published var isRunning: Bool
      @Published var startError: String?
      var workingDirectory: String
      let tmuxSessionName: String?          // shell이면 nil
      func getOrCreateTerminal() -> TerminalWebView
      func restartIfDead()
      func focusTerminal()
      func cleanup()
  }
  // AppState 추가/변경 API (Task 8·9·10이 사용):
  //   @Published var sessions: [TerminalSession], selectedSession: TerminalSession?
  //   func addShellTab(), addTmuxTab(), removeSession(_:), selectSession(_:),
  //   moveSession(from:to:), selectNextSession(), selectPreviousSession()
  ```

- [ ] **Step 1: TerminalWebView에 마지막 그리드 크기 노출 추가**

`TerminalWebView.swift`에 프로퍼티 추가:

```swift
    private(set) var lastCols: UInt16 = 80
    private(set) var lastRows: UInt16 = 24
```

`handleBridgeMessage`의 `case "resize"` 본문을 다음으로 교체:

```swift
        case "resize":
            if let p = dict["payload"] as? [String: Any],
               let cols = p["cols"] as? Int, let rows = p["rows"] as? Int {
                lastCols = UInt16(cols)
                lastRows = UInt16(rows)
                onResize?(UInt16(cols), UInt16(rows))
            }
```

- [ ] **Step 2: TerminalSession 작성**

`Sources/SpaceManager/Models/TerminalSession.swift`:

```swift
import Foundation
import SwiftUI

enum TabKind: String, Codable {
    case tmuxMain    // 워크스페이스 고정 탭 — 워크스페이스 tmux 세션에 attach
    case shell       // 순수 셸 탭 — 앱 재시작 시 새 셸로 시작 (복구 없음, 명시적 한계)
    case tmuxExtra   // 추가 tmux 탭 — <세션명>-N, 재부팅 후에도 복구됨
}

/// 터미널 탭 하나. PTYProcess + TerminalWebView 쌍을 소유해
/// SwiftUI 뷰 업데이트를 넘어 터미널을 살아있게 한다 (기존 AgentSession 패턴 계승).
final class TerminalSession: Identifiable, ObservableObject, Equatable {
    let id: UUID
    let kind: TabKind
    @Published var name: String
    @Published var isRunning: Bool = false
    @Published var startError: String?
    var workingDirectory: String
    /// tmuxMain/tmuxExtra가 attach할 세션명 (shell이면 nil)
    let tmuxSessionName: String?

    private(set) var terminalView: TerminalWebView?
    private var pty: PTYProcess?
    private var started = false

    init(id: UUID = UUID(), kind: TabKind, name: String,
         workingDirectory: String, tmuxSessionName: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.workingDirectory = workingDirectory
        self.tmuxSessionName = tmuxSessionName
    }

    func getOrCreateTerminal() -> TerminalWebView {
        if let existing = terminalView { return existing }
        let view = TerminalWebView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onUserInput = { [weak self] data in self?.pty?.write(data) }
        view.onResize = { [weak self] cols, rows in self?.pty?.resize(cols: cols, rows: rows) }
        // PTY는 xterm 페이지 ready 이후에 시작해야 초기 출력이 유실되지 않는다
        view.onReady = { [weak self] in self?.startIfNeeded() }
        view.onWebProcessCrash = { [weak self] in self?.recoverFromCrash() }
        terminalView = view
        return view
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        startPTY()
    }

    private func startPTY() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let execName = "-" + (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"

        let startDir = FileManager.default.fileExists(atPath: workingDirectory)
            ? workingDirectory : NSHomeDirectory()
        let arguments: [String]
        if let sessionName = tmuxSessionName {
            arguments = ["-lc", TmuxBootstrap.attachOrCreateScript(sessionName: sessionName, workingDirectory: startDir)]
        } else {
            arguments = []   // 순수 인터랙티브 로그인 셸
        }

        let pty = PTYProcess()
        let view = terminalView
        pty.onOutput = { [weak view] data in view?.feed(data) }   // feed 내부에서 메인 큐 배칭
        pty.onExit = { [weak self] _ in
            DispatchQueue.main.async { self?.isRunning = false }
        }
        do {
            try pty.start(
                executable: shell, execName: execName, arguments: arguments,
                environment: env, workingDirectory: startDir,
                cols: view?.lastCols ?? 80, rows: view?.lastRows ?? 24
            )
            self.pty = pty
            isRunning = true
            startError = nil
        } catch {
            startError = "터미널 시작 실패: \(error)"
            isRunning = false
        }
    }

    /// 죽은 탭 재시작 (프로세스 종료·시작 실패 후 재시도)
    func restartIfDead() {
        guard started, pty?.isRunning != true else { return }
        pty?.terminate()
        pty = nil
        startError = nil
        startPTY()
    }

    /// WKWebView 프로세스 크래시: 페이지 리로드 + PTY 재시작.
    /// tmux 세션은 서버에 살아있으므로 재attach로 무손실 복구된다 (스펙 §7).
    private func recoverFromCrash() {
        pty?.terminate()
        pty = nil
        started = false          // 리로드 후 ready가 다시 오면 startIfNeeded가 재시작
        terminalView?.reloadPage()
    }

    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.focusTerminal()
        }
    }

    func cleanup() {
        pty?.terminate()
        pty = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }
}
```

- [ ] **Step 3: AppState를 TerminalSession 기반으로 치환**

`AppState.swift`에서 일괄 치환 + 탭 생성 API 교체:

1. 프로퍼티/함수명 치환: `agentSessions`→`sessions`, `selectedAgentSession`→`selectedSession`, `agentSessionsByWorkspace`→`sessionsByWorkspace`, `selectedAgentIdByWorkspace`→`selectedSessionIdByWorkspace`, `addAgentSession`→(삭제, 아래로 대체), `removeAgentSession`→`removeSession`, `selectAgentSession`→`selectSession`, `moveAgentSession`→`moveSession`, `selectNextAgentSession`→`selectNextSession`, `selectPreviousAgentSession`→`selectPreviousSession`. 타입 `AgentSession`→`TerminalSession`
2. init의 `NotificationCenter...agentSelectionRequested` 구독 블록 삭제
3. `addAgentSession()`을 다음 세 함수로 교체:

```swift
    /// 순수 셸 탭 (Cmd+T)
    func addShellTab() {
        guard let workspace = selectedWorkspace else { return }
        let session = TerminalSession(
            kind: .shell,
            name: "zsh",
            workingDirectory: workspace.rootPath
        )
        appendAndSelect(session, in: workspace)
    }

    /// 추가 tmux 탭 — <세션명>-2, -3, … 자동 넘버링
    func addTmuxTab() {
        guard let workspace = selectedWorkspace else { return }
        let base = workspace.effectiveTmuxSessionName
        let used = Set(sessions.compactMap { $0.tmuxSessionName })
        var n = 2
        while used.contains("\(base)-\(n)") { n += 1 }
        let sessionName = "\(base)-\(n)"
        let session = TerminalSession(
            kind: .tmuxExtra,
            name: sessionName,
            workingDirectory: workspace.rootPath,
            tmuxSessionName: sessionName
        )
        appendAndSelect(session, in: workspace)
    }

    private func makeMainTab(for workspace: Workspace) -> TerminalSession {
        // tmux가 없으면 메인 탭도 순수 셸로 폴백 (배너는 TerminalAreaView가 표시)
        guard TmuxBootstrap.isTmuxAvailable else {
            return TerminalSession(kind: .shell, name: "zsh", workingDirectory: workspace.rootPath)
        }
        let sessionName = workspace.effectiveTmuxSessionName
        return TerminalSession(
            kind: .tmuxMain,
            name: sessionName,
            workingDirectory: workspace.rootPath,
            tmuxSessionName: sessionName
        )
    }

    private func appendAndSelect(_ session: TerminalSession, in workspace: Workspace) {
        sessions.append(session)
        sessionsByWorkspace[workspace.id] = sessions
        selectSession(session)
    }
```

4. `ensureSessions(for:)`를 다음으로 교체 (메인 탭 보장 — 기존 ensureAgentSessions 패턴):

```swift
    private func ensureSessions(for workspace: Workspace) {
        sessions = sessionsByWorkspace[workspace.id] ?? []
        // 메인 탭 보장: 닫혔거나 처음이면 재생성 → tmux 세션에 재attach (스펙 §5)
        if !sessions.contains(where: { $0.kind == .tmuxMain }) && TmuxBootstrap.isTmuxAvailable {
            let main = makeMainTab(for: workspace)
            sessions.insert(main, at: 0)
        }
        if sessions.isEmpty {
            sessions = [makeMainTab(for: workspace)]
        }
        sessionsByWorkspace[workspace.id] = sessions
        let storedId = selectedSessionIdByWorkspace[workspace.id]
        selectedSession = sessions.first(where: { $0.id == storedId }) ?? sessions.first
    }
```

5. `selectSession(_:)`에서 죽은 세션 클릭 시 재시작되도록 마지막 줄 `session.focusTerminal()` 앞에 추가:

```swift
        session.restartIfDead()
```

- [ ] **Step 4: AgentTerminalView.swift 전체 교체 (에러 상태 + 재시도 포함)**

```swift
import SwiftUI
import AppKit

/// Terminal view for a single session
struct AgentTerminalView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let error = session.startError {
            VStack(spacing: 12) {
                Text(error)
                    .foregroundColor(.secondary)
                Button("다시 시도") {
                    session.restartIfDead()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SessionTerminalWrapper(session: session)
        }
    }
}

struct SessionTerminalWrapper: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalWebView {
        session.getOrCreateTerminal()
    }

    func updateNSView(_ nsView: TerminalWebView, context: Context) {
        session.focusTerminal()
    }
}
```

- [ ] **Step 5: 나머지 뷰 타입 치환**

- `TerminalAreaView.swift`: `SessionContentView`의 `@ObservedObject var session: AgentSession` → `TerminalSession`. `SingleTerminalView`의 `appState.selectedAgentSession` → `appState.selectedSession`, `Button("New Terminal") { appState.addAgentSession() }` → `{ appState.addShellTab() }`
- `AgentTabBar.swift`: 모든 `AgentSession` → `TerminalSession`, `appState.agentSessions` → `appState.sessions`, `appState.selectedAgentSession` → `appState.selectedSession`, `appState.removeAgentSession` → `appState.removeSession`, `appState.selectAgentSession` → `appState.selectSession`, `appState.moveAgentSession` → `appState.moveSession`, `session.displayName` → `session.name`. "+" 버튼 액션은 임시로 `appState.addShellTab()` (Task 8에서 메뉴로 교체)
- `SpaceManagerApp.swift` 커맨드: `appState.addAgentSession()` → `appState.addShellTab()`, `selectPreviousAgentSession/selectNextAgentSession` → `selectPreviousSession/selectNextSession`

- [ ] **Step 6: SwiftTerm·구 파일 제거**

```bash
git rm Sources/SpaceManager/Models/AgentSession.swift \
       Sources/SpaceManager/Models/AgentSessionSnapshot.swift \
       Sources/SpaceManager/Support/Notifications.swift
cat .gitmodules 2>/dev/null; git submodule status 2>/dev/null
git submodule deinit -f Packages/SwiftTerm 2>/dev/null || true
git rm -rf Packages/SwiftTerm 2>/dev/null || rm -rf Packages/SwiftTerm
rm -rf .git/modules/Packages/SwiftTerm 2>/dev/null || true
rmdir Packages 2>/dev/null || true
```

`Package.swift`에서 `dependencies:`의 SwiftTerm `.package(...)` 줄과 executableTarget dependencies의 `.product(name: "SwiftTerm", ...)` 줄 삭제 (CPty는 유지). `Package.resolved`에서 SwiftTerm 엔트리는 `swift package update` 없이 `swift build`가 자동 정리:

```bash
swift build 2>&1 | tail -3
grep -ri swiftterm Sources/ Package.swift && echo "LEFTOVER FOUND" || echo "CLEAN"
```

Expected: 빌드 성공, "CLEAN"

- [ ] **Step 7: 수동 스모크 검증**

```bash
swift run SpaceManager
```

확인: (1) 워크스페이스 선택 → xterm.js 터미널에 tmux attach, `tmux ls`에 `effectiveTmuxSessionName` 세션 존재 (2) 탭 전환·워크스페이스 전환 후 복귀 시 터미널 그대로 (3) 앱 종료 → `tmux ls` 세션 생존 → 재실행 → 같은 세션 재attach (4) 한글·마우스·복사붙여넣기 스팟 체크

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: replace SwiftTerm with TerminalSession (xterm.js+PTY), wire tmux by workspace name rule"
```

---

### Task 8: 탭 UI — "+" 메뉴, tmux 부재 배너, 세션명 편집

**Files:**
- Modify: `Views/TerminalArea/AgentTabBar.swift`("+" 메뉴), `Views/TerminalArea/TerminalAreaView.swift`(배너), `Views/Sidebar/WorkspaceListView.swift`(컨텍스트 메뉴), `ViewModels/AppState.swift`(setTmuxSessionName), `SpaceManagerApp.swift`(Cmd+Shift+T)

**Interfaces:**
- Consumes: `AppState.addShellTab()/addTmuxTab()`, `TmuxBootstrap.isTmuxAvailable`, `Workspace.tmuxSessionName/effectiveTmuxSessionName` (Task 6·7)
- Produces: `AppState.setTmuxSessionName(_ workspace: Workspace, to raw: String)`

- [ ] **Step 1: AgentTabBar의 "+" 버튼을 메뉴로 교체**

기존 `Button { appState.addShellTab() } label: { Image(systemName: "plus") ... }` 블록을 교체:

```swift
            // Add tab menu: 셸 탭 / tmux 탭 (스펙 §5)
            Menu {
                Button("셸 탭") { appState.addShellTab() }
                    .help("워크스페이스 루트에서 순수 zsh — 재시작 시 복구되지 않음")
                if TmuxBootstrap.isTmuxAvailable {
                    Button("tmux 탭") { appState.addTmuxTab() }
                        .help("별도 tmux 세션 — 재부팅 후에도 복구됨")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 40)
            .help("New Tab")
```

탭 라벨의 상태 점 옆에 종류 구분을 위해 `AgentTab`의 `Text(session.name)` 위에 아이콘 추가는 하지 않는다(YAGNI) — 점 색·이름으로 충분.

- [ ] **Step 2: tmux 부재 배너**

`TerminalAreaView`의 `VStack(spacing: 0)` 최상단(AgentTabBar 위)에 추가:

```swift
            if !TmuxBootstrap.isTmuxAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("tmux가 설치되어 있지 않아 셸 탭만 사용할 수 있습니다 — `brew install tmux` 후 재실행")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
```

- [ ] **Step 3: AppState에 세션명 편집 API 추가**

```swift
    /// tmux 세션명 커스텀 설정 — 마이그레이션 수단 (기존 세션 이름을 그대로 기입하면 연결됨).
    /// 변경 시 해당 워크스페이스의 메인 탭을 재생성해 새 세션명으로 재attach한다.
    func setTmuxSessionName(_ workspace: Workspace, to raw: String) {
        guard var ws = storage.workspace(id: workspace.id) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        ws.tmuxSessionName = trimmed.isEmpty ? nil : TmuxBootstrap.sanitizeSessionName(trimmed)
        storage.updateWorkspace(ws)
        if selectedWorkspace?.id == ws.id {
            selectedWorkspace = ws
        }
        // 메인 탭 재생성 (탭 자체는 detach만 되고 tmux 세션은 무손실)
        var wsSessions = sessionsByWorkspace[ws.id] ?? []
        if let index = wsSessions.firstIndex(where: { $0.kind == .tmuxMain }) {
            wsSessions[index].cleanup()
            wsSessions.remove(at: index)
        }
        sessionsByWorkspace[ws.id] = wsSessions
        if selectedWorkspace?.id == ws.id {
            ensureSessions(for: ws)
        }
    }
```

- [ ] **Step 4: 워크스페이스 컨텍스트 메뉴에 편집 항목 추가**

`WorkspaceListView.swift`의 `.contextMenu`에서 `Button("Rename...")` 아래에 추가:

```swift
                        Button("Edit tmux Session Name...") {
                            let alert = NSAlert()
                            alert.messageText = "tmux 세션명"
                            alert.informativeText = "비워두면 이름에서 자동 파생됩니다. 현재: \(workspace.effectiveTmuxSessionName)"
                            alert.addButton(withTitle: "저장")
                            alert.addButton(withTitle: "취소")
                            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
                            input.stringValue = workspace.tmuxSessionName ?? ""
                            input.placeholderString = workspace.effectiveTmuxSessionName
                            alert.accessoryView = input
                            if alert.runModal() == .alertFirstButtonReturn {
                                appState.setTmuxSessionName(workspace, to: input.stringValue)
                            }
                        }
```

- [ ] **Step 5: Cmd+Shift+T 커맨드 추가**

`SpaceManagerApp.swift`의 `CommandGroup(replacing: .newItem)`에서 "New Terminal Tab"(Cmd+T, `addShellTab`) 아래에 추가:

```swift
                Button("New tmux Tab") {
                    appState.addTmuxTab()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
```

- [ ] **Step 6: 빌드·수동 확인 후 Commit**

```bash
swift build && swift run SpaceManager
```

확인: "+" 메뉴 두 항목 동작, tmux 탭이 `<세션명>-2`로 생성(`tmux ls` 확인), 세션명 편집 후 메인 탭이 새 이름으로 재attach.

```bash
git add -A Sources
git commit -m "feat: tab type menu, tmux-missing banner, editable tmux session name"
```

---

### Task 9: 탭/창 영속화 — TabSnapshot·WindowState + 테스트

**Files:**
- Create: `Sources/SpaceManager/Models/TabSnapshot.swift`
- Create: `Tests/SpaceManagerTests/StorageRoundtripTests.swift`
- Modify: `Storage/WorkspaceStorage.swift`(WindowState 저장), `ViewModels/AppState.swift`(claim/restore/persist), `Models/TerminalSession.swift`(snapshot 변환)

**Interfaces:**
- Consumes: `TabKind`, `TerminalSession` (Task 7)
- Produces:
  ```swift
  struct TabSnapshot: Codable, Identifiable { let id: UUID; var kind: TabKind; var name: String; var workingDirectory: String; var tmuxSessionName: String? }
  struct WorkspaceTabsState: Codable { var workspaceId: UUID; var selectedTabId: UUID?; var tabs: [TabSnapshot] }
  struct WindowState: Codable, Identifiable { let id: UUID; var selectedWorkspaceId: UUID?; var workspaceTabs: [WorkspaceTabsState] }
  // WorkspaceStorage 추가:
  //   @Published var windowStates: [WindowState]
  //   func claimNextWindowState() -> WindowState?   // 미청구 상태 claim (인메모리)
  //   func registerClaimed(_ id: UUID); var claimedCount: Int
  //   func updateWindowState(_:), removeWindowState(id:)
  // AppState 추가: let windowStateId: UUID (Task 10의 창 복원이 사용)
  ```

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/SpaceManagerTests/StorageRoundtripTests.swift`:

```swift
import XCTest
@testable import SpaceManager

final class StorageRoundtripTests: XCTestCase {
    func testWindowStateRoundtrip() throws {
        let tab = TabSnapshot(id: UUID(), kind: .tmuxMain, name: "work",
                              workingDirectory: "/tmp/work", tmuxSessionName: "work")
        let shell = TabSnapshot(id: UUID(), kind: .shell, name: "zsh",
                                workingDirectory: "/tmp/work", tmuxSessionName: nil)
        let wsId = UUID()
        let state = WindowState(
            id: UUID(),
            selectedWorkspaceId: wsId,
            workspaceTabs: [WorkspaceTabsState(workspaceId: wsId, selectedTabId: tab.id, tabs: [tab, shell])]
        )
        let data = try JSONEncoder().encode([state])
        let decoded = try JSONDecoder().decode([WindowState].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, state.id)
        XCTAssertEqual(decoded[0].workspaceTabs[0].tabs.map(\.kind), [.tmuxMain, .shell])
        XCTAssertEqual(decoded[0].workspaceTabs[0].selectedTabId, tab.id)
    }

    func testWorkspaceDecodesLegacyJSONWithoutNewFields() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","rootPath":"/tmp/x","additionalProjects":[],
         "orchestratorEnabled":true,
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ws = try decoder.decode(Workspace.self, from: Data(legacy.utf8))
        XCTAssertEqual(ws.name, "x")
        XCTAssertNil(ws.tmuxSessionName)   // 구 파일 호환: 새 필드 없어도 로드됨
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
swift test --filter StorageRoundtripTests 2>&1 | tail -5
```

Expected: 컴파일 실패 — "cannot find 'TabSnapshot' in scope"

- [ ] **Step 3: TabSnapshot.swift 작성 + TerminalSession 변환**

`Sources/SpaceManager/Models/TabSnapshot.swift`:

```swift
import Foundation

/// 탭 하나의 영속 스냅샷 (window-states.json)
struct TabSnapshot: Codable, Identifiable {
    let id: UUID
    var kind: TabKind
    var name: String
    var workingDirectory: String
    var tmuxSessionName: String?
}

/// 한 창에서 특정 워크스페이스에 열려 있던 탭 구성
struct WorkspaceTabsState: Codable {
    var workspaceId: UUID
    var selectedTabId: UUID?
    var tabs: [TabSnapshot]
}

/// 창 하나의 전체 상태
struct WindowState: Codable, Identifiable {
    let id: UUID
    var selectedWorkspaceId: UUID?
    var workspaceTabs: [WorkspaceTabsState]
}
```

`TerminalSession.swift` 하단에 extension 추가:

```swift
extension TerminalSession {
    convenience init(snapshot: TabSnapshot) {
        self.init(id: snapshot.id, kind: snapshot.kind, name: snapshot.name,
                  workingDirectory: snapshot.workingDirectory,
                  tmuxSessionName: snapshot.tmuxSessionName)
    }

    func snapshot() -> TabSnapshot {
        TabSnapshot(id: id, kind: kind, name: name,
                    workingDirectory: workingDirectory,
                    tmuxSessionName: tmuxSessionName)
    }
}
```

- [ ] **Step 4: WorkspaceStorage에 WindowState 저장 추가**

`WorkspaceStorage.swift`에 추가:

```swift
    @Published var windowStates: [WindowState] = []
    private var claimedWindowStateIds: Set<UUID> = []

    private var windowStatesFile: URL {
        storageDirectory.appendingPathComponent("window-states.json")
    }

    func loadWindowStates() {
        guard fileManager.fileExists(atPath: windowStatesFile.path) else {
            windowStates = []
            return
        }
        do {
            let data = try Data(contentsOf: windowStatesFile)
            windowStates = try decoder.decode([WindowState].self, from: data)
        } catch {
            print("Error loading window states: \(error)")
            windowStates = []
        }
    }

    func saveWindowStates() {
        do {
            let data = try encoder.encode(windowStates)
            try data.write(to: windowStatesFile)
        } catch {
            print("Error saving window states: \(error)")
        }
    }

    /// 아직 어떤 창도 가져가지 않은 저장 상태를 하나 claim (인메모리 — 파일은 불변)
    func claimNextWindowState() -> WindowState? {
        guard let state = windowStates.first(where: { !claimedWindowStateIds.contains($0.id) }) else {
            return nil
        }
        claimedWindowStateIds.insert(state.id)
        return state
    }

    func registerClaimed(_ id: UUID) {
        claimedWindowStateIds.insert(id)
    }

    var claimedCount: Int { claimedWindowStateIds.count }

    func updateWindowState(_ state: WindowState) {
        if let index = windowStates.firstIndex(where: { $0.id == state.id }) {
            windowStates[index] = state
        } else {
            windowStates.append(state)
        }
        saveWindowStates()
    }

    func removeWindowState(id: UUID) {
        claimedWindowStateIds.remove(id)
        windowStates.removeAll { $0.id == id }
        saveWindowStates()
    }
```

`private init()`의 `loadWorkspaces()` 다음 줄에 `loadWindowStates()` 추가.

- [ ] **Step 5: AppState에 claim/restore/persist 연결**

`AppState.swift`에 프로퍼티 추가:

```swift
    let windowStateId: UUID
```

`init()`을 다음으로 교체 (구독 설정은 기존 유지):

```swift
    init() {
        storage.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if let claimed = WorkspaceStorage.shared.claimNextWindowState() {
            windowStateId = claimed.id
            restore(from: claimed)
        } else {
            windowStateId = UUID()
            WorkspaceStorage.shared.registerClaimed(windowStateId)
            if let first = storage.workspaces.first {
                selectWorkspace(first)
            }
        }
    }

    deinit {
        // 창이 닫히면 그 창의 상태를 제거. 앱 종료 시에는 유지해야 하므로 가드
        // (macOS는 종료 시 deinit을 보장하지 않지만, 호출되는 경우를 방어)
        if !AppTermination.isTerminating {
            WorkspaceStorage.shared.removeWindowState(id: windowStateId)
        }
    }

    private func restore(from state: WindowState) {
        let workspaceIds = Set(storage.workspaces.map(\.id))
        for wsTabs in state.workspaceTabs where workspaceIds.contains(wsTabs.workspaceId) {
            let restored = wsTabs.tabs.map { TerminalSession(snapshot: $0) }
            sessionsByWorkspace[wsTabs.workspaceId] = restored
            if let selectedId = wsTabs.selectedTabId {
                selectedSessionIdByWorkspace[wsTabs.workspaceId] = selectedId
            }
        }
        // 터미널 프로세스는 여기서 시작하지 않는다 — 뷰가 붙고 xterm이 ready될 때 게으르게 시작
        if let wsId = state.selectedWorkspaceId,
           let workspace = storage.workspace(id: wsId) {
            selectWorkspace(workspace)
        } else if let first = storage.workspaces.first {
            selectWorkspace(first)
        }
    }

    private func persistWindowState() {
        var wsStates: [WorkspaceTabsState] = []
        for (wsId, wsSessions) in sessionsByWorkspace where !wsSessions.isEmpty {
            wsStates.append(WorkspaceTabsState(
                workspaceId: wsId,
                selectedTabId: selectedSessionIdByWorkspace[wsId],
                tabs: wsSessions.map { $0.snapshot() }
            ))
        }
        WorkspaceStorage.shared.updateWindowState(WindowState(
            id: windowStateId,
            selectedWorkspaceId: selectedWorkspace?.id,
            workspaceTabs: wsStates
        ))
    }
```

다음 함수들의 **마지막 줄에** `persistWindowState()` 호출 추가: `selectWorkspace`, `deleteWorkspace`, `appendAndSelect`, `removeSession`, `selectSession`, `moveSession`, `setTmuxSessionName`.

`AppTermination`은 Task 10에서 정의된다 — 이 태스크에서는 임시로 `Support/AppTermination.swift`를 만든다:

```swift
import Foundation

enum AppTermination {
    static var isTerminating = false
}
```

- [ ] **Step 6: 테스트·빌드·수동 확인**

```bash
swift test 2>&1 | tail -5
swift build && swift run SpaceManager
```

Expected: 전체 테스트 통과. 앱에서 탭 2~3개 만들고 종료 → `cat ~/.space-manager/window-states.json` 확인 → 재실행 시 탭 구성·선택 복원, 메인/tmux 탭은 재attach, 셸 탭은 새 셸.

- [ ] **Step 7: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: persist per-window tab state to window-states.json with claim-based restore"
```

---

### Task 10: 멀티윈도우 — 창마다 독립 AppState

**Files:**
- Modify: `SpaceManagerApp.swift`(전체 교체), `Views/ContentView.swift`(AppState 소유·복원 트리거)
- Delete: `Sources/SpaceManager/Support/AppTermination.swift` (SpaceManagerApp.swift로 이동)

**Interfaces:**
- Consumes: `AppState.windowStateId`, `WorkspaceStorage.claimedCount/windowStates` (Task 9)
- Produces: `WindowGroup(id: "main")`, `AppCommands`(FocusedObject 기반), `WindowRestorer.openRemainingWindowsIfNeeded(_:)`

- [ ] **Step 1: SpaceManagerApp.swift 전체 교체**

```swift
import SwiftUI
import AppKit

enum AppTermination {
    static var isTerminating = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 종료 시 AppState.deinit이 창 상태를 지우지 않도록 표시
        AppTermination.isTerminating = true
        return .terminateNow
    }
}

@main
struct SpaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            if ProcessInfo.processInfo.environment["SM_SPIKE"] == "1" {
                TerminalSpikeView()
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                ContentView()
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .windowStyle(.titleBar)
        .commands {
            AppCommands()
        }
    }
}

/// 메뉴 커맨드 — FocusedObject로 "활성 창"의 AppState에 바인딩된다
struct AppCommands: Commands {
    @FocusedObject private var appState: AppState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("New Workspace") {
                appState?.showNewWorkspaceSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(appState == nil)

            Button("New Terminal Tab") {
                appState?.addShellTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState == nil)

            Button("New tmux Tab") {
                appState?.addTmuxTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(appState == nil)
        }

        CommandMenu("Tabs") {
            Button("Previous Tab") {
                appState?.selectPreviousSession()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(appState == nil)

            Button("Next Tab") {
                appState?.selectNextSession()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(appState == nil)
        }
    }
}

/// 앱 시작 시 저장된 창 수만큼 창을 복원한다.
/// 우리 북키핑(claimedCount) 기준으로 부족분만 열어 시스템 복원과의 중복을 방지.
enum WindowRestorer {
    private static var didRun = false

    @MainActor
    static func openRemainingWindowsIfNeeded(_ openWindow: OpenWindowAction) {
        guard !didRun else { return }
        didRun = true
        // 시스템 상태 복원이 창을 이미 띄웠을 수 있으므로 잠시 뒤 부족분 계산
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let storage = WorkspaceStorage.shared
            let missing = storage.windowStates.count - storage.claimedCount
            guard missing > 0 else { return }
            for _ in 0..<missing {
                openWindow(id: "main")
            }
        }
    }
}
```

(기존 `AppTermination` 임시 파일 삭제: `git rm Sources/SpaceManager/Support/AppTermination.swift`)

- [ ] **Step 2: ContentView가 AppState를 소유하도록 수정**

`ContentView.swift`의 `ContentView` 구조체를 교체 (`NewWorkspaceSheet`/`AddProjectSheet`는 그대로):

```swift
/// Main content view with two-pane layout.
/// 창마다 하나씩 생성된다 — AppState가 여기 살아야 창별 독립 선택이 가능하다.
struct ContentView: View {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 200)
        } detail: {
            TerminalAreaView()
        }
        .environmentObject(appState)
        .focusedSceneObject(appState)
        .sheet(isPresented: $appState.showNewWorkspaceSheet) {
            NewWorkspaceSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showAddProjectSheet) {
            AddProjectSheet()
                .environmentObject(appState)
        }
        .navigationTitle(appState.selectedWorkspace?.name ?? "SpaceManager")
        .onAppear {
            WindowRestorer.openRemainingWindowsIfNeeded(openWindow)
        }
    }
}
```

- [ ] **Step 3: 빌드·멀티윈도우 수동 검증**

```bash
swift build && swift run SpaceManager
```

확인:
1. Cmd+N → 새 창, 다른 워크스페이스 선택 → 두 창이 독립 동작
2. 한 창에서 워크스페이스 추가 → 다른 창 사이드바에 즉시 반영 (전역 스토리지 구독)
3. 같은 워크스페이스를 두 창에서 열기 → 같은 tmux 세션 미러링 (정상 — `window-size latest` 권장)
4. 창 2개 상태로 앱 종료 → 재실행 → 창 2개와 각각의 워크스페이스·탭 복원
5. 창 하나 닫고 종료 → 재실행 → 창 1개만 복원 (`window-states.json` 확인)

- [ ] **Step 4: Commit**

```bash
git add -A Sources
git commit -m "feat: multi-window support with per-window AppState and window restore"
```

---

### Task 11: 최종 검증 + README 갱신 + 마이그레이션

**Files:**
- Modify: `README.md`(기능·사용법·구조 섹션)
- 검증: 스펙 §8 전체 체크리스트

**Interfaces:** 없음 (마감 태스크)

- [ ] **Step 1: 전체 테스트·릴리스 빌드**

```bash
swift test 2>&1 | tail -5
swift build -c release 2>&1 | tail -3
```

Expected: 전 테스트 통과, 릴리스 빌드 성공.

- [ ] **Step 2: 스펙 §8 수동 체크리스트 전체 수행**

`swift run SpaceManager`로 실행 후:
1. tmux 마우스: 패널 클릭 전환·휠 스크롤(copy-mode)·경계 드래그 리사이즈
2. 선택 + Cmd+C → 외부 앱 붙여넣기 / 외부 복사 → Cmd+V
3. 한글 조합 입력·백스페이스·조합 중 Enter
4. claude/vim/htop 풀스크린 TUI + 리사이즈
5. 워크스페이스 전환 후 복귀 → 터미널 상태 유지
6. 앱 종료 → 재실행 → 창·탭·attach 복원
7. **재부팅** → continuum 복원 확인(`tmux ls`) → 앱 실행 → 전 워크스페이스 재attach
8. 두 창 동일 워크스페이스 미러링 + `window-size latest` 동작
9. `swift build -c release` 통과 (Step 1에서 완료)

실패 항목은 이 태스크 안에서 수정 후 재검증.

- [ ] **Step 3: README 갱신**

`README.md`에서 사라진 기능 서술을 현행화한다 — Features 섹션을 다음으로 교체:

```markdown
## Features

- **Real Terminal**: xterm.js-based terminal (same engine as VS Code) — full mouse support, TUI apps, IME, native copy/paste
- **tmux-Native Workspaces**: Selecting a workspace auto-attaches to its tmux session by name. Pair with tmux-resurrect/continuum and everything survives reboots
- **Multi-Window**: Every window is a full IDE — put a different project on each Space
- **Terminal Tabs**: Plain shell tabs or extra tmux session tabs, drag to reorder
- **File Browser**: Read-only project tree in the sidebar for quick reference
```

Usage의 Agents/Keyboard Shortcuts/Supported AI CLI Tools 섹션과 Dependencies의 SwiftTerm 줄, Project Structure를 실제 구조에 맞게 정리 (LauncherTUI·모델 프리셋 관련 서술 삭제, 단축키 표는 Cmd+N/Cmd+Shift+N/Cmd+T/Cmd+Shift+T/Cmd+Opt+←→로 교체).

- [ ] **Step 4: 마이그레이션 (1회성, 유저와 함께)**

```bash
tmux ls   # 기존 세션 이름 확인
```

각 워크스페이스: 사이드바 우클릭 → "Edit tmux Session Name..." → 기존 세션 이름 기입. 그리고:

```bash
grep -q "window-size latest" ~/.tmux.conf || echo 'set -g window-size latest' >> ~/.tmux.conf
tmux source-file ~/.tmux.conf 2>/dev/null || true
```

- [ ] **Step 5: 최종 Commit**

```bash
git add -A
git commit -m "docs: update README for tmux-centric terminal redesign"
```

---

## Self-Review 결과 반영 노트

- 스펙 §4의 "탭 터미널은 워크스페이스 전환에도 생존" → Task 7 `sessionsByWorkspace` 캐시로 커버
- 스펙 §7 에러 표 전체가 Task 7(스폰 실패·크래시 복구·종료 재시작)·Task 8(tmux 부재 배너)에 매핑됨
- 스펙 §5 "메인 탭 재생성 보장" → Task 7 Step 3의 `ensureSessions`
- Task 4 스파이크는 검증 후에도 무해하므로 유지 (SM_SPIKE 환경변수 없이는 비활성)

