#!/bin/sh
# 원격 활동 미러를 launchd 사용자 에이전트로 설치한다 (호스트당 하나).
#   install-remote-mirror.sh <ssh-host>        설치·시작
#   install-remote-mirror.sh <ssh-host> --uninstall
set -eu
host="${1:?usage: install-remote-mirror.sh <ssh-host> [--uninstall]}"
label="com.seol.space-manager-remote-mirror.$host"
plist="$HOME/Library/LaunchAgents/$label.plist"
script="$(cd "$(dirname "$0")" && pwd)/remote-activity-mirror.sh"
log_dir="$HOME/.space-manager/remote/$host"

if [ "${2:-}" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "removed $label"
    exit 0
fi

mkdir -p "$log_dir" "$HOME/Library/LaunchAgents"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$script</string>
        <string>$host</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$HOME/bin</string></dict>
    <key>StandardErrorPath</key><string>$log_dir/mirror.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed $label → $log_dir/activity.json"
