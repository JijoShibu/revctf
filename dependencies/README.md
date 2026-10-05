# Dependency profile

The proposed 2.0 preview runs on Kali Linux amd64. `profile.sh` identifies downloaded
tools; `docker/Dockerfile` identifies the sandbox base by digest. The default sandbox
tag is specific to the preview, so an older `revctf-sandbox:1` image is not silently reused.

| Tool | Proposed version | Source and verification |
|---|---|---|
| Ghidra | 12.1.4 | Official NSA release archive; SHA-256 from the release API |
| Java | Kali OpenJDK 21 JDK | Signed Kali package repository |
| FLOSS | 3.1.1 | PyPI, installed into a separate preview environment |
| uncompyle6 | 3.9.3 | PyPI, same isolated environment |
| PyInstaller extractor | Commit in `profile.sh` | Upstream source at that commit; SHA-256 verified before use |
| Sandbox | Debian stable-slim digest in Dockerfile | Official Docker library image; tracers installed inside |

**Final validation is pending.** Earlier Kali results used Ghidra 11.2.1. They do not
validate 12.1.4, the Java output script, or the revised installer. The Python lock files
include selected packages, their required packages and build tools, with SHA-256
hashes. They target Kali 2026.3 with CPython 3.14 on Intel/AMD 64-bit Linux.
Installation refuses a different Python minor version or processor architecture
rather than silently choosing untested packages. Source packages build with the
pinned tools, without downloading a separate build environment.
`installed-versions.txt` records what was actually installed. Final installation and
scan checks for this profile remain pending.

Ghidra 12.1.4 was selected after reviewing the upstream security notices available on
3 October 2026, including Windows executable import, database parsing, XML loader,
and Swift demangler issues. See the [official advisories](https://github.com/NationalSecurityAgency/ghidra/security).
Some issues need particular formats or host settings; the review does not claim this
installation was exploited or that any version is free from vulnerabilities.

The default script uses Ghidra's Java interface to avoid depending on a Python launcher.
Custom Java scripts use that launcher. Custom Python scripts require the appropriate
Ghidra Python runtime; a missing runtime is reported as failed analysis. Optional Java/.NET
decompilers are outside the core Linux/Windows release promise and remain conditional
on their availability and separate sample tests.

System packages receive Kali security updates. Record their actual versions during each
release rehearsal. Dependency upgrades need a separate pull request and affected tests;
automatic update proposals do not merge themselves. Fully offline installation is not
provided. Scanning works offline after the tools and sandbox are installed.
