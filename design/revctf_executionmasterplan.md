# revctf — Execution Masterplan (Planning → Building)

A project-management roadmap for building `revctf` from the completed v5 design. This document does **not** re-open design decisions — it wraps execution structure (milestones, dependencies, definition-of-done gates, verification checkpoints) around the build sequence already established in the technical masterplan.

**Execution model:** Solo, self-paced, quality-first, no deadline. Progress is tracked by **milestone completion and dependencies**, not calendar dates or time estimates. An explicit **MVP checkpoint (M4)** sits partway through: the 7 tools running end-to-end through a basic report, before the advanced layers (adaptivity, sandbox, agency, resilience) go on top.

---

## 1. How to Read This Plan

- **Milestones (M0–M9)** are the unit of progress. Each is a coherent, independently-verifiable chunk.
- **Dependencies** are explicit: a milestone can't start until its listed prerequisites are done. This is what replaces a schedule — you always know what's unblocked and workable next.
- **Definition of Done (DoD)** gates each milestone: objective, checkable conditions. Don't advance past a milestone until its DoD is fully met — this is the single most important discipline for a solo, unpaced build, because there's no external reviewer forcing it.
- **Verification** is the concrete test to run at each gate, drawn from the technical masterplan's test plan.
- **MVP checkpoint** = end of M4. Everything after is additive; the tool is genuinely usable from M4 onward.

---

## 2. Milestone Map (dependency order)

```
M0 Foundation & scaffolding
        │
M1 Preflight & dependency detection
        │
M2 Core stage engine (file → strings → binwalk → hexdump)
        │
M3 Heavy stages (ltrace, radare2, ghidra) + flag scan
        │
M4 ══ MVP CHECKPOINT ══  Basic report, single-file, autonomous
        │
        ├──────────────┬──────────────┐
M5 Adaptive         M6 Sandbox      M7 Batch mode
   RAM tiers +         hardening        (two-phase concurrency)
   isolation          (Docker)
        │              │              │
        └──────────────┴──────────────┘
        │
M8 User agency & interactivity
        │
M9 Resilience, diagnostics & release polish
```

M5, M6, and M7 all depend on M4 but are **independent of each other** — they can be built in any order, or interleaved, whichever you feel like tackling. M8 depends on all three being in place (agency prompts wrap sandbox starts, tier-driven swap, and batch flow). M9 is last because its error-isolation and diagnostics should wrap the finished behavior of everything else.

---

## 3. Milestones in Detail

### M0 — Foundation & Scaffolding
**Depends on:** nothing (start here)
**Tasks:**
- Initialize the repo structure: `revctf` entry script, `lib/`, `scripts/`, `docker/`, `README.md`, `install.sh` (empty stubs where needed).
- Establish the entry script's argument-parsing skeleton and `scan` subcommand dispatch.
- Set up a local test-corpus directory (not committed): a simple crackme ELF, a stripped ELF, a PE sample, a binary with a planted `flag{...}`, and a deliberately-hung binary. Everything downstream is verified against these.
- Version control: first commit, a `.gitignore` covering reports/temp/test-corpus.

**Definition of Done:**
- `revctf scan <anything>` runs and reaches a "not yet implemented" stub without a shell error.
- Test corpus assembled and documented in a local notes file.

**Verification:** `revctf -h` prints usage; `revctf scan dummy` exits cleanly.

---

### M1 — Preflight & Dependency Detection
**Depends on:** M0
**Tasks:**
- `lib/preflight.sh`: verify `file`, `strings`, `binwalk`, `hexdump`, `ltrace`, `radare2` on `PATH`.
- Ghidra discovery: `PATH` → `GHIDRA_HOME` → `/opt/ghidra*/support/analyzeHeadless` scan.
- Version detection for Ghidra (feeds M3's script selection) and binwalk (numeric major-version check, feeds M2's binwalk parsing).
- Disk-space check at startup.
- Clear, actionable "missing tool → apt install X" messaging, exit 1 on hard failure.

**Definition of Done:**
- Running on a box with a tool removed from `PATH` produces the correct missing-tool message and exit code.
- Ghidra is found whether it's on `PATH` or only under `/opt/`.
- Detected versions are correctly captured for downstream use.

**Verification:** Preflight test scenarios — missing tool, `/opt`-only Ghidra, both binwalk generations if available.

---

### M2 — Core Stage Engine (light static stages)
**Depends on:** M1
**Tasks:**
- Establish the **per-stage function pattern** every stage will follow (input, capture-to-disk, report-fragment output) — this pattern is reused by every later stage, so get it right here.
- `stage_file.sh` — classify target (ELF/PE/Mach-O/other); this classification is a dependency for M3's ltrace gating.
- `stage_strings.sh` — `strings -a -n 6`, streamed to disk.
- `stage_binwalk.sh` — version-branched parsing (from M1's detection), streamed to disk.
- `stage_hexdump.sh` — capped preview default, `--full-hexdump` full dump, streamed.
- Streaming-to-disk discipline established here (no variable buffering) — also a reused pattern.

**Definition of Done:**
- All four stages run against every test-corpus file and produce captured output on disk.
- `file` correctly classifies each corpus file's type.
- `--full-hexdump` vs. default preview behave differently and correctly.
- Large-file streaming confirmed not to spike memory (test with a large firmware-ish file).

**Verification:** Run the four stages across the corpus; confirm output files + `file` classification + streaming behavior.

---

### M3 — Heavy Stages + Flag Scan
**Depends on:** M2 (needs the stage pattern + `file` classification)
**Tasks:**
- `stage_ltrace.sh` — host-mode `setsid timeout -k 5 10 ltrace -f … </dev/null` + orphan process-group sweep; **gated on M2's ELF classification** (skip-with-note for non-ELF).
- `stage_radare2.sh` — `\bmain\b` word-boundary check → `entry0` fallback; the standard command set.
- `stage_ghidra.sh` — headless `analyzeHeadless` with throwaway project + `-deleteProject`; version-appropriate post-script (`pyghidra_decompile.py` / `jython_decompile.py`) selected via M1's detection; `--ghidra-script` override; stdout/stderr split.
- `scripts/pyghidra_decompile.py` and `scripts/jython_decompile.py` — the two decompile post-scripts.
- `lib/flagscan.sh` — tiered regex (known formats + `--flag-format` = High; generic fallback = Low), dedupe.

**Definition of Done:**
- `ltrace` runs on ELF, correctly skips non-ELF, and the timeout + orphan sweep leave no leftover processes (test against the hung binary).
- `radare2` produces a disassembly section on both a symbol'd and a stripped binary (confirms `entry0` fallback).
- Ghidra headless produces decompiled pseudo-C + function list on at least one corpus binary, on whichever Ghidra generation is installed.
- Flag scan finds the planted `flag{...}` and tags it High confidence.

**Verification:** Full heavy-stage run across corpus; hung-binary timeout test; stripped-binary radare2 test; planted-flag detection test.

---

### M4 — ═══ MVP CHECKPOINT ═══ Basic Report, Single-File, Autonomous
**Depends on:** M3
**Tasks:**
- `lib/report.sh` — per-stage beginner-friendly blurb + raw output; "Possible Flags Found" section (High-confidence first, ASCII `[FLAG]` fallback); explicit "stage found nothing" / "stage failed" markers.
- Wire all 7 stages + flag scan + report assembly into a single autonomous single-file pipeline.
- Basic `trap` cleanup for temp dirs/Ghidra projects (full SIGINT abort semantics come in M9; this is the minimal version).
- Report file naming + stdout mirroring.

**Definition of Done — this is the MVP gate:**
- `revctf scan <single-file>` runs all 7 tools autonomously and produces a complete, readable plain-text report with the flag section at top.
- Works end-to-end on every corpus file without manual intervention.
- **The tool is genuinely useful from this point.** Everything after M4 improves robustness, safety, scale, and control — but a real RE-CTF challenge can be analyzed with what exists here.

**Verification:** End-to-end single-file run on all 5 corpus files; visually inspect each report for completeness and correct flag surfacing.

**→ Recommended: tag this commit `v0.1-mvp`. It's your fallback-good-state for everything that follows.**

---

### M5 — Adaptive RAM Tiers + Resource Isolation
**Depends on:** M4
**Tasks:**
- `lib/tier.sh` — `free -m` detection → Tier A/B/C resolution; `--jobs-light`/`--jobs-ghidra`/`--maxmem-ghidra` overrides.
- Resource isolation: `systemd-run --scope -p MemoryMax=…` with `ulimit -v` fallback + report notice when systemd-run is unusable.
- Ghidra `MAXMEM` (tier-specific) + `-XX:MaxRAMPercentage=25`.
- Tier C behavior: auto `--light-decompile`, `--force-full-decompile` override.
- `lib/swap.sh` — auto-create 1–2GB swap on low tier + no active swap (`--no-auto-swap` opt-out). *(Prompt integration deferred to M8.)*
- `lib/watchdog.sh` — global RSS monitor, kills job tree at 90% RAM.
- `--light-decompile` / `--force-full-decompile` flags.

**Definition of Done:**
- Correct tier selected on a ≥3.8GB box and on a forced-2GB cgroup/VM.
- `systemd-run` path works where available; `ulimit -v` fallback engages cleanly with the notice where not.
- Watchdog fires on an artificially memory-hungry binary and does **not** false-fire during a normal Tier A run.
- Auto-swap engages on a low-RAM box with no swap.

**Verification:** Forced-2GB Tier C end-to-end; RSS measurement of isolation bounds; watchdog trigger + false-positive tests.

---

### M6 — Sandbox Hardening (Docker)
**Depends on:** M4 (independent of M5, M7)
**Tasks:**
- `docker/Dockerfile` — minimal image with `ltrace` + `timeout`.
- `install.sh` — build the image during the setup network window; symlink `revctf` onto `PATH`.
- `stage_ltrace.sh` sandbox path — `docker run --network=none --read-only --user nobody --memory=256m --pids-limit=64 --cap-drop=ALL`; existence check with fail-fast "run install.sh while online" error if image absent. *(Start-confirmation prompt deferred to M8.)*
- Docker daemon footprint logging when `--sandbox` is used.
- `--sandbox` flag.

**Definition of Done:**
- After a proper `install.sh`, `--sandbox` runs ltrace in the container with confirmed no network egress.
- After a simulated offline-only setup, `--sandbox` fails with the correct clear error, not an opaque Docker failure.
- Container resource bounds hold against a resource-abuse test binary.

**Verification:** Both `--sandbox` scenarios (image present / absent); network-isolation confirmation; resource-bound test.

---

### M7 — Batch Mode (two-phase concurrency)
**Depends on:** M4 and M5 (needs tier-driven concurrency values from M5)
**Tasks:**
- Directory detection + per-file loop.
- **Phase 1**: light stages at the tier's `-P N` via `xargs`, per-job `mktemp -d` isolation, `flock`-protected results file.
- **Phase 2**: Ghidra at the tier's concurrency, strictly after Phase 1 completes across the whole batch.
- Per-file failure isolation; final run summary (files scanned / flags / stages failed), merged only after both phases finish.

**Definition of Done:**
- A directory of mixed corpus files processes correctly with no interleaved/corrupted reports.
- Light-stage concurrency and Ghidra's separate phase both run at the correct tier-driven levels.
- One deliberately-failing file doesn't stop the batch; summary reflects it.

**Verification:** Batch run over the corpus; concurrent-radare2 aggregate-memory test; concurrent-Ghidra test; per-file-failure isolation test.

---

### M8 — User Agency & Interactivity
**Depends on:** M5, M6, M7 (wraps swap creation, sandbox start, OOM retry, and batch flow)
**Tasks:**
- `lib/prompt.sh` — TTY detection, prompt display, per-run answer memoization.
- Wire targeted confirmations into: swap creation (M5), sandbox start (M6), Ghidra OOM auto-retry.
- `--interactive/-i` guided mode — per-stage Continue/Skip-stage/Skip-file/Abort loop.
- `--yes/-y` — force-suppress prompts either direction; mutual-exclusion warning with `--interactive`.
- `--skip-ltrace` / `--skip-ghidra` guards.

**Definition of Done:**
- Prompts appear on a TTY, not when piped; `-y` overrides both ways.
- `--interactive` walkthrough options all behave correctly across a small batch.
- Prompt-answer memoization confirmed (same prompt type not re-asked within a run).
- `--skip-*` flags work individually and together, including the `--sandbox` + `--skip-ltrace` no-op notice.

**Verification:** TTY-vs-piped prompt test; `--interactive` option-by-option test; memoization test; skip-flag tests.

---

### M9 — Resilience, Diagnostics & Release Polish
**Depends on:** M8 (wraps the completed behavior of everything)
**Tasks:**
- `lib/errorlog.sh` — structured diagnostic block (command, exit code/signal, stderr tail, file, stage, timestamp); persistent `~/.revctf/error.log` (`600`, 5MB rotation).
- Stage-level isolate-and-continue: each stage in its own `ERR`-trapped boundary; no top-level `set -e`.
- `lib/spinner.sh` — TTY spinner / redirected-output heartbeat for long stages.
- `--verbose` / `--debug` flags.
- Full SIGINT abort semantics + complete `trap` cleanup.
- Report permission hardening (`700`/`600`).
- `--summary-only` / `--dry-run`.
- README completion: tier table, agency model, diagnostics, swap behavior, sandbox notes, every-flag usage examples.

**Definition of Done:**
- An injected mid-stage crash is caught, fully diagnosed in report + error log, and the pipeline continues.
- Ctrl+C aborts cleanly with cleanup; no orphaned temp dirs or Ghidra projects.
- Spinner/heartbeat behave correctly by output mode; `--verbose`/`--debug` produce correct content in correct destinations.
- README covers every flag and behavior.

**Verification:** Full expanded test pass from the technical masterplan §7/§11 — crash-injection, interrupt, diagnostics, error-log rotation, `--dry-run` accuracy, `--summary-only` ordering.

**→ This is release-ready. Tag `v1.0`.**

---

## 4. Cross-Cutting Practices (apply throughout, every milestone)

- **Commit at every green DoD gate.** Solo + unpaced means your commit history is your only progress record and your only rollback safety. Tag M4 (`v0.1-mvp`) and M9 (`v1.0`) specifically.
- **Keep an `implementation-notes.md`** in the repo: log deviations from the design, open questions, and any conservative choices made when a small unknown surfaced mid-build. This is the memory that a solo unpaced project loses between sessions otherwise.
- **Test against the corpus at every milestone**, not just at the end. Each DoD names its verification — actually run it before advancing.
- **The stage-function pattern (M2) and streaming discipline (M2) are load-bearing** — every later stage reuses them. Time spent making them clean in M2 pays back across M3–M7.
- **Don't let advanced milestones leak backward.** If a resilience idea (M9) or an agency idea (M8) occurs to you during M3, note it in `implementation-notes.md` and keep going — don't build it early, or you lose the clean MVP gate at M4.

---

## 5. Resources & Prerequisites

- **Environment:** a Kali VM matching the design's assumptions (XFCE, tiered RAM), plus — for honest testing — the ability to force a low-RAM (~2GB) cgroup or VM for the Tier C / M5 verification.
- **Tools installed:** `file`, `strings`, `binwalk`, `hexdump`, `ltrace`, `radare2`, Ghidra (note which generation, for M3), Docker (for M6), `systemd` (for M5's preferred isolation path).
- **Network:** the one-time setup window for M6's Docker image build.
- **Test corpus (M0):** the 5 binaries listed, kept out of version control.
- **Skills:** Bash (core), a little Python (the two Ghidra post-scripts in M3), Docker basics (M6), and cgroup/systemd familiarity (M5) — the milestones are ordered so the Bash-heavy core comes first and the more specialized bits (Python/Docker/cgroups) come in the middle-to-late milestones.

---

## 6. Milestone Gate Checklist (quick reference)

| Milestone | Gate condition (short form) | Suggested tag |
|---|---|---|
| M0 | Scaffold runs to a stub; corpus assembled | — |
| M1 | Preflight catches missing tools; Ghidra found via all paths | — |
| M2 | 4 light stages produce output; `file` classifies correctly; streaming holds | — |
| M3 | Heavy stages run; ltrace skips non-ELF + no orphans; flag detected | — |
| **M4** | **All 7 tools → complete report, single-file, autonomous** | **`v0.1-mvp`** |
| M5 | Tiers select correctly; isolation + watchdog + swap work | — |
| M6 | Both `--sandbox` scenarios correct; isolation holds | — |
| M7 | Batch two-phase concurrency; failure isolation; clean summary | — |
| M8 | Prompts TTY-gated; interactive + skip flags + memoization work | — |
| M9 | Crash caught + continues; clean abort; full diagnostics; README done | **`v1.0`** |

---

## 7. Approval Gate

This is the execution roadmap. Reply **`implement`** to begin at **M0 — Foundation & Scaffolding**, or tell me what to adjust about the milestone structure, sequencing, or gates first.
