"""Regression: an exec'd resume must not restore its code-mode helper."""
import importlib.util
from pathlib import Path
import shlex
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('metadata', Path(__file__).with_name('tmux-session-metadata.py'))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class ResumeSaveTests(unittest.TestCase):
    def test_exec_resume_keeps_arguments_and_last_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = root / '123'
            process.mkdir()
            argv = ['/home/u/bin/codex', 'resume', 'session-id', '--cd', '/home/u/my project', '-c', 'model_reasoning_effort=xhigh']
            (process / 'cmdline').write_bytes('\0'.join(argv).encode() + b'\0')
            original = 'pane\thomenet\t0\t1\t:*\t0\tAstra\t:/home/u\t1\tcodex\t:/bin/codex-code-mode-host\n'
            other = 'pane\tother\t0\t1\t:*\t0\tOther\t:/home/u\t1\tbash\t:/bin/bash\n'
            target = root / 'saved.txt'
            target.write_text(original + other)
            last = root / 'last'
            last.symlink_to(target.name)
            snapshot = [dict(session_name='homenet', window_index='0', pane_index='0', pane_pid='123')]
            metadata.preserve_exec_resume(last, snapshot, root)
            lines = last.read_text().splitlines()
            self.assertEqual(shlex.split(lines[0].split('\t')[10][1:]), argv)
            self.assertEqual(lines[1] + '\n', other)
            self.assertTrue(last.is_symlink())
            # A normal shell parent keeps the established resurrect strategy.
            target.write_text(original)
            (process / 'cmdline').write_bytes(b'/bin/bash\0')
            metadata.preserve_exec_resume(last, snapshot, root)
            self.assertEqual(last.read_text(), original)
            (process / 'cmdline').unlink()
            metadata.preserve_exec_resume(last, snapshot, root)
            self.assertEqual(last.read_text(), original)


if __name__ == '__main__':
    unittest.main()
