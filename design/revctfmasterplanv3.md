# revctf — Masterplan v3 (4GB RAM Retune + v2 Hardening)

A Bash CLI for Kali Linux that runs `file`, `strings`, `binwalk`, `hexdump`, `ltrace`, `radare2`, and `ghidra` (headless) against a Reverse Engineering CTF challenge file — or a directory of them — and produces a beginner-friendly plain-text report with auto-detected flag candidates surfaced at the top.

**Target environment:** Kali VM, **4GB RAM** (raised from 2GB), **full XFCE desktop running alongside** (~600–800MB OS baseline), brief network access available during setup/install (not fully air-gapped thereafter).

This revision raises the RAM target from 2GB to 4GB and re-tunes every memory-dependent decision against that new budget, while carrying forward every hardening fix confirmed correct by the v2 technical review (sandbox build timing, network isolation, binwalk forward-compatibility, radare2 symbol matching, Ghidra OOM messaging, RAM preflight detection).

---

## 1. Decision Summary

| Area | Decision |
|---|---|
| Interface | Pure CLI, flags/args |
| Orchestration | Fully autonomous, fixed 7-tool pipeline, no pauses |
| Dynamic analysis safety | Host by default; opt-in `--sandbox` (Docker, network-isolated) for the `ltrace` step |
| File scope | ELF + PE + others (Mach-O, firmware, unknown) |
| Ghidra depth | Headless scripted decompile, auto-injected into report |
| Report format | Plain text, stdout + saved file |
| Flag detection | On by default; tiered confidence + custom `--flag-format` |
| Report verbosity | Beginner-friendly explanations above raw output |
| Language | Bash, zero core dependencies (Docker only required if `--sandbox` used) |
| Scope (files) | Single file **or** batch/directory |
| Missing tools | Pre-flight check (`PATH` + `GHIDRA_HOME` + `/opt/ghidra*` scan) |
| ltrace hang risk | Fixed default timeout (10s), `setsid` + process-group kill sweeps orphans |
| hexdump size | Capped preview by default, `--full-hexdump` opt-in, streamed to disk |
| Ghidra version | Two dedicated scripts (PyGhidra / Jython), auto-selected; `--ghidra-script` override |
| Name | **revctf** |
| **RAM target** | **4GB, XFCE desktop assumed (~600–800MB OS baseline)** |
| **Batch execution model** | **Two phases, never interleaved: (1) light stages at `-P 4`, fully complete; (2) Ghidra at `-P 2`, runs after** |
| **Ghidra JVM heap** | **`MAXMEM=1024M`** (raised from 768M) |
| **radare2 per-process ceiling** | **`ulimit -v 640000` (640MB)** — re-tuned for `-P 4` under the XFCE assumption |
| Sandbox backend | Docker; **image built during `install.sh`** (confirmed network window), `stage_ltrace.sh` only checks for its existence; container run with `--network=none --read-only --user nobody --memory=256m --pids-limit=64 --cap-drop=ALL` |
| Flag confidence tiers | Known formats + `--flag-format` matches = High; generic bracket matches = Low; High listed first |
| Lighter decompile path | Opt-in `--light-decompile` flag swaps Ghidra's decompile for a radare2-only pass; also auto-suggested in the report when Ghidra fails with an OOM error |
| binwalk version drift | Numeric major-version check (`≥3`), not a literal `"3."` substring match — forward-compatible with future releases |
| radare2 stripped/symbol handling | `\bmain\b` word-boundary match before falling back to `entry0`, avoiding false positives on symbols like `domain_main_init` |
| RAM preflight | Detects actual system RAM via `free -m`; warns if below the tuned 4GB target rather than assuming the stated figure always holds |
| Subprocess memory bounding | Every external tool call wrapped in `ulimit -v`, sized per-tool against the relevant concurrency phase |
| Large output capture | Streamed directly to disk, never buffered in Bash variables |
| Batch job isolation | Per-job `mktemp -d` + `flock`-protected results file |
| README additions | Swap-file recommendation; `--sandbox` network-window note; XFCE-vs-headless baseline statement; `--sandbox` + large batch runs flagged as the tightest resource combination |

---

## 2. Goal

Build `revctf`: a scriptable, autonomous, plain-text-reporting CLI that orchestrates the full 7-tool RE toolchain against one or more challenge files, tuned to run reliably on a 4GB RAM Kali VM running a full XFCE desktop — with the two-phase batch design (light stages, then Ghidra) confirmed to eliminate the Ghidra/light-stage memory collision entirely, and per-process ceilings re-derived against the actual concurrency factor (`-P 4` for light stages, `-P 2` for Ghidra) rather than tuned in isolation.

---

## 3. CLI Surface

```
revctf scan <file|dir> [--output DIR] [--timeout SECONDS] [--no-flag-scan]
             [--full-hexdump] [--sandbox] [--flag-format REGEX]
             [--ghidra-script PATH] [--light-decompile] [-h]
```

- `<target>` — autodetected as file vs directory (batch mode)
- `--output` — defaults to `./revctf-reports/`
- `--timeout` — defaults to `10` (seconds, applies to `ltrace`)
- `--no-flag-scan` — disables flag-pattern detection
- `--full-hexdump` — dumps the entire file instead of the capped preview (streamed to disk)
- `--sandbox` — routes the `ltrace` step through a network-isolated, resource-bounded Docker container
- `--flag-format REGEX` — adds a custom High-confidence flag pattern (e.g. `--flag-format 'HTB\{.*?\}'`)
- `--ghidra-script PATH` — overrides automatic Ghidra script selection
- `--light-decompile` — substitutes radare2's disassembly output for Ghidra's full decompile; also the report's suggested remedy on a Ghidra OOM

---

## 4. Key Decisions Confirmed (this revision)

1. **RAM target raised to 4GB**, with the XFCE desktop assumption (tighter than headless) used for all resource math, per your confirmation — this is the more conservative of the two real possibilities, so numbers tuned against it hold under a headless install too.
2. **Two-phase batch execution retained and confirmed sound**: light stages (`file`/`strings`/`binwalk`/`hexdump`/`ltrace`/`radare2`) fully complete across the whole batch before Ghidra's phase begins. This is what makes independently increasing each phase's concurrency safe — the two phases never compete for memory with each other.
3. **Light-stage concurrency raised to `-P 4`** (from `-P 3`), since 4GB provides enough headroom to run one more file concurrently without meaningfully eroding safety margin, once `radare2`'s ceiling is re-tuned to match (see #5).
4. **Ghidra phase concurrency raised to `-P 2`** (from strict `-P 1` serialization): two `MAXMEM=1024M`-capped instances total ~2GB, comfortably inside the 4GB budget even under the XFCE assumption (~1.2GB+ slack), roughly halving decompile-phase time on multi-file batches.
5. **radare2 per-process ceiling re-tuned to 640MB** for `-P 4`: sized against the worst-case aggregate (4 concurrent files all in their `radare2` stage simultaneously, Docker daemon resident, XFCE running) rather than picked in isolation — the exact gap the v2 review flagged in the 2GB-era tuning. Full derivation in §8.
6. **Ghidra `MAXMEM` raised to 1024M** (from 768M): P=2 at 1024M each (~2GB total) still leaves comfortable headroom, and the extra 256MB per instance reduces how often `--light-decompile` needs to be the fallback on larger/complex binaries.
7. **Sandbox image build moved into `install.sh`**, which runs during the confirmed network window; `stage_ltrace.sh`'s sandbox path now only checks the image exists and fails with a clear `revctf`-authored error ("sandbox image not found; run install.sh while online") rather than attempting an on-demand build that will fail once offline.
8. **Sandbox container hardened with network isolation**: `--network=none --read-only --user nobody` added alongside the existing `--memory=256m --pids-limit=64 --cap-drop=ALL`. `ltrace` needs no network access to trace a local binary, so this closes an exfiltration/callback vector at no functional cost.
9. **binwalk version check made forward-compatible**: numeric major-version comparison (`≥3`) instead of a literal `"3."` substring match, so a future binwalk 4.x doesn't silently fall through to the wrong parsing branch.
10. **radare2 symbol matching tightened to a word boundary** (`\bmain\b`), preventing `domain_main_init`-style symbols from being mistaken for a real `main` and pointed at by `pdf`.
11. **RAM preflight check added**: `free -m` detects actual system memory and warns (without hard-failing) if it's meaningfully below the tuned 4GB target, since the stated environment figure isn't guaranteed to match every actual deployment.
12. **Ghidra OOM now surfaces `--light-decompile` directly** in the report's failure message, rather than a generic "stage failed" — turns a dead end into an actionable next step.
13. **README states the XFCE baseline assumption explicitly**, and flags `--sandbox` combined with a large batch run as the single tightest resource combination on this hardware (Docker daemon + concurrent light-stage phase overlapping).

---

## 5. Proposed Steps

1. **Scaffold** the repo: `revctf` entry script, `lib/`, `scripts/`, `docker/`, `README.md`, `install.sh`.
2. **Pre-flight check** (`lib/preflight.sh`) — verify all 7 tools (Ghidra via `PATH` → `GHIDRA_HOME` → `/opt/ghidra*` scan); detect Ghidra and binwalk versions; **detect actual system RAM via `free -m` and warn if below ~3800MB**; disk-space check. Docker existence (not build) checked only if `--sandbox` is passed.
3. **`install.sh`** — in addition to symlinking `revctf` onto `PATH`, **builds the sandbox Docker image now**, during the confirmed network window; prints a clear warning (not a hard failure) if the build fails or Docker isn't present, noting offline `--sandbox` use will be unavailable.
4. **Stage 1 — `file`** — capture output, classify target (ELF/PE/Mach-O/other); drives `ltrace` gating.
5. **Stage 2 — `strings`** — streamed directly to disk, no variable buffering.
6. **Stage 3 — `binwalk`** — numeric major-version branch (`≥3` → `--format=text`, else legacy), streamed to disk.
7. **Stage 4 — `hexdump`** — capped preview by default, streamed to disk; `--full-hexdump` streams the complete dump.
8. **Stage 5 — `ltrace`** — `setsid timeout -k 5 10 ltrace -f "$target" </dev/null` on host, followed by a process-group sweep for orphans; `--sandbox` routes through `docker run --network=none --read-only --user nobody --memory=256m --pids-limit=64 --cap-drop=ALL`; skipped with a note for non-ELF targets; fails fast with a clear error if `--sandbox` is passed and the image doesn't exist (i.e. `install.sh` was never run online).
9. **Stage 6 — `radare2`** — `\bmain\b` word-boundary check before falling back to `entry0`; run inside `ulimit -v 640000` (640MB), sized against `-P 4` concurrency (derivation in §8).
10. **Stage 7 — `ghidra` headless** — picks the version-appropriate post-script (or `--ghidra-script` override); runs with `MAXMEM=1024M`, stdout/stderr split; OOM detection in stderr surfaces a `--light-decompile` suggestion in the report; this phase runs at `-P 2` and only *after* all light-stage jobs (steps 4–9) across the whole batch have completed.
11. **Flag scan** (`lib/flagscan.sh`) — tiered regex (known formats + `--flag-format` = High; generic fallback = Low) over all captured output; dedupe.
12. **Report assembly** (`lib/report.sh`) — per-stage blurb + explicit found/failed markers + raw output; "🚩 Possible Flags Found" (High confidence first, ASCII `[FLAG]` fallback) prepended when applicable; Ghidra OOM failures include the `--light-decompile` hint.
13. **Batch/directory mode** — Phase 1: `xargs -P 4` across light stages (4–9) with per-job `mktemp -d` isolation and a `flock`-protected results file; Phase 2: `xargs -P 2` across Ghidra runs (10) for the same file set, strictly after Phase 1 completes; final summary assembled once both phases finish.
14. **README** — apt prerequisites, pinned/tested binwalk version, Docker + one-time network-window note for `--sandbox`, explicit XFCE-baseline statement, swap-file recommendation, note that `--sandbox` + large batch runs together is the tightest resource combination, usage examples covering every flag.
15. **Test pass**:
    - Format/stripped-binary coverage (ELF/PE, stripped confirms `entry0` fallback, symbol false-positive case confirms `\bmain\b` fix)
    - Planted `flag{...}` string; `--flag-format` custom pattern; `--ghidra-script` override
    - Deliberately-hung binary confirming `--timeout` + orphan-sweep leave no leftover processes
    - Missing tool on `PATH`, and a Ghidra install only under `/opt/`
    - `--sandbox` after a proper `install.sh` run (image present, network isolation holds — confirm no egress from inside the container) and `--sandbox` after a *simulated offline-only* setup (confirm the clear "run install.sh while online" error, not an opaque Docker failure)
    - **4 concurrent files simultaneously in their `radare2` stage** — explicit aggregate-memory test, confirming the 640MB×4 ceiling holds under an XFCE-desktop test VM
    - **2 concurrent Ghidra instances** at `MAXMEM=1024M` — confirms Phase 2's `-P 2` fits comfortably
    - Both PyGhidra (11.x+) and Jython (10.x-) paths individually, confirming `MAXMEM=1024M` is sufficient for each runtime's overhead profile
    - Both binwalk generations (legacy and v3+), confirming correct branch selection and forward-compatibility of the numeric check
    - Large firmware-image file confirming streaming I/O doesn't spike memory
    - RAM-preflight warning triggering correctly on a deliberately memory-constrained test VM

---

## 6. Repo Layout

```
revctf/
├── revctf                     # main entry script (bash), chmod +x
├── lib/
│   ├── preflight.sh            # PATH + GHIDRA_HOME + /opt scan + version detection + RAM + disk-space checks
│   ├── stage_file.sh
│   ├── stage_strings.sh        # streams to disk
│   ├── stage_binwalk.sh        # numeric version-branched parsing
│   ├── stage_hexdump.sh        # streams to disk
│   ├── stage_ltrace.sh         # host or --sandbox docker routing (network-isolated); setsid + orphan sweep
│   ├── stage_radare2.sh        # \bmain\b word-boundary + entry0 fallback; 640MB ulimit -v
│   ├── stage_ghidra.sh         # version-based script selection; MAXMEM=1024M; stdout/stderr split; OOM → --light-decompile hint
│   ├── flagscan.sh             # tiered regex + --flag-format support
│   └── report.sh               # stage-failure markers; ASCII fallback header
├── scripts/
│   ├── pyghidra_decompile.py   # Ghidra 11.x+
│   └── jython_decompile.py     # Ghidra 10.x and earlier
├── docker/
│   └── Dockerfile              # minimal image with ltrace + timeout; built by install.sh
├── README.md                   # XFCE baseline note, sandbox network-window note, swap-file rec, tightest-combo warning
└── install.sh                  # symlinks revctf onto PATH; builds sandbox image during the network window
```

---

## 7. What Will Not Change

- No full-pipeline containerization — `--sandbox` isolates only the `ltrace` execution step.
- No TUI/interactive mode.
- No general modular tool selection — all 7 tools always run **except** the narrow, opt-in `--light-decompile` exception for Ghidra specifically.
- No user-configurable concurrency flags — `-P 4` (light) and `-P 2` (Ghidra) are fixed defaults, tuned against the stated 4GB/XFCE environment.

---

## 8. radare2 Ceiling Derivation (640MB)

Worst-case budget for the light-stage phase, XFCE + `-P 4`, Docker daemon resident:

| Line item | Estimate |
|---|---|
| Kali OS baseline (XFCE desktop) | ~800MB (upper end, conservative) |
| Bash orchestrator + `xargs` overhead | ~50MB |
| Docker daemon (resident, worst case) | ~300MB |
| **Available for concurrent light-stage tool processes** | **~2,946MB** |
| 4× `radare2` @ 640MB `ulimit -v` each | 2,560MB |
| **Remaining slack** | **~386MB (~13%)** |

640MB was chosen over 512MB (30% slack, but leaves usable radare2 memory on the table for no added benefit) and over 700MB (only ~5% slack, which the v2 review's own finding shows doesn't survive the additional un-modeled overhead of the other five light-stage tools running concurrently across the three files not currently in their `radare2` stage).

---

## 9. Residual Risks (post-mitigation)

- **`ulimit -v` still bounds virtual memory, not RSS** — tuned conservatively, but worth confirming empirically in the §5 step-15 aggregate-memory test rather than trusting the math alone.
- **Docker daemon overhead is an estimate (~100–300MB)** — actual figure varies by Docker version/config; the 640MB derivation uses the upper end of that range for safety, but is worth spot-checking on the actual target VM.
- **`--sandbox` + large batch runs remains the tightest combination** on this hardware, even with the 4GB increase — flagged explicitly in the README rather than hard-blocked, since it's not actually unsafe, just the least headroom of any supported combination.
- **Ghidra version coverage is not exhaustive** — two scripts cover the two major API generations; unusual installs may still need `--ghidra-script`.
- **Genuinely air-gapped environments** (zero network access, ever) still need the sandbox image pre-built elsewhere and transferred manually — `install.sh`'s build step assumes the stated one-time network window actually occurs.

---

## 10. Verification Plan

Run the full test-pass list in step 15, with particular attention to the items new in this revision: the 4-concurrent-`radare2` aggregate test, the 2-concurrent-Ghidra test, both Ghidra runtime paths at `MAXMEM=1024M`, and the two `--sandbox` scenarios (online install → offline use works; skipped install → offline use fails with the correct clear error).

---

## 11. Approval Gate

Reply **`implement`** to begin scaffolding the repo and building this stage by stage, or specify changes first.
