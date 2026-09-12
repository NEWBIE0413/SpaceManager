#!/bin/sh
# 원격 호스트의 에이전트 활동 요약을 맥으로 끌어온다 — SpaceManager 원격 워크스페이스의
# 활동 점(dot)과 아일랜드가 이 파일을 읽는다.
#
#   remote-activity-mirror.sh <ssh-host> [interval-seconds]
#
# 매 주기마다 remote-activity-summary.py를 ssh stdin으로 보내 원격 python3로 실행하고,
# 그 stdout(JSON 한 줄, 보통 수 KB)을 ~/.space-manager/remote/<host>/activity.json에
# 원자적으로 쓴다. 원격에 설치할 것이 없고, transcript 원본은 한 바이트도 옮기지 않는다.
# ssh는 ~/.ssh/config의 ControlMaster를 그대로 써서 주기마다 새 핸드셰이크를 하지 않는다.
#
# 한계: 맥이 끌어오는 방향만 있다(맥 Remote Login이 꺼져 있어 원격이 밀어 넣을 수 없다).
# 원격이 꺼져 있으면 실패마다 60초 쉰다 — 5초마다 타임아웃을 기다리며 CPU를 태우지 않기 위해.
set -u
host="${1:?usage: remote-activity-mirror.sh <ssh-host> [interval]}"
interval="${2:-5}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
summary="$script_dir/remote-activity-summary.py"
out_dir="$HOME/.space-manager/remote/$host"
mkdir -p "$out_dir"

while :; do
    tmp="$out_dir/.activity.json.$$"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 "$host" python3 - < "$summary" > "$tmp" 2>/dev/null \
        && [ -s "$tmp" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$out_dir/activity.json"
        sleep "$interval"
    else
        rm -f "$tmp"
        sleep 60
    fi
done
