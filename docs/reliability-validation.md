# 2.0 preview validation

Prepared on 2026-10-02. This is a release-preparation record, not a publication claim.
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
| Docker lifecycle | Eight real checks passed: INT, TERM, HUP, timeout, simultaneous scans, unexpected exit, interruption during creation, and exact 16 KiB enforcement. A new actual-memory-breach check is pending below. |
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

Final-code tests, the clean installation rehearsal, CI results, evidence archive identity,
and VM restoration are still being recorded. Do not publish based on this interim section.

The interrupted earlier regression run is not counted as complete. Its two temporary-path
failures and two stale output-label assertions were identified. The resumed suite also
exposed README-based executable assumptions and an invalid 1 MB Docker test: Docker
requires at least 6 MB. Those are replaced by executable controls and a measured 64 MiB
container breach. Any remaining failures will be retained in the final record.

The 2 GB VM test, Ghidra 12.x integration, arbitrary automatic solution/acceptance,
and real-terminal display inspection are not established by the completed checks.
SIGKILL/host crashes can prevent cleanup. Unreachable Docker cleanup is bounded and
reported honestly, but cannot guarantee the daemon stopped a container.

Publication, post-publication anonymous download verification, seven days of preview
availability, and an independent tester's Kali report remain future gates.
