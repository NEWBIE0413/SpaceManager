#!/usr/bin/env python3
"""Copy the local smux display/navigation settings to an SSH tmux owner."""
from pathlib import Path
import json
import shlex
import subprocess
import sys
import time

host = sys.argv[1]
home = Path.home()
source = (home / '.smux/tmux.conf').read_text().split('# === session persistence')[0]
# Process names differ across Darwin/Linux; keep the same visible agent icons.
source = source.replace('#{m:2.*,#{pane_current_command}}', '#{||:#{m:2.*,#{pane_current_command}},#{==:#{pane_current_command},claude}}')
source = source.replace('#{m:node,#{pane_current_command}}', '#{||:#{m:node,#{pane_current_command}},#{==:#{pane_current_command},codex}}')
options = '''prefix prefix2 base-index renumber-windows detach-on-destroy history-limit
status-position status-interval status-left-length status-right-length window-status-separator
mode-keys status-keys window-size aggressive-resize automatic-rename automatic-rename-format
escape-time extended-keys extended-keys-format focus-events allow-passthrough'''.split()
expected = {}
for option in options:
    value = subprocess.check_output(['tmux', 'show-options', '-gqv', option], text=True).rstrip('\n')
    expected[option] = value
    source += '\nset-option -g ' + option + ' ' + shlex.quote(value)
bindings = subprocess.check_output(['tmux', 'list-keys', '-T', 'root'], text=True)
source += '\n# Replace conflicting Omarchy Option shortcuts with the Mac root key table.\n'
source += 'unbind-key -a -T root\n' + bindings
source += '\n# Saving is handled by the Linux service, not an invisible status command.\nset -g status-right ""\n'
destination = '~/.config/tmux/workspace-display.conf'
subprocess.run(['ssh', host, 'mkdir -p ~/.config/tmux ~/.smux/backups/workspace-sync'], check=True)
for config in ['~/.config/tmux/tmux.conf', '~/.tmux.conf']:
    backup = '~/.smux/backups/workspace-sync/' + ('xdg' if '/.config/' in config else 'home') + '-tmux.conf-' + str(int(time.time()))
    subprocess.run(['ssh', host, 'test ! -f ' + config + ' || cp ' + config + ' ' + backup], check=True)
subprocess.run(['ssh', host, 'cat > ' + destination], input=source.encode(), check=True)
# tmux on this Arch desktop reads XDG config first. Install in both entry points
# so manual reload and the pre-warmed user service follow the same overrides.
script = '''
for file in "$HOME/.config/tmux/tmux.conf" "$HOME/.tmux.conf"; do
  for entry in workspace-display.conf workspace-persistence.conf; do
    line="source-file ~/.config/tmux/$entry"
    grep -Fxq "$line" "$file" || printf '\\n%s\\n' "$line" >> "$file"
  done
done
tmux source-file ~/.config/tmux/workspace-display.conf
tmux source-file ~/.config/tmux/workspace-persistence.conf
'''
subprocess.run(['ssh', host, 'bash -s'], input=script.encode(), check=True)
print(json.dumps({'host': host, 'matched_options': expected, 'root_bindings': len(bindings.splitlines())}))
