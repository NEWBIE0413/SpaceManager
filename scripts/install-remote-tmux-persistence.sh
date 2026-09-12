#!/usr/bin/env bash
# Run on the Linux tmux owner after restoring/migrating its initial sessions.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.smux/bin" "$HOME/.config/systemd/user/tmux-server.service.d"
for script in remote-tmux-persistence.sh tmux-session-metadata.py; do
  [[ "$HERE/$script" == "$HOME/.smux/bin/$script" ]] || install -m 755 "$HERE/$script" "$HOME/.smux/bin/$script"
done
cat > "$HOME/.config/systemd/user/tmux-persistence.service" <<'EOF'
[Unit]
Description=Save tmux sessions without requiring an attached status-line client
After=tmux-server.service

[Service]
Type=oneshot
ExecStart=%h/.smux/bin/remote-tmux-persistence.sh save
TimeoutStartSec=150
EOF
cat > "$HOME/.config/systemd/user/tmux-persistence.timer" <<'EOF'
[Unit]
Description=Periodic tmux session checkpoint

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
cat > "$HOME/.config/systemd/user/tmux-server.service.d/persistence.conf" <<'EOF'
[Service]
ExecStartPost=%h/.smux/bin/remote-tmux-persistence.sh restore
ExecStop=
ExecStop=%h/.smux/bin/remote-tmux-persistence.sh save
ExecStop=/usr/bin/tmux kill-server
TimeoutStartSec=150
TimeoutStopSec=150
EOF
# Explicit startup service replaces continuum's process-count heuristic. Saving
# remains useful while every client is detached or its status-right was themed.
CONF="$HOME/.config/tmux/workspace-persistence.conf"
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<'EOF'
# Match the pane numbering in the migrated Mac checkpoints. Resurrect assumes
# the same pane-base-index at save and restore; a mismatch merges adjacent panes.
set -g base-index 0
set -g pane-base-index 0
set -g @continuum-restore off
set -g @continuum-save-interval 0
set -g @resurrect-processes '~claude ~codex'
set -g @resurrect-dir '~/.smux/state/persistence/resurrect'
EOF
LINE='source-file ~/.config/tmux/workspace-persistence.conf'
for file in "$HOME/.config/tmux/tmux.conf" "$HOME/.tmux.conf"; do
  touch "$file"
  grep -Fxq "$LINE" "$file" || printf '\n%s\n' "$LINE" >> "$file"
done
tmux source-file "$CONF"
systemctl --user daemon-reload
systemctl --user enable --now tmux-persistence.timer
systemctl --user start tmux-persistence.service
