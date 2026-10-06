#!/usr/bin/env python3
"""Build reviewed source archives and enforce publication prerequisites."""
import argparse
import datetime as dt
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    'kali_4gb', 'ram', 'container_cleanup', 'output_limits', 'ghidra',
    'known_answers', 'regression', 'installation', 'offline', 'upgrade_rollback', 'timing',
)


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode().strip()


def version():
    match = re.search(r'^REVCTF_VERSION="([^"]+)"$', (ROOT / 'revctf').read_text(), re.M)
    if not match or not re.fullmatch(r'\d+\.\d+\.\d+(?:-rc\.[1-9]\d*)?', match[1]):
        raise ValueError('Missing or invalid program version')
    return match[1]


def runtime_digest():
    digest = hashlib.sha256()
    for path in sorted(git('ls-files').splitlines()):
        if path in ('revctf', 'install.sh') or path.startswith(('lib/', 'scripts/', 'docker/', 'dependencies/')):
            data = (ROOT / path).read_bytes()
            digest.update(path.encode() + b'\0' + str(len(data)).encode() + b'\0' + data)
    return digest.hexdigest()


def validate_evidence(record, expected_version, expected_digest):
    if record.get('version') != expected_version or record.get('runtime_sha256') != expected_digest:
        raise ValueError('Kali evidence does not identify this runtime and version')
    if record.get('configured_ram_mib') != 4096:
        raise ValueError('Final validation must use the real 4096 MiB Kali configuration')
    checks = record.get('checks', {})
    missing = [name for name in REQUIRED if checks.get(name, {}).get('result') != 'passed' or
               not checks.get(name, {}).get('evidence')]
    if missing:
        raise ValueError('Release checks still incomplete: ' + ', '.join(missing))
    if record.get('open_blockers') or not record.get('vm_restored_16gb'):
        raise ValueError('Resolve release blockers and restore the test VM first')


def api(path):
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'revctf-release'}
    if os.environ.get('GH_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
    request = urllib.request.Request('https://api.github.com/repos/JijoShibu/revctf/' + path, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def direct_stable_approved(record, expected_version):
    """Recognize the maintainer's recorded decision for this release only."""
    decision = record.get('stable_release_decision') or {}
    return (expected_version == '2.0.0' and decision.get('version') == expected_version and
            decision.get('maintainer') == 'Jijo Shibu <jijoshibu@gmail.com>' and
            decision.get('preview_wait_waived') is True and
            decision.get('independent_report_waived') is True and
            decision.get('required_controlled_checks') is True and
            decision.get('approved_on') == '2026-10-05')


def check_stable(record, releases, now):
    previews = [r for r in releases if r.get('prerelease') and not r.get('draft') and
                re.fullmatch(r'v2\.0\.0-rc\.[1-9]\d*', r.get('tag_name', ''))]
    if not previews:
        raise ValueError('Publish and verify a preview before stable 2.0.0')
    preview = max(previews, key=lambda r: r['published_at'])
    published = dt.datetime.fromisoformat(preview['published_at'].replace('Z', '+00:00'))
    if now - published < dt.timedelta(days=7):
        raise ValueError('The latest preview has not been available for seven days')
    report = record.get('independent_test') or {}
    if (report.get('version') != preview['tag_name'][1:] or report.get('result') != 'passed' or
            report.get('maintainer_reviewed') is not True or not report.get('issue_number') or
            report.get('tester', '').lower() in ('', 'jijoshibu')):
        raise ValueError('An independent Kali report reviewed by the maintainer is required')
    return report


def gate(expected_version, source):
    if not re.fullmatch(r'[0-9a-f]{40}', source) or git('rev-parse', 'HEAD') != source:
        raise ValueError('The reviewed 40-character commit must be checked out exactly')
    if expected_version != version():
        raise ValueError('Requested release version differs from the program')
    if git('status', '--porcelain'):
        raise ValueError('Build from a clean committed checkout')
    record = json.loads((ROOT / 'docs/release-evidence.json').read_text())
    validate_evidence(record, expected_version, runtime_digest())
    if '-rc.' not in expected_version and not direct_stable_approved(record, expected_version):
        report = check_stable(record, api('releases?per_page=100'), dt.datetime.now(dt.timezone.utc))
        issue = api('issues/' + str(int(report['issue_number'])))
        if issue.get('user', {}).get('login', '').lower() != report['tester'].lower():
            raise ValueError('Independent report author does not match the GitHub issue')


def build(destination, expected_version):
    if version() != expected_version:
        raise ValueError('Archive version differs from program version')
    source = git('rev-parse', 'HEAD')
    if git('status', '--porcelain'):
        raise ValueError('Archive requires a clean committed checkout')
    archive = subprocess.check_output(['git', 'archive', '--format=tar',
        '--prefix=revctf-' + expected_version + '/', source], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:') as tf:
        for member in tf:
            parts = Path(member.name).parts[1:]
            if member.issym() or member.islnk() or '..' in parts:
                raise ValueError('Unexpected archive link or path: ' + member.name)
            if any(p in ('.env', '.claude', '.codex', 'test-corpus', 'node_modules', '__pycache__') or
                   p.endswith(('.pem', '.key', '.pyc')) for p in parts):
                raise ValueError('Private or local artifact in archive: ' + member.name)
            if member.isfile():
                data = tf.extractfile(member).read()
                if re.search(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}', data):
                    raise ValueError('Possible credential in archive: ' + member.name)
    destination.mkdir(parents=True, exist_ok=True)
    name = 'revctf-' + expected_version + '.tar.gz'
    packed = gzip.compress(archive, mtime=0)
    checksum = hashlib.sha256(packed).hexdigest()
    (destination / name).write_bytes(packed)
    (destination / (name + '.sha256')).write_text(checksum + '  ' + name + '\n')
    (destination / 'manifest.json').write_text(json.dumps({
        'version': expected_version, 'source_commit': source, 'runtime_sha256': runtime_digest(),
        'archive': name, 'sha256': checksum,
        'author': 'Jijo Shibu <jijoshibu@gmail.com>',
    }, indent=2) + '\n')
    return checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('digest', 'gate', 'build'))
    parser.add_argument('--version')
    parser.add_argument('--commit')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'digest':
            print(runtime_digest())
        elif args.command == 'gate':
            gate(args.version, args.commit)
            print('Publication prerequisites passed')
        elif args.output is not None:
            print(build(args.output, args.version))
        else:
            parser.error('--output is required for build')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, 'Release stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
