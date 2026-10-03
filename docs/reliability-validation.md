# 2.0 preview validation

Prepared on 2026-10-02; installation and cleanup completed on 2026-10-03 (India time).
This is a release-preparation record, not a publication claim.
The fixes are in pull request #2, which remains unmerged.

## Environment

Real Kali VM: 4096 MB configured, 3915 MiB Linux-reported total RAM, approximately 5 GB
of existing swap. Kali rolling 2026.3, kernel 7.1.5+kali-amd64, Bash 5.3.15, Docker
28.5.2, Java 21.0.12.1 and Ghidra 11.2.1/Jython. Heavy tests run sequentially.
This does not establish operation with 2 GB allocated or with swap disabled.

## Completed measurements

| Check | Observed result |
|---|---|
| Startup RAM gate | Simulated below/at/above-threshold and unknown values, explicit overrides, and config/`--yes`/tier bypass attempts passed. The real 4 GB VM passed. |
| Output size | Both runner paths in normal and POSIX Bash retained no more than 16,384 bytes at a 16 KiB limit. Complete early candidates survived; a flag beyond the cutoff was absent. |
| Docker lifecycle | Eight real checks passed: INT, TERM, HUP, timeout, simultaneous scans, unexpected exit, interruption during creation, and exact 16 KiB enforcement. A ninth, focused rerun measured a 67,108,864-byte container limit, confirmed a real out-of-memory kill, and verified removal. |
| Ghidra and acceptance | Heap measurements at three allowances, custom script paths, failed scripts, and independent password acceptance passed. |
| Overriding launcher | Actual heap 2,075,918,336 bytes exceeded requested 1,073,741,824; guard recorded `verified=0`, stopped analysis and scan returned 2. |
| Earlier broad native suite | 157 passed, 2 outdated assertions failed, 1 corpus check skipped. Assertions were corrected; the built corpus and documentation later passed 32 checks. |
| Large-file streaming | A safely generated 220 MB sample passed; measured peak resident memory was 109,160 KiB. |

The broad suite covered plain/encoded flags, packed and stripped Linux files, Windows
samples, malformed packing, no-flag samples, managed/Python routing, native tools, real
Ghidra recovery and Docker isolation. Candidate checks inspect the candidate section or
actual decompiler results; arbitrary appearances elsewhere in a report do not count.

### Measured Ghidra limits

| Requested analysis heap | Actual maximum heap (bytes) | Actual process limit (bytes) | Known password |
|---|---:|---:|---|
| 512 MiB | 518,979,584 | 805,306,368 (768 MiB) | Recovered |
| 768 MiB | 778,502,144 | 1,073,741,824 (1024 MiB) | Recovered |
| 1024 MiB | 1,037,959,168 | 1,342,177,280 (1280 MiB) | Recovered |

The controlled challenge accepted recovered password `sw0rdf1sh` and returned
`Correct! flag{cr4ckm3_s0lv3d}`. Acceptance was checked independently; the application
continues to label candidates UNVERIFIED. A deliberately failing custom script returned
2 and preserved its partial output.

## Timing at 4 GB

Baseline: commit `20f17c8`. Each pair performed equivalent requested analysis, returned
0 and recovered the expected answer. Versions alternated order to reduce warm-cache bias.

| Sample | Before median | After median | Runs per version |
|---|---:|---:|---:|
| Ordinary native scan | 17.775 s | 17.641 s | 3 |
| Packed native scan | 16.183 s | 11.537 s | 3 |
| Ghidra, first round | 34.161 s | 41.389 s | 3 |
| Ghidra, investigation repeat | 37.734 s | 39.455 s | 3 |
| Ghidra, both rounds combined | 35.948 s | 39.636 s | 6 |

The combined Ghidra median rose by about 3.7 seconds (10.3%). Its first-round analysis
stage median differed by approximately one second; startup and other work also varied.
The checked heap and supporting-memory allowance add work and constrain the previously
overriding launcher. The measurements do not isolate a single cause or promise a uniform
speed change. Search coverage and time allowances were not reduced.

## Final-code checks and release gates

The release source started at `e4f78e5`; subsequent changes pin the CI tool version,
make the generated memory probe executable by the sandbox user, and complete author
credits/comments. Runtime code, including the final report-credit fallback, was checked
again in Kali. Commit `caf429d` additionally fixes the installer's missing Java dependency
and retries interrupted Ghidra downloads. Its installation checks use that exact source.
Documentation-only changes are checked separately.

| Final proposed behavior | Result |
|---|---|
| Shell syntax, ShellCheck 0.11.0, version consistency | Passed in Kali |
| Controlled reliability, including installer dependency handling | 38 passed, 0 failed, 0 skipped |
| Linux resource checks | 33 passed, 0 failed |
| Native, corpus, basic CLI, Docker, Ghidra and documentation suite | 122 passed, 0 failed, 0 skipped |
| Real memory enforcement | 34 passed, 0 failed, 2 skipped |
| Container lifecycle | Eight checks passed in the full run; corrected ninth check passed separately |
| Final documentation rerun | 20 passed, 0 failed, 0 skipped |
| Fresh sandbox image | Build passed; ltrace and strace completed; their exact containers were absent afterward |

The two memory-suite skips are its old 1 MiB Docker tests: Docker requires at least
6 MiB. The separate 64 MiB test actually exceeds an accepted container limit and checks
both the measured limit and Docker's out-of-memory evidence. These skips are not passes.

The first ninth lifecycle check failed because the developer's restrictive file-creation
permissions made its generated executable inaccessible to the sandbox user. The test
now explicitly grants executable permissions; the focused rerun passed. No application
resource setting was raised to make the test pass.

The initial hosted check used an older distribution ShellCheck and failed on indirect
shell functions. CI now downloads ShellCheck 0.11.0 with its verified checksum. All basic
checks passed at `4800a2e` ([run 36981719009](https://github.com/JijoShibu/revctf/actions/runs/36981719009)).
After the installer correction, all hosted checks passed again at `99cf86c`, including
38 reliability checks and 33 resource checks
([run 37048168650](https://github.com/JijoShibu/revctf/actions/runs/37048168650)).
The final documentation-only head's check and archive identity are recorded in the
pull request and local review manifest, avoiding a commit referring to its own hash.

### Clean installation

The disposable Kali image was
`kalilinux/kali-rolling@sha256:ed99295a386abde2fb31e01a441b7c2800d9bcf19a20028b77d642c3ef068363`.
It started without the analysis tools and ran without privileged mode or a Docker socket.
Its memory limit was 3072 MiB within the real 4096 MB VM; this is not a separate physical
3 GB or 2 GB VM test.

The first rehearsal exposed missing Java: the installer had relied on optional packages
to supply it. The Ghidra download was also interrupted when the VM was saved and its
network became unavailable. A second installation attempt failed on package downloads
before the guest's network lease was renewed. Both failed containers were removed and
their logs retained. The corrected installer explicitly installs `openjdk-21-jdk-headless`,
reports its failure, and retries interrupted Ghidra downloads within a time limit.

The first fresh sandbox build failed on DNS after VM resume. Once connectivity returned,
the rebuild passed and a scan using that newly built image completed both tracing stages.
Their containers were verified absent and the temporary image tag was removed.

Optional `procyon-decompiler` and `jd-cli` packages were unavailable in this Kali package
list. Their Java-decompiler paths are not validated by this clean install. `mono-utils`
was available. Docker was deliberately absent from the installation container: its
warning and the separately tested sandbox build are expected parts of this rehearsal.

The corrected clean installation returned 0 and found every required tool. FLOSS was
3.1.1, Java was 21.0.12.1, and the pinned Ghidra was 11.2.1. With all container networks
disconnected (Docker reported `{}`), the controlled native scan returned 0, recovered
`flag{cr4ckm3_s0lv3d}` in the candidate section as UNVERIFIED, and recovered `sw0rdf1sh`
in Ghidra output. The independently executed challenge on the Kali VM accepted that
recovered password and rejected a deliberately wrong password.

The installation harness initially could not read the root-owned private report directory.
Only that test evidence's ownership was corrected; the original error record was kept.
The actual report and captures were then inspected and acceptance checked separately.
No application output permissions were weakened. Per-stage whole-process enforcement
was unavailable inside this container; its outer 3072 MiB limit remained in force. The
three measured Ghidra process limits above come from separate real-VM checks.

The interrupted earlier regression run is not counted as complete. Its two temporary-path
failures and two stale output-label assertions were identified. The resumed suite returned
188 passed, 4 failed, 0 skipped: two README-based executable assumptions and two invalid
1 MiB Docker checks. The final suites use executable controls and the 64 MiB container
breach. Original failed logs remain part of the retained evidence. The resumed suite's
QA checks passed, including interrupted reports, hostile filenames, large files, and a
streamed 3 GB logical archive-expansion fixture.

Git Bash on Windows was used for syntax/style checks, but invoking the release check
through Windows Python could not launch Bash successfully in this host environment.
The same release check passed in Kali and hosted Linux CI. Windows-host execution is
not a supported scan environment; Windows executable samples were analyzed on Kali.

The 2 GB VM test, Ghidra 12.x integration, arbitrary automatic solution/acceptance,
and real-terminal display inspection are not established by the completed checks.
SIGKILL/host crashes can prevent cleanup. Unreachable Docker cleanup is bounded and
reported honestly, but cannot guarantee the daemon stopped a container.

Publication, post-publication anonymous download verification, seven days of preview
availability, and an independent tester's Kali report remain future gates.

## Evidence and test-machine restoration

The local evidence archive `revctf-2.0-preview-evidence.tar.gz` contains the measured
results, captures, original failed runs, corrected reruns and timing records. Its SHA-256
is `963d148cc4ae2644a2da688217c8256b29e29b00461ee8468b37d82f190f76da`; the copied Windows
archive matched the Kali checksum. It is retained locally, outside the repository and
release source archive. A separate comparison found no mismatches in 47 runtime and
test files between the proposed source and the final Kali checkout.

Cleanup verification found no scan-owned containers, installation containers or temporary
sandbox image tags. No running test challenge remained. Unrelated containers were not
removed. Kali was shut down normally and verified powered off with 16384 MB configured.
Its original `AD` NAT-network setting was restored after a temporary standard-NAT setup
used to recover package downloads. Existing swap was not changed.

The review archive and its checksum identify the exact final pull-request commit in a
separate review manifest. They are preparation artifacts, not published release assets.
