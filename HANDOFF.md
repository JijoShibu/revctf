# HANDOFF.md — the one file to read first

Consolidated session context for `revctf`. Its job is to let a **fresh session
with no chat history** reach full working competence by reading this file plus
the four it points at — so no future session needs to carry a long transcript.

If you are a new session: read this file top to bottom, then `CLAUDE.md`. That
is enough to start work. Read the others on demand.

Last consolidated: 2026-08-20, after **M5** (memory-bound enforcement, RSS watchdog,
Phase-2 ceiling measured — deviation D11) on the Kali VM. Previous: 2026-08-19 after M4
(`v0.1-mvp`) + QA review #2 + the D10 scope reduction.

---

## 1. What revctf is

A pure-Bash CLI for Kali Linux. It takes a reverse-engineering CTF challenge
file (or a directory of them), runs a staged toolchain — triage/unwrap, static
analysis, dynamic tracing, decompilation — and writes a beginner-friendly
plain-text report with flag candidates surfaced at the top.

Not a library, not a framework. One entry script, `lib/*.sh` modules, two Ghidra
post-scripts, a corpus generator and a verification harness.

---

## 2. Document map — what answers what

| Question | File |
|---|---|
| What may I never do to this codebase? | **`CLAUDE.md` §2** — the non-negotiables |
| Which spec wins when two disagree? | **`CLAUDE.md` §1** — precedence table |
| What is built, what is not? | **`CHECKLIST.md`** — 84 items, 9 phases |
| What changed, milestone by milestone? | `CHANGELOG.md` |
| Why was it built this way? | `implementation-notes.md` — decisions + rationale |
| What broke, and how was it proved? | `QA-REVIEW.md` — 16 defects with reproductions |
| How do I use the tool? | `README.md` |
| Full behavioural spec | `revctfmasterplan_v6.md` (lives beside the repo, not in it) |
| Milestone order and gates | `revctf_executionmasterplan.md` |

`revctfmasterplan_v3/v4/v5.md` are historical; v6 consolidates them. **Precedence:
v6 §11 Deviation Register > v5 + execution masterplan > v4 > v3.**

---

## 3. Current state

**M0, M1, M2, the QA pass, M3, M4 and M5 are complete.** `v0.1-mvp` is tagged; M5 is not
yet tagged (see the caveats below).

**M5 was built on the target Kali VM, not in the cloud** — which is the whole reason it
could be finished. `systemd-run --scope -p MemoryMax` works there, so v4 §4.3's primary
memory-bounding path executed for the first time in this project's history.

**One M5 exit criterion is not closed:** QA review #2 §7 asks for correct tier selection on
a *genuinely* 2GB host, and `REVCTF_RAM_MB` only tests the branch. To close it, shut the VM
down, set RAM to 2048MB in VirtualBox, boot, and run
`./tools/run-tests.sh m5 m5enforce` — Tier C should be selected from real hardware, FLOSS
should degrade to static-only, and Ghidra should be skipped by default. Everything else in
M5 is verified on real hardware.

**Both pre-tag gates have run (2026-08-20).** `shellcheck -S style` is clean across every
shell file, and `install.sh` executed end-to-end on real Kali. That run found four defects
that review had not — including one that made the Ghidra stage silently produce nothing —
which is exactly why QA review #2 insisted the installer be run rather than read. Detail in
`implementation-notes.md` under "install.sh — what the first real run exposed".

- All 13 analysis stages plus Stage 0 triage run end to end.
- Flag detection works, including the base64/base32/hex/ROT13 encoding sweep.
- Ghidra headless verified against a real 11.2.1 install: it recovers the
  password `sw0rdf1sh` from the corpus crackme's pseudo-C.
- Single-file scanning works end to end: report with flags first, three display modes.
- **Verification: `./tools/run-tests.sh`. The total check count is NOT a constant — do not
  chase a number.** Sections self-skip when a tool is absent (`lint` without shellcheck,
  `ghidra` and part of `m5enforce` without a Ghidra install, the 220MB checks under
  `REVCTF_TEST_FAST=1`), so the same commit legitimately reports different totals on
  different machines. Two real data points: **262 in the M0–M4 cloud sandbox**, and
  **147 passed / 111 failed / 4 skipped on this Kali VM before `install.sh` had been run**
  — that 111 was almost entirely D7 refusing to scan without FLOSS, not 111 broken things.
  **The gate is: zero failures, and every skip has a stated reason.** A previous handoff
  quoted "262 checks, all green" as if it were absolute, and the next session lost time
  trying to reconcile a number that never applied to its machine.
  Sections:
  `lint corpus m0 m1 m2 m3 m4 m5 m5enforce qa docs ghidra`. `m5` checks tier
  *resolution*; `m5enforce` checks the ceilings actually bound a real scan. `REVCTF_TEST_FAST=1` skips the 220 MB
  target checks (~3 min instead of ~15).
- Tags `v0.2-m2-qa` and `v0.1-mvp`. Branch `main`, pushed to
  <https://github.com/JijoShibu/revctf> (private).

Progress: 72% of build tasks; 45 of 84 tracked items done; 5 of 10 milestones.

### Remaining milestones

| # | Scope | Can this cloud sandbox validate it? |
|---|---|---|
| M4 | ~~report, TUI, `--summary-only`, config extraction~~ | **DONE** — but the TUI is verified only as far as a `script(1)` pty allows; run `tools/tui-selftest.sh` on a real terminal |
| M5 | **DONE** — enforcement, RSS watchdog, tier-driven Ghidra MAXMEM, Phase-2 ceiling measured (D11). Swap offer removed (D10) | Built and verified on the Kali VM, where `systemd-run` works |
| M6 | Docker sandbox image, `install.sh` hardening, vendor `pyinstxtractor`. **Independent of M5** | **Yes** — Docker 28.5.2 runs on the VM; the full `--network=none --read-only --cap-drop=ALL` contract is verified, including no egress |
| M7 | Batch mode, three-phase scheduling, per-archive-member analysis. **Depends on M5** for tier-driven concurrency | Logic yes, but it is blocked behind M5 |
| M8 | `--interactive` agency: Continue / Skip stage / Skip file / Abort | **No** — no TTY |
| M9 | Crash resilience, resume, error-log rotation | Partly |

---

## 4. The non-negotiable rules (condensed from `CLAUDE.md` §2)

Violating any of these silently breaks a guarantee the design rests on.

1. **Never add `set -e`.** v5 §4.1 mandates stage-level isolate-and-continue. A
   blanket `set -e` destroys exactly that. Every `lib/` file carries a comment
   saying so — do not "helpfully" remove it. The file header is `set -uo pipefail`.
2. **Never let an externally-supplied value reach an arithmetic test.**
   `[[ $x -eq 1 ]]` is arithmetic context; under `set -u` a non-numeric word
   there is read as a variable name and **exits the shell outright**, which
   `stage_run`'s error boundary cannot catch. This was QA-1, the critical finding.
   Coerce and validate first.
3. **The flag scan uses `grep -E` only.** Never `grep -P`, never a PCRE engine,
   never Bash `=~` against a user pattern. `--flag-format` is user input run over
   megabytes of capture; a backtracking engine is a self-inflicted DoS. The
   harness fails if any PCRE flag appears in `lib/`.
4. **Every external tool launches through `st_run_bounded`.** It backgrounds the
   tool and `wait`s, which is what makes a run interruptible — bash defers a trap
   until the foreground command finishes, so a foreground tool swallows Ctrl+C for
   its whole duration (measured: 77 s) and orphans the process. It also applies
   the `ulimit -f` output cap. Never invoke a tool directly.
5. **Stream to disk, never buffer in a variable** (v3 §1). A 220 MB firmware image
   is a normal target. `stage_capture()` is the only place tools get run.
6. **Stages never `exit`.** They return a status. `stage_run()` is the boundary.
7. **Only `lib/stage.sh` writes the `STAGE_*` arrays.** A stage running its own
   tool calls `stage_record_exec()`.
8. **The user's original file is never modified.** Stage 0 unwraps to copies
   under `RUN_WORKDIR`.
9. **Report output is plain text in every display mode.** Filter coloured tool
   output through `st_strip_ansi()`.
10. **`shellcheck -S style` must be clean** across `revctf`, `install.sh`,
    `lib/*.sh`, `tools/*.sh`. Cross-file `SC2034` gets a targeted disable with a
    reason, never a blanket suppression.
11. Captures are `0600`; a directory revctf **creates** is `0700`. Never `chmod`
    a pre-existing user directory.
12. Commits are authored `Jijo <jijoshibuwork@gmail.com>` with
    `-c commit.gpgsign=false`. Commit messages go through `git commit -F` — a
    message line starting with `--` breaks the shell.

---

## 5. Verified environment facts — do not re-derive

Each of these cost real time to discover and each one changed the design.
Full detail in `CLAUDE.md` §3 and `implementation-notes.md`.

- **Ghidra 11.2.1 runs `.py` post-scripts under Jython 2.7.3, not PyGhidra.**
  v3 §1's "11.x+ → PyGhidra" boundary is **wrong**; the real boundary is **11.3**.
  `pf_detect_ghidra_runtime()` probes `Ghidra/Features/{PyGhidra,Jython}` and only
  falls back to a version comparison.
- **Jython 2.7 refuses any source file containing a non-ASCII byte** unless it
  carries a PEP 263 encoding declaration on line 2. The failure surfaces only as
  an empty Ghidra stage that still exits 0. Em-dashes in comments caused this.
- **FLOSS stack/tight/decoded extraction is PE-only.** On ELF it errors; only
  static strings work. Stage 10 is format-aware, and the report says which mode
  applied so a missing flag never reads as a clean negative.
- **`flare-floss` cannot be pip-installed system-wide on modern Debian/Ubuntu** —
  its `halo` dependency fails with `AttributeError: install_layout`. Use a venv.
- **upx 4.2.2 packs a PIE ELF but cannot unpack it** (`Exception: checksum
  error`). PIE is the Kali default, so this fires on real challenges.
- **binwalk 2.x, upx, AND radare2 all reject the `--` end-of-options marker.**
  radare2's was the worst: it analysed nothing, so every binary looked stripped
  and every disassembly silently used the `entry0` fallback. **Check any new tool
  for this before trusting it.**
- **checksec 2.6.0 colours unconditionally** — it ignores both `NO_COLOR` and
  `TERM=dumb`. radare2 writes progress escapes to *stderr* even with `scr.color=0`.
- **`xxd` is not part of a base install** (it ships in vim-common). Depending on
  it made the hex decoding sweep a silent no-op.
- **`python3 -m dis` cannot read a `.pyc`** — it treats the argument as source.
  Unmarshal the code object first; see `scripts/pyc_disasm.py`.
- **Ghidra is downloadable even where `github.com/.../releases/latest` returns
  403**, via `release-assets.githubusercontent.com`. See `.claude/cloud-setup.sh`.
- **`SIGINT` cannot be trapped when revctf is backgrounded from a non-interactive
  shell.** POSIX requires such jobs to ignore it and bash will not install a trap
  for a signal ignored on entry (`SigIgn: …6` in `/proc/<pid>/status`). Not
  fixable in bash. `SIGTERM` is trapped and takes the identical path; `--help`
  says so. **Do not "fix" this — it has been investigated.**
- **`wait` inside `$( )` cannot reap the parent's child** and returns -1.

---

## 6. The build environment

**As of M5 the build environment is the VirtualBox Kali VM** (`jijo`), measured 2026-08-20:

```
RAM      3917 MB (Tier A, by 26 MB), swap 5049 MB     CPUs 3
systemd  booted; systemd-run --user --scope WORKS     cgroup v2 yes
Docker   28.5.2, daemon RUNNING, overlay2, cgroup v2     (M6 UNBLOCKED)
Distro   Kali GNU/Linux Rolling, kernel 7.0.12+kali-amd64
Toolchain  complete after install.sh: floss 3.1.1, shellcheck 0.11.0, GNU time,
           Ghidra pinned to 11.2.x (12.1.3 breaks the post-script — see CLAUDE.md §3)
```

Note how narrowly the reference host makes Tier A: a VM configured with 4096MB reports
3917MB after firmware reservations, 26MB above the 3891MB boundary. A slightly greedier
firmware would silently drop it to Tier B.

**Two Docker access traps, both of which make a working daemon look broken.** Both were hit
on 2026-08-20 and cost real time:

1. **`DOCKER_HOST` may point at a stale podman socket.** In this session it was
   `unix:///run/user/1000/podman/podman.sock`, which does not exist, so every `docker`
   command failed with *"Is the docker daemon running?"* while `dockerd` was active the
   whole time. It comes from the inherited process environment, not from any dotfile —
   `grep DOCKER_HOST ~/.bashrc ~/.zshrc ~/.profile /etc/environment` finds nothing.
   `env -u DOCKER_HOST docker ...` is the check.
2. **Group membership is per-process and does not apply retroactively.** `jijo` is in the
   `docker` group in `/etc/group`, but a shell started *before* that change does not have
   it, and `/var/run/docker.sock` is `root:docker 0660` — so it fails with *permission
   denied* even though a fresh login works fine. `sg docker -c '...'` gets the group without
   re-logging-in.

So: if Docker appears broken, verify with
`sg docker -c "env -u DOCKER_HOST docker info"` before concluding anything. **Do not
re-diagnose this as "the daemon is not running".**

The cloud sandbox described below is **historical** — it is what M0–M4 were built in, and
what every pre-M5 measurement came from:

```
RAM      8023 MB, swap 0 MB       CPUs    2
Docker   binary present, daemon NOT running
systemd  systemd-run present, systemd NOT booted (PID 1 = process_api)
TTY      none on stdout
Distro   Ubuntu 24.04.4 LTS
Disk     252 GB
Ghidra   11.2.1 at /opt/ghidra_11.2.1_PUBLIC
```

**What that blocks, and why it forces a move at M5:**

| Milestone need | Blocker |
|---|---|
| Tier B (2.5–3.8 GB) and Tier C (<2.5 GB) paths | 8 GB fixed → **Tier A only**. Faking the RAM read tests the branch, not the behaviour |
| `systemd-run --scope -p MemoryMax` (v4's preferred bounding) | systemd not booted; the primary path has **never once executed**. Everything falls to the `ulimit -v` fallback |
| ~~Swap offer~~ | **Removed** (D10) — replaced by a diagnostic; revctf never modifies the host |
| Tier concurrency (`jobs_light=4` at Tier A) | **2 CPUs** — every concurrency timing here is taken under 2× oversubscription |
| M6 Docker sandbox (`--network=none --read-only --cap-drop=ALL`) | *(cloud sandbox only)* daemon not running, and with no systemd unlikely to start. **On the Kali VM this is resolved** |
| M8 interactive prompts; M4 TUI redraw / SIGWINCH | **no TTY** |
| `install.sh` on its target platform | not Kali; version parity so far has been luck |

Also: **the sandbox is ephemeral** — reclaimed after inactivity, taking the repo
with it. That is why the GitHub push is urgent (§8).

---

## 7. Measurements taken so far

On the 220 MB stress blob, after M3 optimisation:
**> 600 s and 1.46 GB peak → ~80 s and 103 MB peak.**

| Finding | Number | Consequence |
|---|---|---|
| radare2 `aaa` was run 6× (once per query) | 195 s + an OOM kill → 0 s with one session | Fixed in M3 |
| **FLOSS peak RSS** | **~1.46 GB** | **Disproves v6 §5.** It exceeds Tier A's 1024M and is ~3× Tier C's. M5 must size Phase 2 from *this*, not from Ghidra's ceiling. `FLOSS_MAX_MB=64` is the interim guard |
| Ctrl+C latency before `st_run_bounded` | 77 s, 2 orphans → 8 s, 0 orphans | Fixed in the QA pass |
| Triage on a 220 MB target | 2 s → 0 s (4 KB marker scan before `upx -t`) | Fixed in the QA pass |
| Realistic target (15 KB crackme, all 13 stages incl. Ghidra) | ~15 s | Baseline |

Caveat: all of the above were measured on 2 CPUs / 8 GB in the cloud sandbox.

### Re-measured on the Kali VM at M5 (these are the numbers that matter)

| Measurement | Result | Consequence |
|---|---|---|
| **FLOSS, 264KB PE, all modes** | **899MB** | **The decisive number.** FLOSS's cost is vivisect's emulation workspace, *not* file size. `FLOSS_MAX_MB=64` gates on size, so it never bounded memory at all — a 264KB PE is 250x under the gate |
| FLOSS, 264KB PE, `--only static` | 100MB | Why Tier C degrades to static-only rather than being OOM-killed on every PE |
| FLOSS, 210MB blob, all modes | 1460MB | Reproduces the sandbox's 1.46GB exactly |
| `ulimit -v` at any tier ceiling | **JVM will not start** | A JVM needs 2–4GB of *virtual* size; the documented fallback would have destroyed the Ghidra stage on every non-systemd host |
| `systemd-run --scope` | works; OOM → 137; `--collect` required | The primary bounding path, executing for the first time |

Phase-2 ceilings derived from these: **Tier A 1536MB, B 1024MB, C 512MB** (deviation D11).
Full detail in `implementation-notes.md` under "M5 — host measurements".

---

## 8. Where the code lives, and the GitHub situation

| Location | State |
|---|---|
| GitHub `JijoShibu/revctf` (private) | **Authoritative.** Branch `main`, tags `v0.2-m2-qa` and `v0.1-mvp` |
| Cloud sandbox `/home/claude/work/revctf` | Working copy through M4. Ephemeral |
| Device `D:\RevCTF\revctf-repo` | The pushed clone. `D:\RevCTF\revctf` was the stale pre-push copy |
| Device `D:\RevCTF\` | Also holds the v3–v6 masterplans and the execution masterplan |


**I cannot push from the sandbox.** Re-verified 2026-08-18 rather than assumed:
the `GH_TOKEN` is a 14-char proxy token with **empty `X-OAuth-Scopes`** and
`allows_permissionless_access=true`. It resolves `/user` to `JijoShibu` but
`/user/repos` returns nothing and every `git ls-remote`/push is rejected
(`Invalid username or token`). `gh` is not installed, SSH egress is blocked, and
`device_bash` has no network. Delivery is therefore **git bundle → user pushes**;
see `PUSH-RUNBOOK.md`.

Also noted: the device mount **cannot unlink** files (`Operation not permitted`),
so a stale `.git/index.lock` there can only be removed from Windows itself, and
anything I "delete" on the device is really `mv`-ed into `_to_delete/`.

---

## 9. Windows / WSL traps — read before the migration

The user's machine is Windows (`D:\RevCTF` connected, GitHub Desktop and
Claude Code in PowerShell installed, VirtualBox present, **no WSL yet**).

- **Do not develop this in PowerShell.** revctf traces ELF binaries. Native
  Windows gives no `ltrace`, no `strace`, no `radare2` against ELF, no `setsid`,
  no process-group semantics, no `ulimit -f`/`SIGXFSZ`, no POSIX permission bits.
  The correct configuration is **WSL2 running Kali with Claude Code launched
  inside the WSL shell**. VirtualBox + a Kali VM is an equally valid alternative
  and is already installed.
- **CRLF kills every script.** A `.sh` with CRLF fails as `bad interpreter: No
  such file or directory`. Fixed at the source: the repo now carries
  `.gitattributes` with `* text=auto eol=lf`, which overrides any global
  `core.autocrlf`. Do not remove it.
- **Keep the repo in the Linux filesystem** (`~/revctf`), **never** under
  `/mnt/c` or `/mnt/d`. NTFS cannot hold the `0600` capture and `0700` directory
  modes that v4 §5 requires and QA-9/QA-10 specifically fixed — tests would pass
  while the guarantee was void.
- **Never run `install.sh` from PowerShell or Git Bash.** It targets
  Debian-derived Linux and will fail partway, leaving a half-configured tree.

---

## 10. The agreed plan

Decided 2026-08-18 after comparing environments:

1. ~~Push to GitHub.~~ **Done** — 14 commits, private repo, verified.
2. ~~Build M4 in this cloud session.~~ **Done** — `v0.1-mvp`. One task remains on the
   user's side: run `tools/tui-selftest.sh` on a real terminal, since no automated check
   can see a corrupted redraw or a hidden cursor.
3. **Cut over at M5** to Claude Code inside WSL Kali (or the VirtualBox Kali VM).
   From M5 the work *is* the host — tiers, `systemd-run`, swap, Docker, TTY
   prompts. Continuing in the cloud past M4 means writing code against an
   environment that cannot contradict it.
4. **Optionally return to the cloud for M7's long batch runs** — but only after M5 lands,
   since M7 needs tier-driven concurrency values. Long unattended runs over the corpus are
   the one thing this environment does better than a laptop.

**As of `bd2927b` there is no remaining milestone work this environment can verify.**
*(Written before the M5 cutover; kept for context.)* Every path after M4 is either
host-bound (M5 needs systemd, M6 needs Docker, M8 needs a
TTY) or blocked behind one that is. Building M5's enforcement here would mean shipping the
`systemd-run` primary path with no behavioural check — which is precisely the defect class
QA review #2 closed, in a new costume.

Handoff cost is deliberately low: `CLAUDE.md`, `implementation-notes.md`,
`CHECKLIST.md` and this file were written for cold starts. A fresh Claude Code
session reads them and is current. Migration is not a restart.

---

## 11. Open questions carried forward

- ~~**M5 must NOT inherit Ghidra's ceiling for Phase 2**~~ — **RESOLVED at M5 (D11).**
  Sized from measurement: 1536/1024/512MB. The 264KB-PE figure (899MB) mattered more than
  the 1.46GB one, because it showed the cost is emulation rather than file size.
- **`packed_upx_broken` no longer forces a stage failure.** upx 4.2.4 unpacks the PIE ELF
  that 4.2.2 could not, and six harness checks (`--strict`, exit-2, the unwrap diagnostic)
  depended on that fixture failing. They need a version-independent way to induce a stage
  failure. This is harness fragility, not a product defect.
- **Tier A's `-P 2` cannot afford two concurrent Phase-2 jobs** — 2x1536MB against ~2946MB
  usable. Phase-2 concurrency must be decoupled from Phase-3 concurrency when M7 lands.
  Recorded in D11 rather than fixed, because single-file mode is sequential.
- **Tier boundaries 3.8 GB / 2.5 GB are unvalidated estimates** (v4 §10). The
  Jython version boundary was an estimate too, and it was wrong. Treat these the
  same way once M5 can measure them.
- **The 1800 s Ghidra time bound (v6 §7.4) is a guess** — no prior masterplan
  bounded Ghidra by time at all. Test against a slow-path binary.
- **The TUI is the highest-defect-density component** — redraw, resize and signals
  in Bash. Isolated behind the `--no-tui` fallback.
- **Archive members are extracted into `TRIAGE_MEMBERS` but not analysed
  individually.** That orchestration belongs with batch mode (M7).
- **Deviation D7** (missing optional tool = hard error) is applied in two tiers:
  core tools fail at startup, format-conditional decompilers fail lazily. Flagged
  for review.
- **Polyglot targets** (packed *and* archive) route down one path only; the depth
  cap bounds the damage.
- **`pyinstxtractor` is not packaged** — PyInstaller extraction fails cleanly with
  an install hint. `install.sh` should vendor it in M6.
- **Resolved (D9):** `--sandbox` covers `strace` as well as `ltrace`, and refuses
  the host until M6 builds the container.

---

## 12. How to work

```bash
./tools/build-test-corpus.sh              # 18 artifacts; needs gcc, mingw, JDK, zip, upx, python3
./tools/run-tests.sh                      # 157 checks (~15 min)
./tools/run-tests.sh m3 qa                # just those sections
REVCTF_TEST_FAST=1 ./tools/run-tests.sh   # skip the 220 MB checks (~3 min)
```

The `ghidra` section self-skips when no Ghidra is installed, so the harness stays
useful anywhere. `PF_OPT_ROOT_REAL=/opt` points it at a real install.

**Every milestone:** implement → harness green → append a section to
`implementation-notes.md` → update `CHECKLIST.md` → commit. Do not advance past a
Definition-of-Done gate until its verification actually runs. Each milestone adds
its own harness section so earlier gates keep being re-checked.
