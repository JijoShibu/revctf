# QA Review #2 — pre-M5

**Scope:** everything built between M0 and the pre-M5 groundwork, with the `install.sh`
and `--dry-run` defects as the entry point. **Method:** every finding below was reproduced
against a live build; none is inferred from reading code.

**Verdict: the tool does what it was built to do, and the defects found are not coding
errors — they are a single verification gap that let seven documented features ship with
no implementation behind them.** One structural simplification is recommended. The
milestone plan is sound; the milestone *gates* were not measuring the right thing.

---

## 1. The two reported defects, and what they actually are

### D-1 `install.sh` installs nothing

```
$ sudo ./install.sh
warning: dependency installation is a stub (lands in M1); skipping
```

Every line of the dependency block is commented out. Meanwhile `README.md` said
*"`install.sh` is not optional. It installs the complete toolchain"*, and preflight tells a
user with a missing tool to **"re-run it (while online)"** — a closed loop pointing at a
script that installs nothing. It is the first command anyone runs on a fresh Kali.

It also carries a line already known to be wrong. `CLAUDE.md` §3 records that
`flare-floss` cannot be pip-installed system-wide on modern Debian/Ubuntu — its `halo`
dependency dies with `AttributeError: install_layout`. The commented line is
`pip install --break-system-packages "${PIP_EXTRA[@]}"`. So even uncommenting it would
fail: the correction was recorded in the notes and never propagated to the installer.

### D-2 `--dry-run` ran the full scan

```
$ revctf scan ./crackme --dry-run     # ran 14 stages, wrote a report, exited 0
```

The flag parsed, set `OPT[dry_run]=1`, and was never read again — the short-circuit existed
only as a comment. `README.md` documented it as *"show plan, run nothing"* and recommended
it before committing to a large batch. On a 220MB target that is a 78-second scan instead
of the preview requested.

### These are the same defect

Neither is a logic error. In both cases the code was **absent**, the documentation said it
was **present**, and 188 passing checks had nothing to say about it.

---

## 2. Root cause

**The verification harness tested the behaviour that existed. Nothing tested whether the
behaviour we promised existed.**

Every check was written by someone who had just implemented a feature and was pinning it.
That catches regressions perfectly and cannot, even in principle, catch an omission. The
gates compounded it:

| Milestone | What its gate checked | What it did not |
|---|---|---|
| M0 | "full 25-flag CLI surface with conflict validation" | that any flag *does* something |
| M1 | preflight detects tools and gives the right advice | that `install.sh` can install them |

M0's gate is satisfied by a flag that parses and is ignored — which is exactly what
`--dry-run` was. M1's gate is about the *registry*, so `install.sh` was never in its scope,
yet its own header claims M1 completed it.

The second contributing cause is documentation drift. `README.md` was written early from
the design documents, describing the **finished v1.0 tool**, and has since been maintained
only at its status banner. Every milestone updated the banner; nobody re-read the body
against the build.

---

## 3. The rest of the class — audit results

Having identified the pattern, I audited all 28 flags and every README claim rather than
fixing only the two reported. **Five more of the same defect were found**, all reproduced:

| Feature | README said | Reality |
|---|---|---|
| `--debug` | "full command trace to `<output>/<name>.debug.log`" | no debug log is produced |
| `--interactive` / `-i` | "pause before each stage: Continue / Skip stage / Skip file / Abort" | never prompts; runs straight through |
| `--yes` / `-y` | "auto-accept every prompt; makes CI runs unhangable" | vacuous — there are no prompts |
| `~/.revctf/error.log` | "every stage failure across every run, `600`, rotated at 5MB" | never created |
| RSS watchdog, swap offer | described in the present tense as active | `watchdog_start` / `swap_ensure` are 12-line stubs, never called |

`--jobs-light`, `--jobs-ghidra` and `--maxmem-ghidra` are a milder case: they are now
resolved and reported by `--dry-run`, but nothing enforces them during a scan yet.

**Seven documented features with no implementation. That is the finding — not two.**

### What was checked and found sound

- No placeholder function is called in earnest from the entry script. The five remaining
  stubs (`errorlog`, `prompt`, `spinner`, `swap`, `watchdog`) are unreferenced, so nothing
  silently no-ops mid-run. Now asserted.
- `lib/stage_strings.sh` is 12 lines but is **not** a stub — it is a genuinely small
  working stage. A line-count heuristic flags it; the implemented check greps for the
  placeholder text instead.
- The core pipeline does what it claims: 14 stages, flags first, `flag{cr4ckm3_s0lv3d}`
  recovered at high confidence in ~15 s on the corpus crackme.
- Every QA-1…QA-16 fix from the first review still holds; the `qa` section re-runs on every
  invocation.

---

## 4. Alignment with the original goal

> *Ingest a reverse-engineering CTF challenge file, run an automated Kali toolchain, emit a
> beginner-friendly plain-text report with flag candidates at the top.*

**On target.** The report opens with the flags, each stage carries a plain-English note on
why the reader is looking at it, failures are explained rather than hidden, and the output
is plain text everywhere. A 15 KB crackme is solved end to end in about fifteen seconds.

Three areas have grown beyond what the goal requires. Only one is worth acting on now.

### 4.1 The display layer is the clearest overcomplication

Three display modes and an in-place redrawing table, for a tool whose deliverable is a text
file. It is already flagged as the highest-defect-density component; it needs `SIGWINCH`
handling, cursor arithmetic, width measurement and truncation; and it is the one part of
the build that **cannot be verified by any automated check** — hence a separate manual
self-test script.

The line and heartbeat modes deliver essentially all of the user value: *which stage is
running, how long it has taken*. The in-place table adds polish to the fifteen seconds
before the report — the part nobody keeps.

**Recommendation: keep it, but freeze it.** It is written, it works, it is isolated behind
`--no-tui`. Spending further effort there is not justified by the goal. If it ever costs a
second debugging session, delete it and default to line mode — that would remove ~200 lines
and one whole class of platform-specific risk.

### 4.2 Auto-swap is outside the tool's remit

Creating a swap file and touching `/etc/fstab` is a system-administration action taken by a
tool whose job is to read a binary and write a report. The failure mode it prevents — an
OOM on a 2 GB box — is real, but the honest response is *"this host is too small for
Ghidra; use `--skip-ghidra`, or add swap yourself"*, which is one message rather than a
feature that mutates the system.

**Recommendation: replace M5's auto-swap with a diagnostic.** Detect low RAM with no swap,
say so plainly, name the two remedies, continue. `--no-auto-swap` then becomes unnecessary,
`lib/swap.sh` is deleted, and one flag leaves a 28-flag surface. If it is kept, it must
default to *off*.

### 4.3 The flag surface is large for a beginner's tool

28 flags. Seven are unimplemented, and several exist only to override an unmeasured tier
constant. This is a symptom rather than a problem in itself — the `[NOT YET]` markers now
make the real surface visible — but resist adding more before M5 measures whether the tier
overrides are needed at all.

### Not overcomplicated, despite appearances

The tier system, the three-phase model and `st_run_bounded` all look heavy for the goal,
and all earned their place with measurements: a 4 GB Kali VM is the stated target, FLOSS
peaks at 1.46 GB, radare2 was OOM-killed before the phases were separated, and a foreground
tool swallowed Ctrl+C for 77 seconds. Keep them.

---

## 5. What was fixed in this pass

- `--dry-run` implemented properly: prints target, size, output directory, config source,
  preflight verdict, resolved tier and limits, and exactly which stages would run and why
  not. Returns before the stage modules are sourced — no work directory, no output
  directory, no tool launched. Verified: nothing is created, and it returns in seconds.
- A missing tool no longer suppresses the plan. A hard error is correct for a real scan
  (D7), but refusing to answer *"would this run, and how?"* because a tool is absent
  defeats the flag; the verdict is a line in the plan instead.
- `--help` now marks every unfinished flag `[NOT YET: Mn]` or `[PARTIAL: Mn]`.
- `README.md` no longer describes absent behaviour in the present tense, and carries a
  **"What is not in this build"** table.
- **A `docs` harness section** — 10 checks that close the class rather than the instances.

`install.sh` was deliberately **not** fixed here: an installer that has never run against
the platform it targets is not really written. It is the first task on Kali, where each apt
group and download can be executed as it is written. Until then `README` says so, `--help`
says so, the harness asserts it says so, and `tools/bootstrap-kali.sh` covers the gap.

---

## 6. The rule that prevents recurrence

The `docs` section makes the failure mode structurally impossible. A flag now has exactly
**two legal states**:

1. **Implemented** — and named somewhere in `tools/run-tests.sh`, or
2. **Marked** `[NOT YET: Mn]` / `[PARTIAL: Mn]` in `--help` *and* listed in README.

There is no third state in which a flag quietly does nothing. The checks:

| Check | Prevents |
|---|---|
| every unmarked flag appears in the harness | `--dry-run`: a flag that parses and is ignored |
| `--help` markers ⊆ README | drift between the two documents |
| README carries no present-tense claim for absent behaviour | `--debug`, `error.log`, watchdog |
| `install.sh` either admits it is a stub or has a live install path | D-1 |
| README discloses that `install.sh` is a stub | the closed loop in the preflight advice |
| no placeholder function is called from the entry script | a stub silently no-oping mid-run |

---

## 7. Strict action plan

Ordered. Nothing below is optional, and each item names the check that proves it.

### Before writing any M5 code

| # | Action | Proof |
|---|---|---|
| 1 | Complete `install.sh` on real Kali — apt groups, **FLOSS via venv**, decompilers, Ghidra verification. Uncommenting is not enough; the pip line is known to fail. | `./tools/run-tests.sh docs` takes the "live package-install path" branch; a clean Kali reaches `revctf scan` with no manual apt |
| 2 | Remove the `install.sh` stub disclosure from README once (1) is true | `docs` section updated in the same commit |
| 3 | Run `./tools/tui-selftest.sh` on a real terminal | six manual checks pass; record the terminal and `TERM` in the notes |
| 4 | Run `./tools/measure-host.sh` | output pasted into `implementation-notes.md` |
| 5 | Enable `[boot] systemd=true` in `/etc/wsl.conf` | `measure-host.sh` reports `systemd-run: WORKS` |
| 6 | Decide the Phase-2 ceiling from (4), not from v6 §5 | the decision written into the Deviation Register |

### The rule for every milestone from here

1. **No feature is documented before it is implemented.** New flag → `[NOT YET: Mn]` in
   `--help` and the README table *in the same commit that adds the flag*.
2. **Every Definition of Done gets a behavioural check, not a structural one.** "The flag
   exists" is not a gate. "The flag changes what happens" is. M0's gate is the
   counter-example to keep in mind.
3. **A milestone is not complete while any file it names is a stub.** M1 claimed
   `install.sh`; `install.sh` is still inert.
4. **A finding recorded in `implementation-notes.md` must be applied everywhere it
   applies, in the same commit.** The FLOSS venv correction sat in the notes while the
   installer kept the failing pip line.
5. **Run the full suite before tagging, launched with `setsid`, never `nohup`** — `nohup`
   ignores SIGHUP for every descendant and produces a phantom signal-handling failure.
6. **Every milestone adds its own harness section**, and `docs` runs every time.

### Standing exit criteria for M5

- Correct tier on a ≥3.8 GB host **and** on a `.wslconfig`-forced 2 GB host.
- `systemd-run` path **actually executes** — it never has in this project.
- Watchdog fires on a memory-hungry target and does not false-fire on a normal Tier A run.
- Tier limits are **enforced**, not merely reported; the `[PARTIAL: M5]` markers come off
  in the same commit.
- Phase-2 ceiling derived from measurement, with the old derivation struck from v6 §5.

---

## 8. Summary

| | |
|---|---|
| Defects reported | 2 |
| Defects found of the same class | 7 |
| Root cause | verification tested what was built, never what was promised |
| Fixed this pass | `--dry-run`, `--help` markers, README alignment, `docs` section |
| Deliberately deferred | `install.sh` — belongs on Kali, disclosed everywhere meanwhile |
| Simplification recommended | drop auto-swap for a diagnostic; freeze the TUI |
| Goal alignment | on target; core pipeline solves the corpus crackme in ~15 s |
