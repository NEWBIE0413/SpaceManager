#!/usr/bin/env bash
# Linux user service: tmux-resurrect owns layouts/processes; a small companion
# preserves smux pane labels. No status-line client is required for saving.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SMUX_PERSIST_DIR:-$HOME/.smux/state/persistence}"
SOCKET="${SMUX_TMUX_SOCKET:-${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default}"
mkdir -p "$ROOT/resurrect"
exec 9>"$ROOT/operation.lock"
flock -w 130 9
tmux -S "$SOCKET" has-session 2>/dev/null || exit 0
export TMUX="$SOCKET,$(tmux -S "$SOCKET" display-message -p '#{pid}'),0"
tmux set-option -g @resurrect-dir "$ROOT/resurrect"
case "${1:-}" in
  save)
    timeout 120 "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" quiet
    python3 "$HERE/tmux-session-metadata.py" save "$ROOT/metadata.json"
    ;;
  restore)
    [[ -f "$ROOT/resurrect/last" ]] || exit 0
    timeout 120 "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh"
    python3 "$HERE/tmux-session-metadata.py" restore "$ROOT/metadata.json"
    ;;
  *) echo 'usage: remote-tmux-persistence.sh save|restore' >&2; exit 2;;
esac
