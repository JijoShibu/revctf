#!/usr/bin/env python3
"""Run controlled release checks and retain each result, failure and full output."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Linux':
        parser.error('controlled resource tests require Linux')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'results.json').exists():
        parser.error('choose a new output directory; earlier validation evidence is preserved')
    env = dict(os.environ)
    for name in ('REVCTF_TEST_ROOT', 'REVCTF_RAM_MB', 'REVCTF_CEIL_MB', 'ST_MAX_OUT_KB'):
        env.pop(name, None)
    shell_files = [ROOT / 'revctf', ROOT / 'install.sh', *ROOT.glob('lib/*.sh'),
                   *ROOT.glob('tools/*.sh'), *ROOT.glob('dependencies/*.sh')]
    checks = [('syntax-' + p.name, ['bash', '-n', str(p)]) for p in shell_files]
    checks += [
        ('shellcheck', ['shellcheck', '-S', 'style', *(str(p) for p in shell_files)]),
        ('release-consistency', [sys.executable, 'tools/check-release.py']),
        ('reliability', ['bash', 'tools/test-reliability.sh']),
        ('resources', ['bash', 'tools/test-resources.sh']),
        ('accuracy', ['bash', 'tools/test-accuracy.sh']),
        ('qa-recovery', [sys.executable, 'tools/test-qa-recovery.py']),
        ('release-gates', [sys.executable, 'tools/test-release.py']),
        ('publisher', [sys.executable, 'tools/test-publish.py']),
        ('mutation-reader', ['bash', 'tools/verify-harness.sh', '--self-test']),
    ]
    record = dict(started=dt.datetime.now(dt.timezone.utc).isoformat(),
                  environment=platform.platform(), python=sys.version, results=[])
    for name, command in checks:
        started = time.monotonic()
        with (output / (name + '.log')).open('w') as log:
            try:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=180)
                code = result.returncode
            except (OSError, subprocess.TimeoutExpired) as error:
                log.write(str(error) + '\n')
                code = 125
        row = dict(check=name, exit=code, seconds=round(time.monotonic() - started, 3))
        record['results'].append(row)
        (output / 'results.json').write_text(json.dumps(record, indent=2) + '\n')
        if not name.startswith('syntax-') or code:
            print(json.dumps(row), flush=True)
    failed = [r['check'] for r in record['results'] if r['exit']]
    print('Failed checks: ' + (', '.join(failed) if failed else 'none'))
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
