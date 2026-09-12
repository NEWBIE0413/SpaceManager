#!/usr/bin/env python3
"""Companion to tmux-resurrect: custom pane identity, matched by coordinate AND cwd."""
import json
from pathlib import Path
import shlex
import subprocess
import sys


def panes():
    keys = ['session_name', 'window_index', 'pane_index', 'pane_current_path', '@name', '@skey', 'pane_pid']
    result = subprocess.check_output(['tmux', 'list-panes', '-a', '-F', '\t'.join('#{' + k + '}' for k in keys)], text=True)
    return [dict(zip(keys, line.split('\t'))) for line in result.splitlines()]


def preserve_exec_resume(checkpoint, snapshot, proc_root=Path('/proc')):
    """resurrect's ps strategy assumes a shell parent; exec'd Codex has none.

    For an explicit resume, save the pane root instead of its code-mode helper.
    Other process forms keep resurrect's existing strategy until observed otherwise.
    """
    commands = {}
    for pane in snapshot:
        try:
            argv = (proc_root / pane['pane_pid'] / 'cmdline').read_bytes().rstrip(b'\0').decode().split('\0')
        except (OSError, UnicodeError):
            continue
        if len(argv) >= 3 and Path(argv[0]).name == 'codex' and argv[1] == 'resume':
            key = tuple(pane[k] for k in ['session_name', 'window_index', 'pane_index'])
            commands[key] = shlex.join(argv)
    if not commands or not checkpoint.exists():
        return
    lines = []
    changed = False
    for line in checkpoint.read_text().splitlines():
        fields = line.split('\t')
        if len(fields) == 11 and fields[0] == 'pane':
            command = commands.get((fields[1], fields[2], fields[5]))
            if command:
                fields[9], fields[10] = 'codex', ':' + command
                line = '\t'.join(fields)
                changed = True
        lines.append(line)
    if changed:
        # Preserve the last symlink; publish its target atomically under the
        # persistence service's existing operation lock.
        target = checkpoint.resolve()
        temporary = target.with_suffix('.tmp')
        temporary.write_text('\n'.join(lines) + '\n')
        temporary.replace(target)


def main(action, filename):
    path = Path(filename)
    if action == 'save':
        snapshot = panes()
        preserve_exec_resume(path.parent / 'resurrect/last', snapshot)
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(snapshot, ensure_ascii=False))
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
