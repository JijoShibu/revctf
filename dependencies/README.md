# Dependency profile

RevCTF 2.0.0 runs on Kali Linux amd64. `profile.sh` identifies downloaded
tools; `docker/Dockerfile` identifies the sandbox base by digest. The default sandbox
tag is specific to the release, so an older `revctf-sandbox:1` image is not silently reused.

| Tool | Selected version | Source and verification |
|---|---|---|
| Ghidra | 12.1.4 | Official NSA release archive; SHA-256 from the release API |
| Java | Kali OpenJDK 21 JDK | Signed Kali package repository |
| FLOSS | 3.1.1 | PyPI, installed into a separate release environment |
| uncompyle6 | 3.9.3 | PyPI, same isolated environment |
| PyInstaller extractor | Commit in `profile.sh` | Upstream source at that commit; SHA-256 verified before use |
| Sandbox | Debian stable-slim digest in Dockerfile | Official Docker library image; tracers installed inside |

The 2.0.0 profile was checked on a real 4 GB Kali VM. Ghidra 12.1.4 heaps and
process limits were measured, a known password was recovered and accepted, and
an overriding launcher was rejected. The earlier 11.2.1 results remain historical. The Python lock files
include selected packages, their required packages and build tools, with SHA-256
hashes. They target Kali 2026.3 with CPython 3.14 on Intel/AMD 64-bit Linux.
Installation refuses a different Python minor version or processor architecture
rather than silently choosing untested packages. Source packages build with the
pinned tools, without downloading a separate build environment.
`installed-versions.txt` records the Python packages actually installed. System package
versions are recorded separately during rehearsal. Clean installation, repeat installation
and an offline known-answer scan passed with the 2.0.0 defaults. Optional
`procyon-decompiler` and `jd-cli` were unavailable and are outside the core native-file
support promise. See [validation results](../docs/stable-validation-status.md).

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
