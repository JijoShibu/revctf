# revctf — Masterplan v4 (Adaptive RAM Tiers + RSS-Accurate Isolation)

A Bash CLI for Kali Linux that runs `file`, `strings`, `binwalk`, `hexdump`, `ltrace`, `radare2`, and `ghidra` (headless) against a Reverse Engineering CTF challenge file — or a directory of them — and produces a beginner-friendly plain-text report with auto-detected flag candidates surfaced at the top.

**Target environment:** Kali VM, XFCE desktop, **RAM auto-detected at runtime and mapped to one of three tiers** (previously a fixed 4GB profile). Brief network access available during setup/install.

This revision responds to a deep technical review of masterplan v3 that identified the fixed 4GB profile as brittle outside its exact target, `ulimit -v` as bounding virtual memory rather than the real-world constraint (RSS), and several UX/error-handling gaps. It replaces the single fixed profile with three auto-detected tiers, upgrades resource isolation, and adds automatic (not just suggested) degradation under memory pressure.

---

## 1. Decision Summary

| Area | Decision |
|---|---|
| Interface | Pure CLI, flags/args |
| Orchestration | Fully autonomous, fixed 7-tool pipeline per file, no pauses |
| Dynamic analysis safety | Host by default; opt-in `--sandbox` (Docker, network-isolated) for `ltrace`; available at every RAM tier |
| File scope | ELF + PE + others (Mach-O, firmware, unknown) |
| Ghidra depth | Headless scripted decompile by default; auto-falls back to `--light-decompile` under memory pressure |
| Report format | Plain text, stdout + saved file; `--summary-only` for a condensed view |
| Flag detection | On by default; tiered confidence + custom `--flag-format` |
| Language | Bash, zero core dependencies (Docker only if `--sandbox`; `systemd-run` preferred, `ulimit -v` fallback) |
| Scope (files) | Single file **or** batch/directory |
| Missing tools | Pre-flight check (`PATH` + `GHIDRA_HOME` + `/opt/ghidra*` scan) |
| **RAM handling** | **Auto-detected via `free -m`, mapped to Tier A/B/C (see §3); overridable via `--jobs-light`, `--jobs-ghidra`, `--maxmem-ghidra`** |
| **Resource isolation** | **`systemd-run --scope -p MemoryMax=...` (bounds real RSS) when available; falls back to `ulimit -v` with a report notice if not** |
| **Ghidra JVM control** | **`MAXMEM` (tier-specific) + `-XX:MaxRAMPercentage=25` as a second, percentage-based bound** |
| **Global watchdog** | **Background monitor kills the whole job tree if total RSS exceeds 90% of detected RAM — last-resort net beyond per-tool bounds** |
| **Ghidra OOM handling** | **Automatic retry with `--light-decompile` for that file, noted in the report — not just a suggestion** |
| **Swap** | **Auto-creates a 1–2GB swap file when none exists and RAM is low (`--no-auto-swap` to opt out)** |
| **New CLI flags** | **`--summary-only`, `--dry-run`, `--jobs-light`, `--jobs-ghidra`, `--maxmem-ghidra`, `--no-auto-swap`, `--force-full-decompile`** |
| Batch execution model | Two phases, never interleaved: light stages complete fully, then Ghidra runs |
| binwalk version drift | Numeric major-version check; output validated, falls back to raw capture on parse failure |
| radare2 stripped/symbol handling | `\bmain\b` word-boundary match before `entry0` fallback |
| Report hygiene | Explicit `700`/`600` permissions on output dir/files, not umask-inherited |
| Cleanup | `trap` handlers on SIGINT/SIGTERM ensure temp dirs and Ghidra projects are removed even on interrupted runs |

---

## 2. Goal

Build `revctf` as a scriptable, autonomous RE-CTF pipeline that degrades gracefully across a *range* of hardware — from a comfortable 4GB+ XFCE VM down to a genuinely constrained ~2GB one — by detecting its environment and adjusting concurrency, memory ceilings, and (when necessary) which analysis it performs, rather than assuming one fixed profile and merely warning when reality doesn't match it.

---

## 3. RAM Tiers

Detected via `free -m` at pre-flight (`total` field), re-evaluated once per run, not per file.

| Tier | RAM range | Light-stage concurrency | Light `radare2` ceiling | Ghidra concurrency | Ghidra `MAXMEM` | Decompile default |
|---|---|---|---|---|---|---|
| **A** | ≥ 3.8GB | `-P 4` | 640MB | `-P 2` | 1024M | Full Ghidra decompile |
| **B** | 2.5GB – 3.8GB | `-P 2` | 450MB | `-P 1` | 768M | Full Ghidra decompile |
| **C** | < 2.5GB | `-P 1` (serial) | 400MB | `-P 1`, only if forced | 512M | **`--light-decompile` (auto)** |

All three tiers also carry `-XX:MaxRAMPercentage=25` alongside `MAXMEM` for Ghidra, and use `systemd-run --scope -p MemoryMax=<ceiling>` for every bounded process when available (see §4.3).

**Tier C behavior in detail:** Ghidra is skipped by default and replaced with a `radare2`-only disassembly pass, avoiding the JVM's overhead entirely on the tightest hardware. `--force-full-decompile` overrides this if a user on a low-RAM box specifically wants full decompilation and accepts the risk — it still runs at `-P 1` with `MAXMEM=512M`.

**Derivation basis (Tier A, carried over from v3, unchanged):** `4096MB − 800MB (XFCE) − 50MB (bash) − 300MB (Docker, worst case) ≈ 2946MB` available; `4 × 640MB = 2560MB`, ~386MB slack. Tiers B and C use the same OS/bash/Docker overhead assumptions at their respective lower RAM bounds, sized with wider proportional margins since less is being asked of the hardware.

---

## 4. Key Decisions Confirmed (this revision)

1. **Adaptive tiers replace the single fixed profile.** The RAM pre-flight check (already present in v3 to *warn*) now actively selects a tier and configures concurrency/ceilings accordingly, rather than only flagging a mismatch against a hardcoded assumption.
2. **Power-user overrides added**: `--jobs-light N`, `--jobs-ghidra N`, `--maxmem-ghidra M` let an advanced user override the auto-selected tier's values individually, without having to abandon adaptive detection entirely.
3. **Resource isolation upgraded, with fallback.** `systemd-run --scope -p MemoryMax=<ceiling>` bounds actual RSS (closing the exact gap flagged twice now — `ulimit -v` only bounds virtual address space). Pre-flight tests whether `systemd-run` is usable (systemd present, user session active, cgroup delegation available); if not, every stage falls back to `ulimit -v` and the report includes a one-line notice that memory bounding is best-effort (VSZ-only) on this system, rather than failing outright.
4. **Ghidra gets a second, independent bound**: `-XX:MaxRAMPercentage=25` alongside the tier's `MAXMEM`, passed via Ghidra's JVM launch options. `25%` was chosen because it reproduces the existing `MAXMEM` values almost exactly at each tier's lower RAM bound (1024M/4096M, 768M/3072M ≈ both ~25%), so the two controls agree rather than fight each other.
5. **Global watchdog added** as a last-resort safety net: a lightweight background process (started alongside the batch, killed when it completes) polls total RSS of revctf's process group every 2 seconds; if it exceeds 90% of detected total RAM, it terminates the batch (`SIGTERM` then `SIGKILL` after a grace period), logs which stage/file was active, and marks the run as aborted in the summary. This exists specifically for the case where per-tool bounds are individually respected but their *sum*, plus un-modeled OS/Docker overhead, still exceeds reality.
6. **Ghidra OOM now self-heals per file**: on detecting an OOM in Ghidra's stderr, revctf automatically re-runs that specific file with `--light-decompile` rather than only suggesting it — the report notes the fallback occurred and why, but no manual re-run is required. `--force-full-decompile` (see Tier C) is the explicit way to disable this auto-fallback if a user wants a hard failure instead.
7. **`--sandbox` stays available at every tier** (not disabled on low RAM) per your call — the README explicitly documents it as the least-headroom combination on constrained hardware, so the trade-off is visible rather than silently blocked.
8. **Swap handling upgraded to auto-create.** When RAM is low (Tier B/C) and `swapon --show` reports nothing active, revctf creates a 1–2GB swap file (sized against available disk space), sets `600` permissions, runs `mkswap` + `swapon`, and appends a persistent entry to `/etc/fstab` — printing each step as it happens rather than doing this silently. Requires root/passwordless sudo; if unavailable, falls back to the v3 behavior of a printed recommendation only. `--no-auto-swap` opts out entirely.
9. **`--summary-only`** reorders the report to lead with the "🚩 Possible Flags Found" section and a condensed one-line-per-stage status line, pushing full raw tool output below a clear separator — addresses the "useful signal buried in a long report" usability risk directly.
10. **`--dry-run`** runs only the pre-flight and tier-selection logic, then prints the resolved tier, concurrency, memory ceilings, and an estimated peak-memory figure for the batch about to run, without executing any of the 7 tools — lets a user sanity-check a large batch before committing to it.

---

## 5. Fixes Folded In Directly (no trade-off)

- **`trap` cleanup**: SIGINT/SIGTERM handlers ensure temp directories and any in-progress Ghidra project are removed even when a run is interrupted mid-scan.
- **binwalk output validation**: after each run, output is checked for non-empty/parseable content; on failure (e.g. a future flag rename breaks the parser), the stage falls back to raw capture, marked "parse validation failed — raw output below" instead of silently reporting nothing.
- **Extended disk-space checks**: beyond the existing startup check, a check now also runs immediately before `--full-hexdump` and before each Ghidra project is created, since these are the two steps most likely to consume large amounts of disk mid-run.
- **Docker daemon footprint logging**: when `--sandbox` is used, revctf logs the daemon's actual measured memory usage at that point in time, giving visibility into how the real number compares to the ~300MB worst-case estimate used in the tier derivations.
- **Report permission hardening**: output directory created `700`, report files written `600`, rather than inheriting the invoking user's umask — reports can contain sensitive detail about the analyzed binary.
- **Test plan expanded** (folded into §7 below): forced 2GB cgroup/VM run to validate Tier C end-to-end, real RSS measurement (not just virtual) of concurrent `radare2`/Ghidra at each tier's concurrency level, and pathological cases (500MB+ firmware, packed binaries, an intentionally infinite-loop `ltrace` target, and a binary that forces Ghidra's slowest full-analysis path).

---

## 6. CLI Surface

```
revctf scan <file|dir> [--output DIR] [--timeout SECONDS] [--no-flag-scan]
             [--full-hexdump] [--sandbox] [--flag-format REGEX]
             [--ghidra-script PATH] [--light-decompile] [--force-full-decompile]
             [--jobs-light N] [--jobs-ghidra N] [--maxmem-ghidra M]
             [--no-auto-swap] [--summary-only] [--dry-run] [-h]
```

New in this revision: `--force-full-decompile`, `--jobs-light`, `--jobs-ghidra`, `--maxmem-ghidra`, `--no-auto-swap`, `--summary-only`, `--dry-run`. All prior flags (`--output`, `--timeout`, `--no-flag-scan`, `--full-hexdump`, `--sandbox`, `--flag-format`, `--ghidra-script`, `--light-decompile`) are unchanged.

---

## 7. Proposed Steps

1. **Scaffold** the repo: `revctf` entry script, `lib/`, `scripts/`, `docker/`, `README.md`, `install.sh`.
2. **Pre-flight check** (`lib/preflight.sh`) — verify all 7 tools; detect Ghidra/binwalk versions; **detect total RAM via `free -m` and resolve the tier (A/B/C)**, applying any `--jobs-light`/`--jobs-ghidra`/`--maxmem-ghidra` overrides on top; **test `systemd-run` usability**, falling back to `ulimit -v` with a report notice if unavailable; disk-space check; **swap check** — if low tier + no active swap + writable root access, auto-create (unless `--no-auto-swap`).
3. **`install.sh`** — symlinks `revctf` onto `PATH`; builds the sandbox Docker image during the confirmed network window.
4. **`--dry-run` short-circuit** — if set, print the resolved tier, concurrency, ceilings, and an estimated peak-memory figure, then exit before touching any target file.
5. **Stage 1 — `file`** — classify target (ELF/PE/Mach-O/other); drives `ltrace` gating.
6. **Stage 2 — `strings`** — streamed to disk.
7. **Stage 3 — `binwalk`** — version-branched, output-validated with raw-capture fallback.
8. **Stage 4 — `hexdump`** — capped preview by default, streamed; disk-space check before `--full-hexdump`.
9. **Stage 5 — `ltrace`** — `setsid timeout -k 5 10 ltrace -f "$target" </dev/null` + orphan sweep on host; network-isolated, resource-bounded Docker container under `--sandbox`; skipped for non-ELF.
10. **Stage 6 — `radare2`** — `\bmain\b` word-boundary check before `entry0` fallback; wrapped in `systemd-run --scope -p MemoryMax=<tier ceiling>` (or `ulimit -v` fallback).
11. **Stage 7 — `ghidra` headless** — tier-appropriate `MAXMEM` + `-XX:MaxRAMPercentage=25`; version-appropriate post-script or `--ghidra-script` override; **on OOM in stderr, automatically retries that file with `--light-decompile`** and logs the fallback; Tier C skips this stage by default entirely unless `--force-full-decompile` is set; disk-space check before project creation.
12. **Global watchdog** — started when the batch begins, polls total job-tree RSS every 2s, kills the run and logs the abort if it exceeds 90% of detected RAM; stopped cleanly when the batch finishes.
13. **Flag scan** (`lib/flagscan.sh`) — tiered regex (known formats + `--flag-format` = High; generic fallback = Low); dedupe.
14. **Report assembly** (`lib/report.sh`) — per-stage blurb + found/failed markers + raw output; flags section prepended when applicable; `--summary-only` reorders to lead with flags + condensed status lines; `700`/`600` permissions applied.
15. **Batch/directory mode** — Phase 1 light stages at the tier's concurrency with per-job `mktemp -d` + `flock` results file; Phase 2 Ghidra at the tier's concurrency, strictly after Phase 1 completes; final summary once both phases finish.
16. **README** — apt prerequisites, pinned binwalk version, `--sandbox` network-window + tightest-combination note, XFCE-baseline statement, tier table, swap-file behavior (auto-create + opt-out), usage examples for every flag.
17. **Test pass** (expanded — see §5 and prior revisions' items, plus):
    - **Tier C end-to-end on a forced 2GB cgroup/VM**, confirming serial execution, auto `--light-decompile`, and auto-swap creation all engage correctly
    - Real RSS measurement of concurrent `radare2` at each tier's `-P` level and ceiling, and of concurrent Ghidra at each tier's level and `MAXMEM`
    - `systemd-run` present vs. absent, confirming the `ulimit -v` fallback engages cleanly with the correct report notice
    - Watchdog triggering correctly on an artificially memory-hungry test binary, and *not* triggering falsely during normal Tier A operation
    - Ghidra OOM auto-retry: confirm the fallback fires, the file still gets a usable (radare2-based) report section, and `--force-full-decompile` correctly disables the auto-fallback when set
    - `--dry-run` output accuracy against actually-observed peak memory in a real run
    - `--summary-only` output ordering and content
    - 500MB+ firmware image, packed binary, infinite-loop `ltrace` target, and a Ghidra-slow-path binary

---

## 8. Repo Layout

```
revctf/
├── revctf                     # main entry script (bash), chmod +x
├── lib/
│   ├── preflight.sh            # tools + versions + RAM tier + systemd-run test + disk + swap
│   ├── tier.sh                 # RAM-tier resolution + override handling
│   ├── watchdog.sh             # global RSS monitor, kills job tree on breach
│   ├── swap.sh                 # auto-swap creation logic
│   ├── stage_file.sh
│   ├── stage_strings.sh
│   ├── stage_binwalk.sh        # numeric version branch + output validation
│   ├── stage_hexdump.sh
│   ├── stage_ltrace.sh         # host or --sandbox docker routing; setsid + orphan sweep
│   ├── stage_radare2.sh        # \bmain\b + entry0 fallback; systemd-run/ulimit bound
│   ├── stage_ghidra.sh         # tier MAXMEM + MaxRAMPercentage; OOM auto-retry; Tier C skip logic
│   ├── flagscan.sh             # tiered regex + --flag-format support
│   └── report.sh               # stage markers; --summary-only reordering; permission hardening
├── scripts/
│   ├── pyghidra_decompile.py   # Ghidra 11.x+
│   └── jython_decompile.py     # Ghidra 10.x and earlier
├── docker/
│   └── Dockerfile              # minimal image with ltrace + timeout; built by install.sh
├── README.md
└── install.sh
```

---

## 9. What Will Not Change

- No full-pipeline containerization — `--sandbox` isolates only the `ltrace` execution step.
- No TUI/interactive mode.
- No general modular tool selection — all 7 tools always run, with the tier-driven Ghidra exception (auto `--light-decompile` on Tier C, or on any tier after an OOM) as the only conditional skip.
- No change to the two-phase batch model (light stages complete fully before Ghidra begins) — this remains the core correctness guarantee that makes independent per-phase concurrency safe.

---

## 10. Residual Risks (post-mitigation)

- **`systemd-run` availability isn't universal** — minimal Kali installs, containers-within-containers, or restricted cgroup delegation can all make it unusable; the `ulimit -v` fallback closes the functional gap but not the accuracy gap the fallback itself has.
- **The watchdog's 90% threshold is a heuristic**, not a guarantee — a sufficiently fast memory spike between 2-second polls could still cause a brief OOM before the watchdog reacts. It's a backstop, not a substitute for correctly-sized per-tool ceilings.
- **Auto-swap creation touches system state** (disk, `/etc/fstab`) — while opt-out-able and transparent about each step, this is a meaningfully different risk profile than v3's read-only recommendation, worth being comfortable with before first real-world use.
- **Tier boundaries (3.8GB / 2.5GB) are estimates**, not empirically validated — the step-17 test pass is what actually confirms them; expect possible minor adjustment after real hardware testing.
- **`--force-full-decompile` on Tier C is an explicit risk override** — a user can still choose to run Ghidra on genuinely constrained hardware; the auto-fallback protects the default path, not every possible invocation.

---

## 11. Approval Gate

Reply **`implement`** to begin scaffolding the repo and building this stage by stage, or specify changes first.
