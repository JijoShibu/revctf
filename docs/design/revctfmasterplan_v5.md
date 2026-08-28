# revctf — Masterplan v5 (User Agency + Crash Resilience)

A Bash CLI for Kali Linux that runs `file`, `strings`, `binwalk`, `hexdump`, `ltrace`, `radare2`, and `ghidra` (headless) against a Reverse Engineering CTF challenge file — or a directory of them — and produces a beginner-friendly plain-text report with auto-detected flag candidates surfaced at the top.

**Target environment:** Kali VM, XFCE desktop, RAM auto-detected and mapped to one of three tiers (v4).

This revision adds user agency and intervention points on top of v4's adaptive-tier design: targeted confirmations before consequential actions, an optional fully-guided mode, partial tool-skipping, and — separately — a crash-resilience pass ensuring every exception produces detailed diagnostics, the pipeline stays responsive during long stages, and nothing but an explicit abort or the safety watchdog ever stops a run outright.

---

## 1. Decision Summary

| Area | Decision |
|---|---|
| Interface | Pure CLI, flags/args; default execution stays fully autonomous |
| **User agency** | **Targeted confirmation prompts for risky actions, PLUS an optional full guided `--interactive` mode** |
| **Prompt behavior** | **TTY auto-detected by default (prompts only when a human is watching); `--yes/-y` forces suppression in either direction; an answer is remembered for the rest of that run** |
| **Tool selection** | **`--skip-ltrace` and `--skip-ghidra` allow skipping those two specific stages; the other 5 stay mandatory** |
| Dynamic analysis safety | Host by default; opt-in `--sandbox` (Docker, network-isolated) for `ltrace`; no-op if `--skip-ltrace` is also set (with a notice) |
| Ghidra depth | Full decompile by default; auto-falls back to `--light-decompile` under memory pressure or Tier C; `--skip-ghidra` forces the same fallback by explicit user choice |
| RAM handling | Auto-detected 3-tier system (v4), overridable via `--jobs-light`/`--jobs-ghidra`/`--maxmem-ghidra` |
| Resource isolation | `systemd-run --scope -p MemoryMax` preferred, `ulimit -v` fallback; global watchdog as last resort |
| **Stage-level error handling** | **Isolate-and-continue: any stage failure is captured with full diagnostics and the pipeline moves on — nothing but the watchdog or an explicit abort stops a whole run** |
| **Diagnostics** | **`--verbose` (human-readable trace) and `--debug` (full command-level trace to a log file); every exception also appended to a persistent `~/.revctf/error.log`** |
| **Responsiveness** | **Spinner + elapsed time on stderr when attached to a TTY; periodic heartbeat lines when output is redirected/logged, for any stage running more than a few seconds** |
| **Interrupt handling** | **Any Ctrl+C aborts the whole run immediately (standard convention); existing `trap`-based cleanup still runs** |
| **Watchdog exception** | **The global RSS watchdog's kill action is never prompted — it's a safety-critical automatic response, not a candidate for user confirmation** |
| Swap | Auto-creates 1–2GB swap when none exists and RAM is low; now also passes through the confirmation-prompt system |
| New CLI flags (this revision) | `--interactive/-i`, `--yes/-y`, `--skip-ltrace`, `--skip-ghidra`, `--verbose`, `--debug` |

---

## 2. Goal

Extend `revctf` so that its default autonomous, scriptable behavior is preserved for CI/batch use, while a human running it interactively gets real agency — visibility into and control over consequential actions, the option for a fully guided walkthrough, and the ability to skip the two heaviest/riskiest stages — and so that no single unexpected failure, anywhere in the pipeline, ever produces a silent crash or an unreadable stack dump; every exception is caught, explained in detail, logged, and the tool keeps going.

---

## 3. User Agency & Interactivity

### 3.1 Targeted confirmation prompts
Shown before each of the following, **only when a TTY is detected** (or always-shown/always-suppressed if `-y`/`--yes` is explicitly passed):

| Action | Prompt (paraphrased) | Default if suppressed (`-y` or non-TTY) |
|---|---|---|
| Auto-swap creation | "No swap detected and RAM is low — create a 1–2GB swap file now? [Y/n]" | Yes (proceed, matching v4's auto-create design) |
| `--sandbox` container start | "This will build/start a Docker container for ltrace — continue? [Y/n]" | Yes |
| Ghidra OOM auto-retry | "Ghidra ran out of memory on `<file>` — retry with --light-decompile? [Y/n]" | Yes (matches v4's auto-fallback default) |

Each prompt's answer is **remembered for the rest of that run** — the first swap-creation prompt (say) covers every subsequent file in a batch that would trigger the same situation; it is not re-asked per file.

**Explicitly excluded from prompting**: the global RSS watchdog's kill action. It exists to react at machine speed to imminent memory exhaustion; a prompt there would mean the terminal sits waiting for input while memory keeps climbing — exactly the crash scenario the watchdog exists to prevent. This is a deliberate, documented exception, not an oversight.

### 3.2 `--interactive` / `-i` — full guided mode
An opt-in mode, orthogonal to the default. When set, revctf pauses **before each of the 7 stages, per file**, and presents: `[C]ontinue / [S]kip this stage / [K]ip this file / [A]bort run`. This is where a user gets fine-grained control beyond the targeted prompts in §3.1 — e.g. skipping `hexdump` for one particular file without needing a permanent `--skip-*` flag. `--interactive` and `-y`/`--yes` are mutually exclusive; if both are passed, `--yes` wins and a warning is printed (since suppressing all prompts and asking for a guided walkthrough are contradictory).

### 3.3 `--yes` / `-y`
Forces every prompt (targeted confirmations and, if reached, `--interactive` pauses) to auto-accept the listed default, regardless of TTY status. This is what makes revctf safe to invoke from CI even if someone forgets to redirect output — no auto-detection edge case can cause a hang.

### 3.4 Partial tool skipping
- `--skip-ltrace` — stage 5 is skipped entirely; report notes "ltrace skipped by user request." If `--sandbox` is also passed, revctf prints a notice that it's a no-op in this run (sandbox only ever wrapped the ltrace stage).
- `--skip-ghidra` — a convenience alias that forces `--light-decompile` behavior for the run regardless of RAM tier: Ghidra doesn't run, radare2's disassembly substitutes, same underlying mechanism as the automatic Tier C / OOM fallback, just invoked directly by user choice rather than triggered automatically.

---

## 4. Error Handling & Resilience

### 4.1 Isolate-and-continue, at the stage level
Every stage (not just every file, as in v4's batch isolation) now runs inside its own error boundary. A stage that fails — whether via a normal non-zero exit or a genuinely unexpected crash/segfault in the underlying tool — is:
1. Marked `STAGE FAILED: <stage name>` in the report, with the full diagnostic block from §4.2
2. Appended to the persistent error log (§4.3)
3. **Never allowed to abort the rest of that file's pipeline or the batch** — execution moves on to the next stage/file automatically

This is implemented by avoiding a blanket `set -e` at the top level; each stage runs in its own function/subshell with a local `trap '... ERR'` that captures the failure and returns control to the orchestrator rather than propagating a fatal exit. The **only** things that stop a run entirely are: the global RSS watchdog (§4 of v4, a deliberate safety exception), and an explicit user abort (Ctrl+C, or `[A]bort` in `--interactive` mode).

### 4.2 Detailed diagnostic block
Every stage failure — in the report, in `--verbose` output, and in the persistent error log — includes the same structured detail: the exact command and arguments run, exit code (and signal name if killed by one), a tail of captured stderr, the file being processed, the stage name, and a timestamp. Where applicable, a suggested next step is included (e.g. "re-run with --debug for the full command trace," or "see ~/.revctf/error.log for prior occurrences").

### 4.3 Persistent error log
`~/.revctf/error.log` (permissions `600`) accumulates every stage failure and uncaught exception across all runs, not just the current one — useful for spotting a recurring problem (e.g. the same tool consistently failing on a particular binary class) across sessions. Rotated at 5MB (moved to `error.log.1`, a fresh log started) rather than growing unbounded.

### 4.4 `--verbose` and `--debug`
- `--verbose` — human-readable trace to stderr as the run proceeds: which stage is starting, its command line, and a one-line result when it finishes.
- `--debug` — additionally enables a full `set -x`-level command trace, redirected to `<output_dir>/<basename>.debug.log` rather than the terminal, for deep troubleshooting without cluttering normal output.

### 4.5 Interrupt handling
Any Ctrl+C (SIGINT) aborts the entire run immediately — the standard CLI convention, per your call — rather than trying to distinguish "skip this stage" from "abort everything" via multiple signals. The existing `trap`-based cleanup (temp dirs, in-progress Ghidra projects) still runs before exit. `--interactive` mode's `[A]bort run` option achieves the same result through the prompt flow instead of a signal, for anyone who wants it as part of the guided walkthrough rather than a raw Ctrl+C.

---

## 5. Responsiveness

Any stage running longer than a few seconds (Ghidra is the common case, but this applies uniformly) shows liveness signal so the tool never *looks* hung:
- **Attached to a TTY**: a spinner plus elapsed time on stderr, updated roughly once a second.
- **Redirected/logged output**: periodic heartbeat lines instead (e.g. every ~15s: `"[ghidra] still analyzing chall.bin... 45s elapsed"`), since a rapidly-updating spinner is unreadable/noisy in a log file.

Implemented as a lightweight background subshell started alongside the stage's actual command, checked via `[ -t 2 ]` to pick the display mode, and terminated as soon as the stage completes.

---

## 6. CLI Surface (full, cumulative)

```
revctf scan <file|dir>
  # Output & reporting
  [--output DIR] [--summary-only] [--dry-run]
  # Flag detection
  [--no-flag-scan] [--flag-format REGEX]
  # Analysis depth / stage control
  [--full-hexdump] [--skip-ltrace] [--skip-ghidra]
  [--light-decompile] [--force-full-decompile] [--ghidra-script PATH]
  # Resource tuning
  [--timeout SECONDS] [--jobs-light N] [--jobs-ghidra N]
  [--maxmem-ghidra M] [--no-auto-swap]
  # Sandboxing
  [--sandbox]
  # Agency & interactivity
  [--interactive|-i] [--yes|-y]
  # Diagnostics
  [--verbose] [--debug]
  [-h]
```

New this revision: `--interactive`/`-i`, `--yes`/`-y`, `--skip-ltrace`, `--skip-ghidra`, `--verbose`, `--debug`. Everything else carries forward unchanged from v4.

---

## 7. Proposed Steps (delta from v4)

1. **Scaffold additions**: `lib/prompt.sh` (TTY detection, prompt display, per-run answer memoization), `lib/errorlog.sh` (structured diagnostic formatting + persistent log writes + rotation), `lib/spinner.sh` (TTY-aware liveness indicator).
2. **Argument parsing** extended for the 6 new flags; validate `--interactive` + `--yes` mutual exclusion (warn, `--yes` wins).
3. **Wrap each stage function** (`stage_file.sh` through `stage_ghidra.sh`) in a local `ERR` trap that routes failures through `lib/errorlog.sh` instead of propagating a fatal exit — this replaces any residual reliance on a top-level `set -e`.
4. **Wire `lib/prompt.sh` into**: `stage_ltrace.sh` (sandbox container start), `swap.sh` (auto-creation), `stage_ghidra.sh` (OOM auto-retry) — each call site checks for a remembered per-run answer before showing a new prompt.
5. **`--interactive` orchestration loop**: before invoking each of the 7 stage functions per file, present the Continue/Skip stage/Skip file/Abort prompt; wire "Skip file" to jump to the next target in a batch, "Abort" to the same cleanup path as Ctrl+C.
6. **`--skip-ltrace` / `--skip-ghidra`** — early-exit guards at the top of `stage_ltrace.sh` / `stage_ghidra.sh` (the latter delegating to the existing `--light-decompile` code path); report notes the skip and (for `--skip-ltrace` + `--sandbox` together) prints the no-op notice.
7. **`lib/spinner.sh` wired into** every stage invocation, gated on stage duration exceeding a small threshold (avoid flickering on genuinely fast stages like `file`).
8. **`--verbose` / `--debug`** plumbed through the orchestrator: verbose prints stage start/command/result lines; debug additionally enables `set -x` redirected to the per-run debug log.
9. **`~/.revctf/error.log`** — created with `600` permissions on first write; rotation check (5MB) runs before each append.
10. **README updates** — document the full agency/interactivity model, the diagnostic flags, the persistent error log location, and the deliberate watchdog-prompting exception.
11. **Test pass** (additions):
    - `--interactive` walkthrough: confirm each prompt option (Continue/Skip stage/Skip file/Abort) behaves correctly across a small batch
    - TTY-vs-piped prompt behavior: run once attached to a terminal, once with output piped to a file, confirm prompts appear only in the first case
    - `-y` suppresses prompts in both a TTY and non-TTY context; `--interactive -y` together triggers the mutual-exclusion warning and behaves as `-y`
    - Prompt-answer memoization: trigger the same prompt type twice in one batch (e.g. two files both needing Ghidra OOM fallback), confirm the second occurrence isn't re-asked
    - `--skip-ltrace` and `--skip-ghidra` individually and together, including the `--sandbox` + `--skip-ltrace` no-op notice
    - Inject a deliberate crash into a stage (e.g. a corrupted/segfaulting tool invocation) and confirm: the stage is marked failed with full diagnostics, the pipeline continues to the next stage/file, and the failure appears correctly in both the report and `~/.revctf/error.log`
    - Ctrl+C mid-run confirms full abort + existing cleanup trap still fires
    - `--verbose` and `--debug` output content and destination (stderr vs. debug log file)
    - Spinner appears on a TTY, heartbeat lines appear when output is redirected, for a deliberately slow stage
    - Error log rotation at the 5MB boundary

---

## 8. Repo Layout (delta from v4)

```
revctf/
├── lib/
│   ├── prompt.sh                # TTY detection, prompt display, per-run answer memoization
│   ├── errorlog.sh              # structured diagnostics + persistent log writes + rotation
│   ├── spinner.sh                # TTY-aware liveness indicator (spinner or heartbeat)
│   ├── stage_ltrace.sh          # + --skip-ltrace guard, sandbox-start prompt hook
│   ├── stage_ghidra.sh          # + --skip-ghidra guard, OOM-retry prompt hook
│   ├── swap.sh                  # + auto-swap prompt hook
│   └── ... (all v4 stage/lib files, now individually ERR-trapped)
└── ... (rest unchanged from v4)
```

`~/.revctf/error.log` lives outside the repo/report directory, in the invoking user's home, since it's meant to persist across every run and every target directory.

---

## 9. What Will Not Change

- Default behavior (no flags) remains fully autonomous, non-interactive, and CI-safe — everything in this revision is additive/opt-in except the stage-level error isolation and diagnostic logging, which apply unconditionally because they're pure reliability improvements with no behavioral trade-off.
- The two-phase batch model (light stages complete, then Ghidra) and the RAM-tier system from v4 are unchanged.
- The global RSS watchdog's authority to kill a run without prompting is unchanged and explicitly reaffirmed — see §3.1's exception.

---

## 10. Residual Risks (post-mitigation)

- **TTY auto-detection can be fooled** in unusual setups (e.g. `script`, certain CI runners that allocate a pseudo-TTY) — `--yes`/`-y` is the reliable override for anyone who needs certainty rather than auto-detection.
- **`--interactive` mode adds real wall-clock time** to a run by design (it's meant to) — not suitable for anything time-sensitive; the README will say so explicitly.
- **Per-run prompt memoization** means a user who says "yes" to the first Ghidra OOM fallback won't be asked again even if a later file's situation is meaningfully different (e.g. a much larger binary) — a deliberate simplicity trade-off, not a bug.
- **Stage-level isolate-and-continue** means a pipeline can complete "successfully" with several stages marked failed — the report's failure markers are the mechanism for surfacing this, but a user who only skims the flag-detection section could miss a stage failure that mattered. `--summary-only`'s condensed status lines (v4) help here but don't fully eliminate the risk.
- **The persistent error log accumulates across runs and targets** — worth a periodic manual review or cleanup, since it isn't scoped to a single project the way each run's own report is.

---

## 11. Approval Gate

Reply **`implement`** to begin scaffolding the repo and building this stage by stage, or specify changes first.
