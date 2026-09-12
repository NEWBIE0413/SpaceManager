#!/usr/bin/env python3
"""원격 머신에서 실행되는 활동 요약기.

`~/.claude/projects/*/*.jsonl`과 `~/.codex/sessions/**/*.jsonl` 중 최근 24시간 안에
바뀐 transcript만 골라, SpaceManager의 RecentActivityScanner가 로컬에서 뽑는 것과 같은
메타데이터(cwd·마지막 이벤트 시각·마지막 유저 메시지)를 JSON 한 덩어리로 stdout에 낸다.

왜 요약인가: transcript 원본은 수 GB이고 5초마다 rsync하면 링크와 디스크를 다 먹는다.
점(dot)과 아일랜드에 필요한 것은 파일당 몇 백 바이트뿐이라, 파일의 끝부분만 읽어
요약을 만들고 그것만 맥으로 보낸다. 표준 라이브러리만 쓴다 — 원격에 아무것도 설치하지
않고 `ssh host python3 - < 이 파일`로 실행되기 위해서다.
"""
import json
import os
import sys
import time
from datetime import datetime, timezone

WINDOW_SECONDS = 24 * 3600          # RecentActivityScanner.dotWindow
TAIL_BYTES = 131_072                # TranscriptJSON.tail 기본값과 동일
HEAD_BYTES = 65_536                 # Codex session_meta는 파일 머리에 있다
SNIPPET_MAX = 240


def parse_timestamp(raw):
    if not isinstance(raw, str):
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def clean_snippet(text):
    return " ".join(text.strip().split("\n"))[:SNIPPET_MAX]


def read_tail(path):
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - TAIL_BYTES))
        return f.read()


def read_head(path):
    with open(path, "rb") as f:
        return f.read(HEAD_BYTES)


def json_lines(data):
    for line in data.split(b"\n"):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue           # 잘린 첫 줄 등
        if isinstance(obj, dict):
            yield obj


def claude_user_text(obj):
    # RecentActivityScanner.userText와 같은 규칙: 유저가 직접 친 문자열 메시지만.
    if obj.get("type") != "user":
        return None
    content = (obj.get("message") or {}).get("content")
    if not isinstance(content, str):
        return None
    trimmed = content.strip()
    if not trimmed or trimmed.startswith("<") or trimmed.startswith("Caveat:") \
            or trimmed.startswith("[Request interrupted"):
        return None
    return clean_snippet(trimmed)


def claude_record(path, mtime):
    cwd = snippet = last = None
    for obj in reversed(list(json_lines(read_tail(path)))):
        if cwd is None and isinstance(obj.get("cwd"), str):
            cwd = obj["cwd"]
        if snippet is None:
            snippet = claude_user_text(obj)
        if last is None:
            last = parse_timestamp(obj.get("timestamp"))
        if cwd and snippet and last:
            break
    if cwd is None:
        return None
    session_id = os.path.splitext(os.path.basename(path))[0]
    return {"provider": "claude", "id": session_id, "cwd": cwd, "mtime": mtime,
            "lastActivity": last if last is not None else mtime, "snippet": snippet}


def codex_user_text(obj):
    payload = obj.get("payload") or {}
    if payload.get("type") == "user_message" and isinstance(payload.get("message"), str):
        return clean_snippet(payload["message"])
    if payload.get("type") == "message" and payload.get("role") == "user":
        for part in payload.get("content") or []:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                return clean_snippet(part["text"])
    return None


def codex_record(path, mtime):
    cwd = None
    session_id = os.path.splitext(os.path.basename(path))[0]
    for obj in json_lines(read_head(path)):
        if obj.get("type") == "session_meta":
            payload = obj.get("payload") or {}
            cwd = payload.get("cwd")
            session_id = payload.get("id") or payload.get("session_id") or session_id
            break
    if not isinstance(cwd, str):
        return None
    snippet = last = None
    for obj in reversed(list(json_lines(read_tail(path)))):
        if last is None:
            last = parse_timestamp(obj.get("timestamp"))
        if snippet is None:
            snippet = codex_user_text(obj)
        if last and snippet:
            break
    if last is None:
        return None
    return {"provider": "codex", "id": session_id, "cwd": cwd, "mtime": mtime,
            "lastActivity": last, "snippet": snippet}


def recent_files(root, recursive, cutoff):
    if not os.path.isdir(root):
        return
    if recursive:
        walker = ((d, files) for d, _, files in os.walk(root))
    else:
        walker = ((os.path.join(root, d), os.listdir(os.path.join(root, d)))
                  for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)))
    for directory, files in walker:
        for name in files:
            # `._*`는 맥에서 tar로 복사할 때 딸려온 AppleDouble 메타파일이다.
            if not name.endswith(".jsonl") or name.startswith("._"):
                continue
            path = os.path.join(directory, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if st.st_mtime > cutoff:
                yield path, st.st_mtime


def main():
    home = os.path.expanduser("~")
    now = time.time()
    cutoff = now - WINDOW_SECONDS
    records = []
    for path, mtime in recent_files(os.path.join(home, ".claude", "projects"), False, cutoff):
        try:
            rec = claude_record(path, mtime)
        except OSError:
            rec = None
        if rec:
            records.append(rec)
    for path, mtime in recent_files(os.path.join(home, ".codex", "sessions"), True, cutoff):
        try:
            rec = codex_record(path, mtime)
        except OSError:
            rec = None
        if rec:
            records.append(rec)
    records.sort(key=lambda r: r["lastActivity"], reverse=True)
    json.dump({"version": 1, "host": os.uname().nodename, "home": home,
               "generatedAt": now, "records": records}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
