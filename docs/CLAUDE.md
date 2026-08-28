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

**`revctfmasterplan_v6.md` consolidates all four — read that one first.** All five live in
**`design/`** in this repo. They used to sit beside it, which meant a fresh clone lacked the
very document this table calls the highest authority; `design/README.md` explains the move
and flags the two places where v3/v4/v5 are now actively wrong.

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
- **Every external tool launches through `st_run_bounded`. This has been violated three
  times, and every time the cost was a memory ceiling that was reported and enforced by
  nothing.** `lib/stage_dynamic.sh` ran its own `setsid timeout … &` (ltrace, strace) and
  `lib/stage_pydecomp.sh` ran `timeout … | st_strip_ansi`. In all three the ceiling was
  resolved, printed by `--verbose`, and applied to nothing — and `ulimit -f`'s output cap
  was lost too. If a stage needs its own session for the orphan sweep, that is what
  `ST_OWN_SESSION` is for; do not hand-roll a launcher. It backgrounds the tool and
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
- **A test hook that changes behaviour must announce itself in the report.**
  `REVCTF_RAM_MB` labels itself `INJECTED via …` so a tier chosen from a fake number can
  never look measured; `REVCTF_CEIL_MB` does the same. An override the report does not
  mention is indistinguishable from a broken host — a stray `REVCTF_CEIL_MB=1` SIGKILLs
  every bounded stage. Validate and announce **once**, in `tier_resolve`; consumers read
  the resolved global, never the environment.
- **A flag assertion must be scoped to the report's `POSSIBLE FLAGS` section**
  (`flag_section()` in the harness). The report embeds every stage capture and `strings`
  shows most corpus flags in plain sight, so a whole-report grep passes with the flag
  scanner completely dead. Five checks did exactly that. Identical to the `sw0rdf1sh`
  mistake in the `ghidra` section — knowing the lesson did not stop it recurring.
- **When a check stays green under a mutation, establish WHICH of two causes it is before
  changing either side.** Either the check is vacuous, or the mutation is weaker than it
  claims. These look identical in the output and have opposite fixes. The `flag_tiers`
  mutation gutted only `_FLAG_BRACED`, but `_FLAG_GENERIC` (`[A-Za-z0-9_]{2,}\{…\}`)
  matches `flag{…}` too, so the flag was still found — demoted to low confidence, not lost.
  Three checks correctly reported that the product still worked, and "fixing" them would
  have deleted real coverage to make the tool report clean. That is the failure mode of the
  thing that catches the other failure modes: `verify-harness.sh` output is a hypothesis,
  not a verdict.
- **Never report exit 124 and 137 as the same thing.** 124 is a `timeout`; 137 is a
  SIGKILL, which since M5 is how a cgroup memory ceiling announces itself. Six stages once
  reported both as "timed out after Ns", so a FLOSS run killed at its ceiling after ONE
  second was reported as "timed out after 300s" — pointing the reader at the wrong
  constant. Use `st_explain_kill()`.
- **A stage check must assert the artifact the stage produces, not that its tool exists.**
  The `ghidra` harness section passed 3/0 while the stage produced an empty capture, because
  it ran `analyzeHeadless` with no `-postScript` — testing Ghidra, never revctf's stage.
  `v0.3-m5` was tagged against that. It now asserts `sw0rdf1sh` appears in the decompiled
  pseudo-C. Four checks in M5 turned out to pass by never executing; this was the costliest.
- **A bound applied outside a container does not reach inside it.** `systemd-run --scope
  -p MemoryMax` wraps the *docker client*; the container is forked by `dockerd` into another
  cgroup entirely. A sandboxed stage's ceiling must therefore be passed as
  `docker run --memory`, and its teardown must be `docker rm -f <name>` — `ST_LAST_PGID` is
  the client's process group and `timeout` firing kills the client while the container keeps
  running the target. Both failures are invisible: the scan succeeds, the trace arrives, the
  report is right, and only the guarantee is missing.
- **An isolation claim must be printed with the flags that back it.** `STAGE_CMD` reaches
  the report only for a stage that FAILED, so a successful sandboxed run would assert "no
  network, all capabilities dropped" with no evidence under it — and the checks would have
  nothing to grep but revctf's own adjectives. `dyn_banner` prints the real `sbx_wrap`
  output.
- **A negative security test needs a positive control.** "The target cannot reach the
  network" passes trivially on a host with no outbound connectivity. The m6 egress check
  runs the identical probe with `--network=bridge` first, must see it SUCCEED, and SKIPs
  with a reason if it does not. It can never pass by default.
- **A memory ceiling that a stage cannot possibly meet must degrade the stage, not kill
  it.** Tier C cannot afford FLOSS's ~900MB emulation, so it runs `--only static` and the
  report says RAM was the reason. A ceiling that guarantees a failure is worse than none.
- **A shellcheck directive is only valid in front of a complete command**, never a single
  `case` branch — it produces SC1124/SC1072 and breaks parsing. Lift the statement into a
  small function and annotate that instead (see `set_config_path`).
- Commits are authored as `Jijo Shibu <jijoshibuwork@gmail.com>` and made with
  `-c commit.gpgsign=false` so GitHub does not show "Unverified". History before
  2026-08-28 says `Jijo`; it was not rewritten, because doing so would invalidate every
  pushed tag for a cosmetic gain.
- **This file lives at `docs/CLAUDE.md`, but Claude Code only loads `CLAUDE.md` from the
  repo root.** The root file is a four-line stub whose whole job is the `@docs/CLAUDE.md`
  import. Do not delete it — without it every convention here silently stops being loaded,
  and nothing about the repo looks different.

---

## 3. Environment facts — verified, do not re-derive

These cost real time to discover. Each one changed the design.

**Every fact carries the tool version it was verified against, and that is not decoration.**
This section exists so facts are not re-derived — but a fact about a third-party tool is
only true of the version it was measured on, and **two have already decayed**: upx's PIE
unpack bug was fixed in 4.2.4, and radare2 got better at finding `main` in stripped
binaries. Both decayed silently, and the upx one broke six harness checks on a routine
`apt upgrade`.

So: **if a fact below carries a version older than what is installed, re-verify it before
relying on it — and re-stamp it here.** A fact with no version stamp is a fact nobody has
checked recently. Current reference host: Kali rolling, verified 2026-08-20.

| Tool | Verified against | Was |
|---|---|---|
| upx | **4.2.4** | 4.2.2 (fact decayed — see below) |
| radare2 | **6.0.5** | unversioned (fact decayed — see below) |
| binwalk | **2.4.3** | "2.x" |
| checksec | 2.6.0 | 2.6.0 |
| floss | **3.1.1** | unversioned |
| Ghidra | **11.2.1 (pinned)** | 12.1.3 was installed once and broke the stage — see below |
| file / binutils | 5.47 / 2.47 | — |

- **[Ghidra 12.1.3] PyGhidra is NOT enabled under plain `analyzeHeadless` — the post-script
  fails and analyzeHeadless still EXITS 0.** Measured 2026-08-20 after `install.sh` pulled
  the newest release. 12.x ships `Ghidra/Features/PyGhidra` and no Jython, so runtime
  selection correctly picks the PyGhidra script — which then dies with
  `GhidraScriptLoadException: Ghidra was not started with PyGhidra. Python is not
  available`. The stage recorded `empty / 0B / exit 0` and the corpus crackme's password
  (which 11.2.1 recovers) was silently not found. Two consequences, both now in the code:
  **(a)** `install.sh` installs the **pinned, verified** build by default; `GHIDRA_LATEST=1`
  opts into newest with a warning. **(b)** `stage_ghidra` now treats "empty capture + script
  error in stderr" as a FAILURE (`_ghidra_saw_script_error`) instead of a clean negative.
  **Running the PyGhidra post-script headlessly on 12.x is UNSOLVED** — `support/pyghidraRun`
  is the GUI launcher and there is no `analyzeHeadless` equivalent wired up. Anyone moving
  to 12.x must solve that first; `scripts/pyghidra_decompile.py` has never successfully run
  against a real PyGhidra install.
- **[Ghidra 11.2.1] runs `.py` post-scripts under Jython 2.7.3, not PyGhidra.** v3 §1's
  "11.x+ → PyGhidra" boundary is **wrong**; the real boundary is **11.3**, where PyGhidra
  became the bundled default and Jython was removed. `pf_detect_ghidra_runtime()` therefore
  probes `Ghidra/Features/{PyGhidra,Jython}` and only falls back to a version comparison.
- **[floss 3.1.1] stack/tight/decoded extraction is PE-only.** On ELF it errors out; only static
  strings work. Stage 10 must be format-aware: all modes on PE and shellcode
  (`--format sc32|sc64`), `--only static` on ELF, and the report must say so plainly so a
  missing flag never reads as a clean negative.
- **`flare-floss` cannot be pip-installed system-wide on modern Debian/Ubuntu** — its `halo`
  dependency fails with `AttributeError: install_layout`. Use a venv.
- **[upx 4.2.2 — DECAYED, fixed in 4.2.4]** upx 4.2.2 packed a PIE ELF but could not
  unpack it (`Exception: checksum error`). **upx 4.2.4 unpacks it fine.** The product's
  handling is still correct — fail the stage cleanly, preserve upx's message, continue on
  the packed bytes — it simply no longer fires here.
  **The damage was in the harness.** `packed_upx_broken` was a PIE ELF *relying on that
  bug* to be a guaranteed-unpack-failure fixture, and six checks (`--strict`, exit-2, the
  unwrap diagnostic) needed it to fail. An apt upgrade silently repaired the fixture and
  broke all six at once. **Fixed 2026-08-20:** the fixture is now corrupted by construction
  — pack normally, then overwrite 128 bytes of the compressed stream anchored to the
  trailing `UPX!` packheader — so no upx version can decompress it. Do not "fix" it back
  into depending on a vendor defect.
- **[binwalk 2.4.3, upx 4.2.4] binwalk and upx reject the `--` end-of-options marker** (`Cannot open file --`).
  Omitted for those two; `RUN_TARGET` is absolutised so it is never ambiguous anyway.
- **[checksec 2.6.0] colours unconditionally** — it ignores both `NO_COLOR` and `TERM=dumb`.
  radare2 also writes progress escapes to *stderr* even with `scr.color=0`.
- **`xxd` is not part of a base install** (it ships with vim-common). Depending on it made
  the hex decoding sweep a silent no-op.
- **`/usr/bin/time` is not part of a base install either** (separate `time` package; the
  shell's `time` keyword reports no RSS). `tools/measure-host.sh` silently took its
  wall-clock-only branch, so the FLOSS peak M5's Phase-2 ceiling depends on never appeared
  and the output still looked complete. It now falls back to
  `python3 -c 'resource.getrusage(RUSAGE_CHILDREN)'` — same kernel counter, already-mandatory
  dependency.
- **[radare2 6.0.5] recovers `main` in a *stripped* non-PIE ELF** (it reads the argument
  to `__libc_start_main`), so `strip -s` no longer forces the `entry0` fallback. The
  harness check "a stripped binary falls back to entry0" assumes it cannot, and fails.
  **This is a decayed fact:** the check was written when an older radare2 could not do
  this. The product is fine — the fallback is still correct when there genuinely is no
  `main`; the fixture just no longer produces that condition.
- **`ulimit -v` cannot bound a JVM.** A hello-world `java` needs 2–4GB of *virtual* address
  space; at the tier ceilings (1024M/768M/512M) the JVM refuses to start at all
  (`Could not reserve enough space for object heap`). v4 §4.3's documented `ulimit -v`
  fallback would therefore have converted a memory bound into total loss of the Ghidra
  stage on every non-systemd host. JVM stages are exempt on that path; see
  `tier_stage_is_jvm`.
- **`systemd-run --scope` needs `--collect`**, or every OOM-killed scope leaves a `failed`
  transient unit that only `systemctl --user reset-failed` clears.
- **`python3 -m dis` cannot read a `.pyc`** — it treats its argument as source. Unmarshal
  the code object first; see `scripts/pyc_disasm.py`.
- **Jython 2.7 refuses a source file with any non-ASCII byte** unless it carries a PEP 263
  encoding declaration. The failure shows up only as an empty Ghidra stage, exit 0.
- **Ghidra is downloadable even where `github.com/.../releases/latest` returns 403**, via the
  release-asset host. See `.claude/cloud-setup.sh`.

---

## 3b. The Kali target environment

Development moves to Kali at M5. **The chosen host is a VirtualBox Kali VM**, not WSL, for
one decisive reason: v3 §8's memory derivation is
`4096MB − 800MB (XFCE) − 50MB (bash) − 300MB (Docker) ≈ 2946MB`. That 800MB desktop is a
load-bearing term. WSL has no desktop, so tier numbers measured there would show ~800MB of
headroom a real user does not have — and M5 is the milestone that turns measurements into
constants. A real VM also boots systemd itself, has a real kernel (stable RSS accounting
for the watchdog), and supports snapshots before destructive tests.

**On VirtualBox:** give the VM 4096MB for normal work (Tier A, and v3's exact target) and
2048MB when testing Tier C. Snapshot before `bootstrap-kali.sh` if the VM is used for
anything else.

The WSL notes below are kept in case the host changes:

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
                          Ghidra order: GHIDRA_HOME -> PATH -> /opt/ghidra* (D12)
lib/stage_triage.sh       Stage 0: classify + unwrap (packers, archives, managed, Python)
lib/stage_*.sh            one file per analysis stage
lib/flagscan.sh           tiered regex + encoding sweep            (M3)
lib/config.sh             config key registry + coercion           (M4)
lib/report.sh             report assembly                          (M4)
lib/tui.sh                stage table / line / heartbeat, stderr   (M4)
lib/tier.sh               RAM tiers, ceilings, per-stage limits     (M5)
lib/watchdog.sh           global RSS watchdog; kills the job tree   (M5)
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
./tools/run-tests.sh             # the checks
./tools/verify-harness.sh        # proves the checks would catch a broken product
```

**`./tools/verify-harness.sh` is a pre-tag gate, not an optional extra.** It applies five
known breakages and asserts the named checks flip PASS → FAIL, then restores and asserts
green. A green harness is evidence only if a broken product turns it red, and four separate
times in this project it did not. Its first run found three stages whose memory ceiling was
enforced by nothing, two stages that had never captured any output, and five vacuous flag
checks. Adding a mutation is two `case` branches — keep it cheap, so the next person who
fixes a vacuous check pins it in the same commit.

**When you fix a vacuous check, add the mutation that proves the fix.** Otherwise the
replacement is worth exactly as much as the check it replaced, and nobody can tell.

The `ghidra` section self-skips when no Ghidra is installed, so the harness stays useful
anywhere. Set `PF_OPT_ROOT_REAL=/opt` to point it at a real install.

**Every milestone:** implement → `./tools/run-tests.sh` green → append a section to
`implementation-notes.md` → commit. The execution masterplan's Definition-of-Done gates are
the standard; do not advance past one until its verification actually runs. Each milestone
adds its own section to the harness so earlier gates keep being re-checked.

**Milestone status:** M0, M1, M2, the QA pass, M3, M4, **M5** and **M6** are complete. Tags through
`v1.0.0`. Two "complete" marks were corrected on 2026-08-21 after mutation testing: M5's
enforcement claim was false for three of seven bounded stages, and M3's "all 13 stages run
end to end" was false for `ltrace` and `strace`, which captured nothing. Superseded tags
are left in place as a record of what was believed. Single-file scanning works end to end: 14 stages, flag
detection, a readable report, three display modes, and enforced per-stage memory ceilings.

**M5 was built on the Kali VM**, where `systemd-run --scope -p MemoryMax` works — so v4
§4.3's primary bounding path executed for the first time in this project.

**Both pre-tag gates have now run (2026-08-20):** `shellcheck -S style` is clean across
every shell file, and `install.sh` has been executed end-to-end on real Kali — which found
four defects, including one that silently broke the Ghidra stage. See
`implementation-notes.md` "install.sh — what the first real run exposed".

M6 shipped in v1.0: the sandbox is ON by default (D13), `--no-sandbox` opts out, and
without Docker the two executing stages skip rather than running on the host. Next is **M7**
(batch mode), which is post-1.0. Historical note, kept because the traps are still real —
M6 was **unblocked**: Docker 28.5.2 runs on the VM and the full
`--network=none --read-only --cap-drop=ALL` contract is verified, including no network
egress. See `HANDOFF.md` §6 for two access traps that make a working daemon look dead
(a stale `DOCKER_HOST` pointing at a podman socket, and per-process group membership).
**M7** (batch mode) is the alternative, and D11 flags a prerequisite: Phase-2 concurrency
must decouple from Phase-3.

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
- **Resolved in M6 (deviations D9, D13):** the sandbox covers `strace` as well as `ltrace`,
  it is ON by default, and without Docker those stages skip rather than running on the host.
- **RESOLVED at M5 (deviation D11): Phase 2 no longer inherits Ghidra's ceiling.** Sized
  from measurement instead — 1536/1024/512MB. The decisive figure was not the 1.46GB blob
  but **899MB on a 264KB PE**: FLOSS's cost is vivisect's emulation workspace, not file
  size, so `FLOSS_MAX_MB` (an input-size gate) never bounded memory at all despite its
  comment claiming it kept FLOSS "comfortably inside every tier".
- **Two tools reject the `--` end-of-options marker AND so does radare2** (it analyses
  nothing and every binary looks stripped). Check any new tool for this before trusting it.
- **`nohup` makes SIGHUP untrappable for every descendant.** It sets SIGHUP to SIG_IGN
  (`SigIgn: …1` in `/proc/<pid>/status`), the disposition is inherited, and bash will not
  install a trap for a signal ignored on entry — the same rule that makes SIGINT
  untrappable for a backgrounded job. Running the harness under `nohup` therefore made the
  SIGHUP check fail while revctf was behaving correctly. Launch long harness runs with
  `setsid`, not `nohup`. The check now detects the ignored disposition and skips itself
  with a reason.
