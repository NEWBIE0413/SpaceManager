# SpaceManager 재설계: 순수 터미널 + tmux 중심 + 멀티윈도우

날짜: 2026-07-12
상태: 설계 확정 (유저 승인)

## 1. 배경과 목표

SpaceManager는 터미널 중심 IDE지만, 현재 다음 문제로 제작자 본인이 쓰지 않는 상태다:

1. **터미널이 나사빠짐** — 마우스 상호작용, 스크롤, 복사/붙여넣기, TUI 렌더링(claude/vim/htop), 한글 IME 전부 고장이거나 불안정. 원인은 SwiftTerm 자체보다 로컬 포크에 가한 수정들(`allowMouseReporting = false`, 얼터네이트 버퍼 비활성 이력, 커스텀 키 가로채기, 커서 강제 고정)로 추정되나, 신뢰가 깨진 상태.
2. **에이전트 탭 시스템이 워크플로우와 어긋남** — 요즘 실사용은 "터미널에 tmux 하나 띄워놓고 그 안에서 전부 처리". 워크스페이스별 다중 에이전트 탭 + TUI 런처 + 자동 분할은 tmux와 기능이 중복되는 죽은 무게.
3. **재부팅 복구 안 됨** — 유저의 tmux는 tmux-resurrect + tmux-continuum으로 재부팅 시 자동 복원되도록 이미 구성됨(15분 주기 저장, 시작 시 자동 복원). 앱이 이걸 활용하지 못함.
4. **창 1개 제한** — 맥북 화면(Space)마다 창 하나씩 띄워 서로 다른 프로젝트를 작업하고 싶은데 불가능.

### 목표

- VS Code/Cursor급으로 전부 동작하는 진짜 터미널
- 워크스페이스 선택 = 해당 tmux 세션 자동 attach. 재부팅 → continuum 복원 → 앱이 이름으로 재attach
- VS Code식 멀티윈도우: 모든 창이 동일 구조, 창마다 독립적인 워크스페이스 선택
- **기본 뼈대는 기존 소스 유지** — 재작성이 아니라 수술. 기존 클래스·패턴·파일 구조를 최대한 보존하면서 다이어트

### 비목표 (YAGNI)

- 설정 UI, 모델 프리셋, 플랜 오케스트레이션, 자동 분할 페인 — 전부 제거. 분할·페인·에이전트 관리는 tmux가 담당
- 폰트/테마 커스터마이즈 UI — 하드코딩 기본값 + 시스템 라이트/다크 추종
- 앱이 tmux 세션의 저장/복원을 직접 수행하는 것 — 그건 resurrect/continuum의 일. 앱은 이름으로 attach만 한다

## 2. 확정된 결정 사항

| 항목 | 결정 |
|---|---|
| 터미널 엔진 | **xterm.js + WKWebView** (VS Code와 동일 엔진). SwiftTerm 포크·의존성 전면 제거 |
| 탭 | 유지하되 단순화 — 순수 터미널 탭만. 런처·자동분할·에이전트 개념 제거 |
| tmux 연동 | 이름 규칙 자동 연결. `Workspace.tmuxSessionName` 필드(기본값: 이름 파생, 편집 가능) |
| 첫 탭(메인 탭) | 워크스페이스 tmux 세션에 자동 attach. 없으면 생성 |
| 추가 탭 | "+" 메뉴로 선택: 순수 셸 탭 / tmux 탭(`<세션명>-2` 등) |
| 멀티윈도우 | 모든 창 동일 구조(사이드바+터미널), 워크스페이스 목록 전역 공유, 창별 독립 선택 |
| 사이드바 | 기존 그대로 — 워크스페이스 목록 + 프로젝트/파일 트리 열람. 오케스트레이터 토글만 제거 |
| 제거 기능 | PlanOrchestrator, CommandPreset/모델 설정, LauncherTUIView, 자동 분할, 설정 시트 |
| 마이그레이션 | 완성 후 1회: 기존 tmux 세션 이름을 워크스페이스의 tmuxSessionName에 기입(또는 tmux 쪽 rename) |

## 3. 아키텍처 — 파일별 운명표

기존 아키텍처의 두 가지 핵심 패턴을 그대로 계승한다:

- **전역 스토리지 + 구독**: `WorkspaceStorage.shared`는 이미 전역 싱글턴이고 `AppState`가 `storage.objectWillChange`를 구독한다. 멀티윈도우에서 "어느 창에서 워크스페이스를 추가해도 모든 창에 반영"은 이 패턴이 이미 해결한다. 지금 멀티윈도우가 안 되는 유일한 이유는 `AppState`가 App 레벨 `@StateObject`라서 모든 창이 선택 상태를 공유하기 때문.
- **세션이 터미널 뷰를 소유, SwiftUI는 래핑만**: `AgentSession`이 NSView를 소유하고 `SessionTerminalWrapper: NSViewRepresentable`이 감싸는 구조는 뷰 업데이트를 넘어 터미널을 살아있게 하는 검증된 패턴. 내용물만 SwiftTerm → WKWebView로 교체한다.

| 파일 | 처리 | 내용 |
|---|---|---|
| `SpaceManagerApp.swift` | 수정 (소폭) | `@StateObject appState`를 App → `ContentView` 안으로 이동(창마다 독립 AppState). Cmd+N=새 창. 메뉴 커맨드는 `@FocusedObject`로 활성 창의 AppState에 연결 |
| `ViewModels/AppState.swift` | 수정 (다이어트) | 뼈대(워크스페이스 선택, 워크스페이스별 캐시, hydrate/persist 패턴) 유지. 에이전트 그룹·분할·포커스모드·PlanOrchestrator 로직 삭제 |
| `Storage/WorkspaceStorage.swift` | 수정 (소폭) | workspaces.json 로직 그대로. models.json·agent-states.json 로딩 제거, window-states.json 추가 |
| `Models/Workspace.swift` | 수정 (소폭) | `tmuxSessionName: String?` 추가. `orchestratorEnabled` 제거(JSONDecoder가 모르는 키를 무시하므로 기존 파일 호환) |
| `Models/AgentSession.swift` | 교체 → `TerminalSession` | 클래스 골격(Identifiable·ObservableObject·터미널 소유·snapshot) 유지. 내부를 `PTYProcess`+`TerminalWebView`로 교체. 워킹트리의 tmux 부트스트랩 스크립트(`buildTmuxBootstrapScript`, `shQuoted`)는 재사용하되 세션명을 UUID → 워크스페이스 규칙 기반으로 변경 |
| `Models/AgentSessionSnapshot.swift` | 수정 | `TabSnapshot`(id, 이름, 종류, 디렉토리) + `WindowState`로 재편. hydrate/persist 패턴 유지 |
| `Models/DirectoryWatcher.swift` | 유지 | 파일 브라우저가 사용 |
| `Models/PlanOrchestrator.swift` | 삭제 | |
| `Models/CommandPreset.swift` | 삭제 | 단, 파일 안의 색상 익스텐션(`warmPink` 등)은 사이드바·탭바가 사용 중이므로 `Views/Theme.swift`(신규)로 옮긴 뒤 삭제 |
| `Views/TerminalArea/AgentTabBar.swift` | 수정 (소폭) | 드래그 정렬·호버·닫기 그대로. "+" 버튼을 메뉴(셸 탭/tmux 탭)로 |
| `Views/TerminalArea/TerminalAreaView.swift` | 수정 | VStack(탭바+터미널) 뼈대 유지. `AgentGroupTabBar`·`SplitTerminalView`·`SplitSessionView` 삭제 |
| `Views/TerminalArea/AgentTerminalView.swift` | 수정 | `SessionTerminalWrapper` 패턴 그대로, 내용물만 WKWebView |
| `Views/TerminalArea/LauncherTUIView.swift` | 삭제 | |
| `Views/TerminalArea/CommandPresetBar.swift` | 삭제 | |
| `Views/Sidebar/SidebarView.swift` | 유지 | |
| `Views/Sidebar/WorkspaceListView.swift` | 수정 (소폭) | 오케스트레이터 안테나 버튼 제거. 컨텍스트 메뉴에 "tmux 세션명 편집" 추가 |
| `Views/Sidebar/ProjectListView.swift` | 유지 | 파일 브라우저 포함 전부 그대로 |
| `Views/ContentView.swift` | 수정 | NavigationSplitView·NewWorkspaceSheet·AddProjectSheet 유지. ModelConfig/Settings 시트·기어 툴바 제거 |
| `Packages/SwiftTerm` 포크 | 삭제 | Package.swift에서 SwiftTerm 의존성 제거 |
| `Terminal/PTYProcess.swift` | 신규 | PTY 열기 + 셸 스폰 + 입출력 |
| `Terminal/TerminalWebView.swift` | 신규 | WKWebView 래퍼 + Swift↔JS 브릿지 |
| `Terminal/Resources/` | 신규 | terminal.html, xterm.js + 애드온 번들 (vendored) |

## 4. 터미널 엔진 (xterm.js + WKWebView)

터미널 하나 = `PTYProcess` + `TerminalWebView` 한 쌍. `TerminalSession`이 둘 다 소유한다.

### PTYProcess

- `openpty()`로 마스터/슬레이브 fd 확보, 슬레이브를 표준 입출력으로 유저 셸을 스폰 (`$SHELL`, 폴백 `/bin/zsh`; `-lc <부트스트랩 스크립트>` 형태 — 기존 `startTerminalIfNeeded`의 인자 구성 계승)
- 출력: `DispatchSource.makeReadSource`로 마스터 fd 감시 → 브릿지로 전달
- 입력: 브릿지에서 받은 바이트를 마스터 fd에 write
- 리사이즈: `ioctl(TIOCSWINSZ)`
- 종료 감지: 프로세스 종료 시 콜백 → 세션의 `isRunning = false` (기존 `processTerminated` 패턴 계승)

### TerminalWebView

- WKWebView가 앱 번들(SPM resources)의 `terminal.html`을 `loadFileURL`로 로드
- xterm.js + fit·webgl 애드온을 고정 버전으로 vendored — 런타임 네트워크 의존 없음
- 폰트: CSS `fontFamily`로 기존 `fontCandidates` 목록 계승 — `D2Coding, NanumGothicCoding, "Noto Sans Mono CJK KR", "SF Mono", Menlo, monospace` (CJK 폭 문제 대응)
- 테마: 시스템 라이트/다크 감지해서 xterm 테마 색상 주입, `NSApp.effectiveAppearance` 변경 시 갱신

### 브릿지 (성능이 관건)

- **PTY→JS**: 출력 바이트를 ~8ms 코얼레싱 배칭 → base64 → `evaluateJavaScript`로 `term.write()` 호출. 배칭 없이는 claude처럼 출력이 폭주하는 TUI에서 브릿지가 병목이 된다 (VS Code도 같은 이유로 배칭)
- **JS→PTY**: xterm `onData`(키입력·IME 조합 결과·마우스 리포트 전부 포함) → `WKScriptMessageHandler` postMessage → PTY write
- **리사이즈**: FitAddon이 컨테이너 크기에서 cols/rows 계산 → postMessage → `TIOCSWINSZ`
- **클립보드는 네이티브 단일 경로**: Cmd+C는 JS에서 `term.getSelection()`을 Swift로 넘겨 NSPasteboard 기록, Cmd+V는 Swift가 NSPasteboard를 읽어 term에 paste. 웹뷰 클립보드 권한 문제를 원천 차단

### 기존 증상별 해결 근거

- 마우스/스크롤: xterm.js 마우스 리포팅 완전 지원 → tmux 마우스 모드(유저 설정에 이미 `set -g mouse on`)로 패널 클릭·휠 스크롤(copy-mode 히스토리)·드래그 리사이즈 동작
- 복사/붙여넣기: 위 네이티브 클립보드 경로
- 한글 IME: xterm.js의 textarea 기반 조합 입력 — VS Code 터미널과 동일 코드 경로
- TUI: webgl 렌더러 + 완전한 얼터네이트 버퍼

### 수명 관리

- 탭의 터미널(WebView+PTY)은 세션이 소유 → 워크스페이스 전환해도 살아있음 (기존 동작 유지)
- 창 닫힘/앱 종료 → PTY 종료 → tmux 클라이언트는 detach될 뿐 세션은 서버에 생존. 별도 정리 로직 불필요

## 5. tmux 연동

### 세션 이름 규칙

- `Workspace.tmuxSessionName` — 기본값: 워크스페이스 이름에서 파생. tmux가 금지하는 `.` `:` 및 공백을 `-`로 치환, 빈 결과면 `workspace`로 폴백
- 워크스페이스 컨텍스트 메뉴에서 편집 가능 — **이것이 마이그레이션 수단**: 기존에 돌던 세션 이름을 그대로 기입하면 tmux 쪽 변경 없이 연결됨

### 메인 탭 (워크스페이스 고정 탭)

- 워크스페이스 선택 시 자동 보장(기존 `ensureAgentSessions` 패턴): `tmux new-session -A -s <세션명> -c <루트경로>` 동작의 부트스트랩 — 있으면 attach, 없으면 생성
- 닫기 가능. 닫으면 탭 목록에서 사라지고, 해당 워크스페이스를 다시 선택(재진입)하면 보장 로직이 메인 탭을 재생성해 재attach
- 재부팅 흐름: 재부팅 → 유저의 continuum이 tmux 세션 복원 → 앱 실행 → 이름으로 재attach. 앱은 복원에 관여하지 않는다

### 추가 탭

- "+" 버튼 = 메뉴: **셸 탭**(워크스페이스 루트에서 순수 zsh, 재부팅·앱재시작 시 새 셸로 시작) / **tmux 탭**(`<세션명>-2`, `-3`… 자동 넘버링, `new -A`, 재부팅 후에도 복구)
- Cmd+T = 셸 탭 바로 열기 (빠른 경로)

### 멀티 클라이언트 주의

같은 워크스페이스를 두 창에서 열면 두 tmux 클라이언트가 같은 세션에 붙어 화면이 미러링되고 크기는 작은 클라이언트 기준이 된다. 유저 `~/.tmux.conf`에 다음 추가 권장 (앱이 강제하지 않음, 문서 안내):

```
set -g window-size latest
```

### tmux 부재/오류

- 앱 시작 시 `tmux` 실행 가능 여부 확인(로그인 셸 PATH 기준). 없으면 메인 탭 자리에 설치 안내 표시, 셸 탭은 정상 동작
- tmux 서버가 죽어있는 경우: `new -A`가 서버를 자동 기동하므로 별도 처리 불필요

## 6. 멀티윈도우와 영속화

### 창 구조

- `WindowGroup` 유지. `@StateObject AppState`를 `ContentView`로 내려 창마다 독립 인스턴스
- 워크스페이스 목록은 `WorkspaceStorage.shared` 전역 공유(기존 구독 패턴으로 창 간 자동 동기화)
- 메뉴 커맨드(새 탭, 탭 이동 등)는 `@FocusedObject`/FocusedValue로 활성 창의 AppState에 바인딩
- Cmd+N: 새 창 / Cmd+Shift+N: 새 워크스페이스(기존) / Cmd+T: 새 셸 탭 / Cmd+Opt+←→: 탭 이동(기존)

### 영속화

- `workspaces.json` — 기존 + `tmuxSessionName`
- `window-states.json` — 신규:

```json
[
  {
    "windowId": "UUID",
    "selectedWorkspaceId": "UUID",
    "workspaceTabs": [
      {
        "workspaceId": "UUID",
        "selectedTabId": "UUID",
        "tabs": [
          { "id": "UUID", "kind": "tmuxMain", "name": "main" },
          { "id": "UUID", "kind": "shell", "name": "Shell", "workingDirectory": "/path" },
          { "id": "UUID", "kind": "tmuxExtra", "name": "work-2", "tmuxSessionName": "work-2" }
        ]
      }
    ]
  }
]
```

- 저장 시점: 탭/선택 변경 시(기존 `persistAgentState` 패턴 계승)
- 복원: 앱 시작 시 첫 창이 저장된 창 상태 목록에서 하나를 claim하고, 나머지 저장 창 수만큼 `openWindow`로 추가 창을 연다. 각 창의 AppState가 미청구 상태를 순서대로 claim해 복원. 저장 상태보다 많이 열린 창은 새 상태로 시작. 닫힌 창의 상태는 목록에서 제거
- 창 위치·크기: macOS 기본 상태 복원에 위임
- `models.json`, `agent-states.json`: 더 이상 로드하지 않음(파일은 삭제하지 않고 방치 — 롤백 안전)

## 7. 에러 처리

| 상황 | 처리 |
|---|---|
| tmux 미설치 | 메인 탭 자리에 안내 + 설치 명령 표시. 셸 탭은 정상 |
| PTY 스폰 실패 | 탭에 에러 상태 + 재시도 버튼 |
| WKWebView 프로세스 크래시 | `webViewWebContentProcessDidTerminate`에서 페이지 리로드 + PTY 재시작. tmux 세션은 무손실이므로 재attach로 완전 복구 |
| 워크스페이스 루트 경로 소실 | 홈 디렉토리 폴백(기존 로직 유지) + 사이드바 경고 아이콘(기존) |
| 셸 프로세스 종료(exit 등) | `isRunning = false` 탭 점 표시(기존 패턴). 메인 탭은 클릭 시 재시작 |
| 세션명 무효 문자 | 저장 시 sanitize. 편집 UI에서 검증 |

## 8. 테스트와 검증

**유닛 테스트** (신규 Tests 타겟):
- 세션명 sanitize (한글 이름, 공백, `.`, `:`, 빈 문자열)
- tmux 부트스트랩 스크립트 생성 (셸 인젝션 — 작은따옴표 포함 경로)
- 스토리지 라운드트립 (Workspace + WindowState 인코딩/디코딩, 구버전 JSON 로드 호환)

**수동 검증 체크리스트** (구현 완료 게이트):
1. tmux 안에서 마우스: 패널 클릭 전환, 휠 스크롤(copy-mode), 경계 드래그 리사이즈
2. 텍스트 선택 + Cmd+C → 다른 앱에 붙여넣기 / 다른 앱 복사 → Cmd+V
3. 한글 입력: 조합 중 표시, 백스페이스, 조합 중 Enter
4. claude / vim / htop 풀스크린 TUI 렌더링 + 리사이즈
5. 워크스페이스 전환 후 복귀 → 터미널 상태 그대로
6. 앱 종료 → 재실행 → 창 구성·탭·tmux attach 복원
7. 재부팅 → continuum 복원 → 앱 실행 → 전 워크스페이스 재attach
8. 창 2개에서 같은 워크스페이스 (미러링 확인, `window-size latest` 동작)
9. `swift build -c release` 통과

## 9. 마이그레이션 (완성 후 1회)

1. 앱 실행 → 워크스페이스마다 컨텍스트 메뉴에서 tmux 세션명을 기존 세션 이름으로 편집 (또는 `tmux rename-session -t old new`로 tmux 쪽을 규칙에 맞춤)
2. `~/.tmux.conf`에 `set -g window-size latest` 추가 권장
3. 구 데이터(`agent-states.json`, `models.json`)는 자동 무시 — 유저 조치 불필요

## 10. 구현 순서 (플랜에서 상세화)

1. **Terminal 모듈 단독 스파이크**: 빈 창 + xterm.js + PTY 브릿지만으로 §8 체크리스트 1~4 검증 — 엔진 리스크를 가장 먼저 소거
2. 기능 제거·다이어트 (빌드 그린 유지)
3. `TerminalSession` 교체 + tmux 부트스트랩 연결
4. 탭 UI 개편 ("+" 메뉴)
5. 멀티윈도우 + window-states.json 영속화
6. §8 전체 체크리스트 + 마이그레이션 수행
