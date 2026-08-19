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
- **`lib/tui.sh` is FROZEN** (QA review #2). Bug fixes only — no new features, modes,
  colour or progress bars. The harness pins its line count, so growth fails the build.
  If it ever needs a second dedicated debugging session, **delete it and default to line
  mode**: the four `tui_*` entry points keep their signatures, so nothing else changes.
  Do not "improve" this file.
- **All progress output goes to stderr; the report owns stdout.** `lib/tui.sh` must never
  write to stdout. `revctf scan x > report.txt` has to produce a clean file while progress
  still reaches the terminal, and v6 §10 requires the report to be plain text in every
  display mode.
- **A shellcheck directive is only valid in front of a complete command**, never a single
  `case` branch — it produces SC1124/SC1072 and breaks parsing. Lift the statement into a
  small function and annotate that instead (see `set_config_path`).
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
  radare2 also writes progress escapes to *stderr* even with `scr.color=0`.
- **`xxd` is not part of a base install** (it ships with vim-common). Depending on it made
  the hex decoding sweep a silent no-op.
- **`python3 -m dis` cannot read a `.pyc`** — it treats its argument as source. Unmarshal
  the code object first; see `scripts/pyc_disasm.py`.
- **Jython 2.7 refuses a source file with any non-ASCII byte** unless it carries a PEP 263
  encoding declaration. The failure shows up only as an empty Ghidra stage, exit 0.
- **Ghidra is downloadable even where `github.com/.../releases/latest` returns 403**, via the
  release-asset host. See `.claude/cloud-setup.sh`.

---

## 3b. The WSL / Kali target environment

Development moves to WSL Kali (or a Kali VM) at M5. These facts are not optional details —
each one silently voids something the design depends on.

- **WSL2 does not boot systemd by default.** M5's Definition of Done requires
  `systemd-run --scope -p MemoryMax=…` to work, and that path has **never executed once**
  in this project: the cloud build sandbox had systemd installed but not booted, so every
  run fell through to the `ulimit -v` fallback, which bounds *virtual size*, not RSS.
  Migrating to WSL without enabling systemd inherits the exact blocker the move was meant
  to escape. Put this in `/etc/wsl.conf`, then `wsl --shutdown` from PowerShell:

  ```ini
  [boot]
  systemd=true
  ```

  Verify with `systemctl is-system-running` and `systemd-run --user --scope true`.
- **`.wslconfig` is the Tier C test rig.** M5's DoD asks for "a forced-2GB cgroup/VM".
  In `C:\Users\<user>\.wslconfig`, `[wsl2] memory=2GB` plus `processors=2`, then
  `wsl --shutdown`. That is the cheapest way to test a tier boundary honestly, and it is a
  real argument for WSL over a VM here.
- **The repo must live in the Linux filesystem** (`~/revctf`), never under `/mnt/c` or
  `/mnt/d`. NTFS cannot hold the `0600` capture and `0700` directory modes v4 §5 requires
  and QA-9/QA-10 fixed. The permission tests would pass while the guarantee was void —
  worse than failing.
- **Line endings.** `.gitattributes` pins `* text=auto eol=lf`. A CRLF `.sh` fails as
  `bad interpreter: No such file or directory`. Do not remove it, and do not let a global
  `core.autocrlf=true` be assumed safe.
- **Claude Code runs inside the WSL shell**, never in PowerShell. Native Windows has no
  `ltrace`, no `strace`, no `radare2` against ELF, no `setsid`, no process groups, no
  `ulimit -f`/`SIGXFSZ` and no POSIX permission bits — which is most of what `lib/` relies on.
- **`install.sh` is still a stub.** Its whole dependency block is commented out while
  README calls it mandatory and preflight tells users to "re-run it (while online)" when a
  tool is missing. **Completing it is the first task after this handoff.**
  `tools/bootstrap-kali.sh` is the stopgap; note it installs FLOSS via a venv, because
  `pip install --break-system-packages flare-floss` — the line install.sh still carries —
  is already documented in §3 as failing.
- **Use `setsid`, not `nohup`, for long background harness runs.** `nohup` sets SIGHUP to
  SIG_IGN for every descendant, which makes the `qa` SIGHUP check report a phantom
  regression. The check now detects and skips, but the launcher is the real fix.

---

## 4. Layout

```
revctf                    entry script: arg parsing, config, dispatch, orchestration
lib/stage.sh              the stage framework — read this before writing a stage
lib/preflight.sh          tool discovery, versions, Ghidra runtime, disk, systemd-run probe
lib/stage_triage.sh       Stage 0: classify + unwrap (packers, archives, managed, Python)
lib/stage_*.sh            one file per analysis stage
lib/flagscan.sh           tiered regex + encoding sweep            (M3)
lib/config.sh             config key registry + coercion           (M4)
lib/report.sh             report assembly                          (M4)
lib/tui.sh                stage table / line / heartbeat, stderr   (M4)
lib/tier.sh               RAM tier resolution + overrides          (M5 groundwork)
scripts/*.py              the two Ghidra headless post-scripts     (M3)
tools/build-test-corpus.sh  regenerates the 18-artifact corpus (binaries are gitignored)
tools/run-tests.sh        milestone-gate verification harness
tools/tui-selftest.sh     interactive checks needing a real terminal (M4)
tools/measure-host.sh     capture the numbers M5's constants are derived from
tools/bootstrap-kali.sh   one-shot Kali/WSL setup — stopgap until install.sh works
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

**Milestone status:** M0, M1, M2, the QA pass, M3 and **M4** are complete — **188 checks
green**, tagged `v0.1-mvp`. Single-file scanning works end to end: 14 stages, flag
detection, a readable report, three display modes.

Next is **M5**, and it **must be built on real hardware, not in a cloud sandbox** — see
`HANDOFF.md` §6. Tier B/C cannot be entered on an 8GB host, `systemd-run` cannot run
without systemd booted, M6 needs a Docker daemon and M8 needs a TTY.

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
- **Resolved in M3 (deviation D9):** `--sandbox` covers `strace` as well as `ltrace`, and
  refuses the host until M6 builds the container.
- **M5 must NOT inherit Ghidra's ceiling for Phase 2.** Measured: FLOSS peaks at ~1.46GB on
  a 220MB target, exceeding Tier A's 1024M and roughly 3x Tier C's. v6 §5's assumption is
  disproved; size Phase 2 from that number. `FLOSS_MAX_MB` (64MB) is the interim guard.
- **Two tools reject the `--` end-of-options marker AND so does radare2** (it analyses
  nothing and every binary looks stripped). Check any new tool for this before trusting it.
- **`nohup` makes SIGHUP untrappable for every descendant.** It sets SIGHUP to SIG_IGN
  (`SigIgn: …1` in `/proc/<pid>/status`), the disposition is inherited, and bash will not
  install a trap for a signal ignored on entry — the same rule that makes SIGINT
  untrappable for a backgrounded job. Running the harness under `nohup` therefore made the
  SIGHUP check fail while revctf was behaving correctly. Launch long harness runs with
  `setsid`, not `nohup`. The check now detects the ignored disposition and skips itself
  with a reason.
