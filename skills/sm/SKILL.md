---
name: sm
description: WorkspaceManager의 창·워크스페이스·tmux 탭·원격 워크스페이스·활동 표시를 sm CLI로 조회하거나 조작할 때 사용한다.
---

# WorkspaceManager CLI

`sm --help`가 현재 명령 목록이다. `sm ping`, `sm --json windows`, `sm --json ws`, `sm tabs`로 실제 대상을 확인한다. 읽기는 JSON 출력이 안정적이며, 실행 중인 앱의 `window-states.json`을 직접 수정하지 않는다.

워크스페이스는 이름·tmux 세션명·경로·ID 접두사로, 창은 index·ID 접두사·front로 찾는다. 이름이 겹치면 목록에서 얻은 ID를 사용한다. `--no-focus`는 백그라운드 관리 중 창 포커스 이동을 줄인다.

## 원격 워크스페이스

```bash
sm ws add ~/myworld/project
sm ws remote project arch
sm tabs project
```

원격 host는 SSH 별칭이다. 설정 전에 `ssh arch`와 원격 프로젝트 폴더가 실제로 존재하는지 확인한다. 로컬 홈 아래 상대 경로가 원격 홈으로 매핑된다. `sm ws remote project none`은 로컬로 돌린다. 워크스페이스 등록은 소스 이전을 수행하지 않는다.

`sm activity --json`의 세션 `host`로 로컬/원격을 구분한다. 원격 활동 요약은 `~/.space-manager/remote/<host>/activity.json`에 있다. 요약이 오래되면 생성 중 표시가 꺼질 수 있으므로 먼저 미러의 갱신 시각과 SSH 연결을 확인한다. 설치·제거는 저장소의 `scripts/install-remote-mirror.sh`가 담당한다.

## 탭과 에이전트

`sm tab shell|tmux`, `sm tab select|close`, `sm quick` 계열은 앱 UI의 대응 동작을 수행한다. 에이전트에게 메시지를 보낼 때는 smux의 주소·읽기 가드·trust 규약을 사용한다. `sm`은 창과 워크스페이스 관리 도구이며 메시지 제출을 대신하지 않는다.

워크스페이스 삭제나 tmux 세션 종료는 목록을 확인하고 사용자가 요청한 범위에만 적용한다. 고아 탭 기록만 있다는 이유로 실행 중인 세션을 종료하지 않는다.
