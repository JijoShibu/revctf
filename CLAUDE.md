# CLAUDE.md — standing context for revctf

Read this before touching anything. It exists because sessions start cold: a cloud session
has no memory of earlier work, and this file plus `implementation-notes.md` are what
replace it.

`revctf` is a Bash CLI for Kali Linux. It takes a reverse-engineering CTF challenge file
(or a directory of them), runs a staged toolchain against it, and produces a
beginner-friendly plain-text report with flag candidates at the top.

---

## 1. Which document is authoritative

Five design documents exist. They do not all agree. Resolve conflicts in this order:

| Rank | Document | Authority |
|---|---|---|
| 1 | **`revctfmasterplan_v6.md` §11** (Deviation Register) | Final. Records every departure from v3/v4/v5 and why. |
| 2 | `revctfmasterplan_v5.md` + `revctf_executionmasterplan.md` | Authoritative for behaviour, CLI surface, milestone order. |
| 3 | `revctfmasterplan_v4.md` | Fills gaps only: RAM tier table, resource isolation, watchdog, swap, Ghidra OOM retry. |
| 4 | `revctfmasterplanv3.md` | Fills gaps only: memory derivations, base CLI semantics, per-stage invocations, sandbox hardening. |

**`revctfmasterplan_v6.md` consolidates all four — read that one first.** The design
documents live alongside the repo, not inside it.

`implementation-notes.md` (in this repo) records what was learned *while building*, as the
execution masterplan §4 requires. Append to it whenever something non-obvious comes up.

---

## 2. Non-negotiable conventions

- **Never add `set -e`.** Not at the top level of `revctf`, not in any `lib/*.sh`. v5 §4.1
  mandates stage-level isolate-and-continue: a failing stage is diagnosed and skipped, and
  only the RSS watchdog or an explicit user abort stops a run. A blanket `set -e` breaks
  exactly the guarantee the design is built on. Every `lib/` file carries a comment saying
  so — do not "helpfully" remove it.
- **`shellcheck -S style` must be clean** across `revctf`, `install.sh`, `lib/*.sh` and
  `tools/*.sh`. The harness asserts zero findings. Cross-file `SC2034` warnings on shared
  globals get a targeted `# shellcheck disable` with a reason, never a blanket suppression.
- **Stream to disk, never buffer in a variable.** v3 §1. A 220MB firmware image is a normal
  CTF target. `stage_capture()` in `lib/stage.sh` is the only place external tools get run;
  use it.
- **Stages never `exit`.** They return a status and record it. `stage_run()` is the error
  boundary.
- **Only `lib/stage.sh` writes the `STAGE_*` arrays.** A stage that runs its own tool calls
  `stage_record_exec()`.
- **The user's original file is never modified.** Stage 0 unwraps to copies under
  `RUN_WORKDIR`.
- **Report output is plain text**, always, in every display mode. Filter coloured tool
  output through `st_strip_ansi()`.
- **Every external tool launches through `st_run_bounded`.** It backgrounds the tool and
  `wait`s, which is what makes a run interruptible — bash defers a trap until the current
  foreground command finishes, so a tool run in the foreground swallows Ctrl+C for its whole
  duration (measured: 77 seconds) and orphans the process. It also applies the per-stage
  output size cap. Never invoke a tool directly.
- **Never let an externally-supplied value reach an arithmetic test.** `[[ $x -eq 1 ]]` is
  arithmetic context; under `set -u` a non-numeric word there is treated as a variable name
  and **exits the shell**, which `stage_run`'s boundary cannot catch. Coerce and validate
  first — this was the critical QA finding.
- **The flag scan uses `grep -E` only.** Never `grep -P`, never a PCRE engine, never Bash
  `=~` against a user pattern. `--flag-format` is user input run over megabytes of capture;
  a backtracking engine makes that a self-inflicted DoS. The harness fails if any PCRE flag
  appears in `lib/`.
- Commits are authored as `Jijo <jijoshibuwork@gmail.com>` and made with
  `-c commit.gpgsign=false` so GitHub does not show "Unverified".

---

## 3. Environment facts — verified, do not re-derive

These cost real time to discover. Each one changed the design.

- **Ghidra 11.2.1 runs `.py` post-scripts under Jython 2.7.3, not PyGhidra.** v3 §1's
  "11.x+ → PyGhidra" boundary is **wrong**; the real boundary is **11.3**, where PyGhidra
  became the bundled default and Jython was removed. `pf_detect_ghidra_runtime()` therefore
  probes `Ghidra/Features/{PyGhidra,Jython}` and only falls back to a version comparison.
- **FLOSS stack/tight/decoded extraction is PE-only.** On ELF it errors out; only static
  strings work. Stage 10 must be format-aware: all modes on PE and shellcode
  (`--format sc32|sc64`), `--only static` on ELF, and the report must say so plainly so a
  missing flag never reads as a clean negative.
- **`flare-floss` cannot be pip-installed system-wide on modern Debian/Ubuntu** — its `halo`
  dependency fails with `AttributeError: install_layout`. Use a venv.
- **upx 4.2.2 packs a PIE ELF but cannot unpack it** (`Exception: checksum error`). PIE is
  the default on modern Kali, so this fires on real challenges. Fail the stage cleanly,
  preserve upx's real message, and continue on the packed bytes.
- **binwalk 2.x and upx reject the `--` end-of-options marker** (`Cannot open file --`).
  Omitted for those two; `RUN_TARGET` is absolutised so it is never ambiguous anyway.
- **checksec 2.6.0 colours unconditionally** — it ignores both `NO_COLOR` and `TERM=dumb`.
- **Ghidra is downloadable even where `github.com/.../releases/latest` returns 403**, via the
  release-asset host. See `.claude/cloud-setup.sh`.

---

## 4. Layout

```
revctf                    entry script: arg parsing, config, dispatch, orchestration
lib/stage.sh              the stage framework — read this before writing a stage
lib/preflight.sh          tool discovery, versions, Ghidra runtime, disk, systemd-run probe
lib/stage_triage.sh       Stage 0: classify + unwrap (packers, archives, managed, Python)
lib/stage_*.sh            one file per analysis stage
lib/flagscan.sh           tiered regex + encoding sweep            (M3)
lib/report.sh             report assembly                          (M4)
lib/tui.sh                live stage table / line / heartbeat       (M4)
scripts/*.py              the two Ghidra headless post-scripts     (M3)
tools/build-test-corpus.sh  regenerates the 18-artifact corpus (binaries are gitignored)
tools/run-tests.sh        milestone-gate verification harness
.claude/cloud-setup.sh    toolchain install for a cloud environment
```

`lib/stage.sh` is an addition to v6 §12's layout — deliberate, and recorded in
`implementation-notes.md`.

---

## 5. How to work

**Before changing anything:**

```bash
./tools/build-test-corpus.sh     # 18 artifacts; needs gcc, mingw, JDK, zip, upx, python3
./tools/run-tests.sh             # sections: lint corpus m0 m1 m2 ghidra
```

The `ghidra` section self-skips when no Ghidra is installed, so the harness stays useful
anywhere. Set `PF_OPT_ROOT_REAL=/opt` to point it at a real install.

**Every milestone:** implement → `./tools/run-tests.sh` green → append a section to
`implementation-notes.md` → commit. The execution masterplan's Definition-of-Done gates are
the standard; do not advance past one until its verification actually runs. Each milestone
adds its own section to the harness so earlier gates keep being re-checked.

**Milestone status:** M0, M1, M2 and the pre-M3 QA pass complete — tagged `v0.2-m2-qa`,
127 checks green. Next is **M3** (ltrace, strace, FLOSS,
radare2, Ghidra, managed/Python decompilers, `lib/flagscan.sh`), then **M4** — the MVP gate:
report assembly, TUI, and full single-file wiring. M5–M9 add RAM tiers, the Docker sandbox,
batch mode, user agency, and resilience.

---

## 6. Open questions

Carried in `implementation-notes.md`, repeated here because they affect design choices:

- The 1800s Ghidra time bound (v6 §7.4) is a guess — no prior masterplan bounded Ghidra by
  time at all. Measure it against a slow-path binary before trusting it.
- FLOSS's real peak RSS is assumed, not measured. Phase 2 inherits the tier's Ghidra ceiling
  on the argument that it matches an already-tested profile.
- The tier boundaries (3.8GB / 2.5GB) are estimates, flagged as such in v4 §10. The Jython
  boundary was an estimate too, and it was wrong — treat these the same way once M5 can
  measure them.
- Archive members are extracted into `TRIAGE_MEMBERS` but not yet analysed individually;
  that orchestration belongs with batch mode (M7).
- Deviation D7 (missing optional tool = hard error) is applied in two tiers: core and
  always-needed tools fail at startup, format-conditional decompilers fail lazily when a
  target routes to them. Flagged for review.
- **`SIGINT` cannot be trapped when revctf is backgrounded from a non-interactive shell.**
  POSIX makes such jobs ignore it and bash will not install a trap for an
  ignored-on-entry signal. Not fixable in bash; `SIGTERM` is the documented alternative.
  Do not "fix" this — it has already been investigated.
- **M3 decision still open:** v5 scopes `--sandbox` to `ltrace`, but `strace` executes the
  challenge binary just as directly. Decide whether the sandbox covers it before shipping
  the stage.
