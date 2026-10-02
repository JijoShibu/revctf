#!/usr/bin/env python3
"""Keep the proposed release version and public documentation in agreement."""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "revctf").read_text(encoding="utf-8")
match = re.search(r'^REVCTF_VERSION="([^"]+)"$', source, re.MULTILINE)
assert match, "REVCTF_VERSION is missing"
version = match.group(1)
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[1-9][0-9]*)?", version), version
author = "Jijo Shibu <jijoshibu@gmail.com>"
assert f'REVCTF_AUTHOR="{author}"' in source, "Project author differs from the release author"

output = subprocess.check_output(["bash", "./revctf", "--version"], cwd=ROOT, text=True)
assert output.splitlines()[0] == f"revctf {version}", output
assert author in output, "Author missing from --version"
readme = (ROOT / "README.md").read_text(encoding="utf-8")
assert f"**Status: v{version}" in readme, "README status version is stale"
changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
assert f"## [{version}]" in changelog, "Changelog entry missing"
notes = ROOT / "docs" / "releases" / f"{version}.md"
assert notes.is_file(), "Release notes missing"
assert notes.read_text(encoding="utf-8").startswith(f"# RevCTF {version}\n"), "Release notes title differs"
assert "v" + version in (ROOT / "docs" / "RELEASING.md").read_text(encoding="utf-8"), "Release procedure version is stale"

# Release archives must contain executable Bash scripts with Unix line endings.
for path in [ROOT / "revctf", ROOT / "install.sh", *ROOT.glob("lib/*.sh"), *ROOT.glob("tools/*.sh")]:
    assert b"\r\n" not in path.read_bytes(), f"Windows line endings: {path.relative_to(ROOT)}"
print(f"Release consistency passed: v{version}; author and documentation agree")
