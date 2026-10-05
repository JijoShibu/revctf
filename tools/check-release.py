#!/usr/bin/env python3
"""Keep the proposed release version and public documentation in agreement."""
import re
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "revctf").read_text(encoding="utf-8")
def require(condition, message):
    if not condition:
        raise SystemExit('Release consistency failed: ' + message)

match = re.search(r'^REVCTF_VERSION="([^"]+)"$', source, re.MULTILINE)
require(match, "REVCTF_VERSION is missing")
version = match.group(1)
require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[1-9][0-9]*)?", version), version)
if os.environ.get('GITHUB_REF', '').startswith('refs/tags/'):
    require(os.environ['GITHUB_REF'] == 'refs/tags/v' + version, 'tag and version disagree')
author = "Jijo Shibu <jijoshibu@gmail.com>"
require(f'REVCTF_AUTHOR="{author}"' in source, "Project author differs from the release author")

output = subprocess.check_output(["bash", "./revctf", "--version"], cwd=ROOT, text=True)
require(output.splitlines()[0] == f"revctf {version}", output)
require(author in output, "Author missing from --version")
readme = (ROOT / "README.md").read_text(encoding="utf-8")
require(f"**Status: v{version}" in readme, "README status version is stale")
changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
require(f"## [{version}]" in changelog, "Changelog entry missing")
notes = ROOT / "docs" / "releases" / f"{version}.md"
require(notes.is_file(), "Release notes missing")
require(notes.read_text(encoding="utf-8").startswith(f"# RevCTF {version}\n"), "Release notes title differs")
require("v" + version in (ROOT / "docs" / "RELEASING.md").read_text(encoding="utf-8"), "Release procedure version is stale")

# Release archives must contain executable Bash scripts with Unix line endings.
for path in [ROOT / "revctf", ROOT / "install.sh", *ROOT.glob("lib/*.sh"), *ROOT.glob("tools/*.sh")]:
    require(b"\r\n" not in path.read_bytes(), f"Windows line endings: {path.relative_to(ROOT)}")
index = subprocess.check_output(['git', 'ls-files', '--stage', 'revctf', 'install.sh'], cwd=ROOT, text=True)
require(len(index.splitlines()) == 2 and all(line.startswith('100755 ') for line in index.splitlines()),
        'revctf and install.sh must have executable Git modes')
for name in ('SECURITY.md', '.github/CODEOWNERS', '.github/workflows/release.yml',
             'dependencies/profile.sh', 'docs/release-evidence.json', 'docs/INDEPENDENT-TEST.md'):
    require((ROOT / name).is_file(), 'required release file missing: ' + name)

profile = (ROOT / 'dependencies/profile.sh').read_text(encoding='utf-8')
locked = {}
for name in ('python-runtime-3.14-amd64.txt', 'python-build-3.14-amd64.txt'):
    for line in (ROOT / 'dependencies' / name).read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        entry = re.fullmatch(r'([A-Za-z0-9_.-]+)==([^ ]+) --hash=sha256:([0-9a-f]{64})', line)
        require(entry, 'Unpinned or unhashed dependency in ' + name)
        package = entry[1].lower().replace('_', '-')
        require(package not in locked, 'Duplicate locked dependency: ' + package)
        locked[package] = entry[2]
for field, package in (('FLOSS_VERSION', 'flare-floss'), ('UNCOMPYLE6_VERSION', 'uncompyle6')):
    expected = re.search(r'^' + field + r'=(.+)$', profile, re.M)
    require(expected and locked.get(package) == expected[1], 'Profile and dependency lock differ: ' + package)
print(f"Release consistency passed: v{version}; author and documentation agree")
