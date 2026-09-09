#!/usr/bin/env python3
"""Compare scanner-only release executables on identical synthetic transcripts.

Usage: python3 scripts/benchmark-scanners.py [baseline git revision]
Outputs and generated binaries stay under ignored .build/scanner-benchmark/.
"""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
output = root / '.build/scanner-benchmark'
output.mkdir(parents=True, exist_ok=True)
revision = sys.argv[1] if len(sys.argv) > 1 else 'e88f8d5'
models = root / 'Sources/SpaceManager/Models'
common = ['QuickConversationScanner.swift', 'RecentActivityScanner.swift', 'AgentActivitySources.swift']
baseline = output / 'baseline'
baseline.mkdir(exist_ok=True)
for name in common:
    source = subprocess.check_output(['git', 'show', f'{revision}:Sources/SpaceManager/Models/{name}'], cwd=root, text=True)
    # Expose the original scan/cache to the harness without changing its behavior.
    (baseline / name).write_text(source.replace('private ', ''))

results = {}
for label in ['baseline', 'optimized']:
    files = [str(baseline / name) for name in common] if label == 'baseline' else [str(models / name) for name in common + [
        'FileMetadataCache.swift', 'TranscriptTitleIndex.swift', 'GeneratingActivityIndex.swift',
        'DirectoryWatcher.swift', 'AppResourcePolicy.swift',
    ]]
    executable = output / label
    if label == 'baseline':
        executable = output / 'baseline-runner'
    command = ['swiftc', '-O', '-parse-as-library']
    if label == 'optimized':
        command += ['-D', 'OPTIMIZED']
    subprocess.run(command + files + [str(root / 'scripts/benchmark-scanners.swift'), '-o', str(executable)], check=True)
    measured = subprocess.run(['/usr/bin/time', '-l', str(executable)], check=True, text=True, capture_output=True)
    results[label] = json.loads(measured.stdout)
    (output / f'{label}-time.txt').write_text(measured.stderr)
    print(label, json.dumps(results[label], indent=2), flush=True)
(output / 'results.json').write_text(json.dumps({'baseline_revision': revision, **results}, indent=2) + '\n')
