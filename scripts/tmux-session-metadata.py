#!/usr/bin/env python3
"""Companion to tmux-resurrect: custom pane identity, matched by coordinate AND cwd."""
import json
from pathlib import Path
import subprocess
import sys


def panes():
    keys = ['session_name', 'window_index', 'pane_index', 'pane_current_path', '@name', '@skey']
    result = subprocess.check_output(['tmux', 'list-panes', '-a', '-F', '\t'.join('#{' + k + '}' for k in keys)], text=True)
    return [dict(zip(keys, line.split('\t'))) for line in result.splitlines()]


def main(action, filename):
    path = Path(filename)
    if action == 'save':
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(panes(), ensure_ascii=False))
        temporary.replace(path)
        return
    if not path.exists():
        return
    current = {(p['session_name'], p['window_index'], p['pane_index']): p for p in panes()}
    for old in json.loads(path.read_text()):
        key = tuple(old[k] for k in ['session_name', 'window_index', 'pane_index'])
        now = current.get(key)
        if not now or now['pane_current_path'] != old['pane_current_path']:
            continue
        target = '=' + key[0] + ':' + key[1] + '.' + key[2]
        for option in ['@name', '@skey']:
            if old.get(option):
                subprocess.run(['tmux', 'set-option', '-p', '-t', target, option, old[option]], check=True)
    # resurrect switches the current client to restore window selection. A user
    # service has no client, so select the saved window directly in its session.
    checkpoint = path.parent / 'resurrect/last'
    if checkpoint.exists():
        for line in checkpoint.read_text().splitlines():
            fields = line.split('\t')
            if len(fields) >= 5 and fields[0] == 'window' and fields[4] == '1':
                subprocess.run(['tmux', 'select-window', '-t', '=' + fields[1] + ':' + fields[2]], check=True)


if __name__ == '__main__':
    main(*sys.argv[1:])
