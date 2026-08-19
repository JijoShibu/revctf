# Changelog

All notable changes to `revctf`. Milestones refer to `revctf_executionmasterplan.md`;
section references (v3 §8, v5 §4.1, v6 §11) point at the design documents.

---

## [Unreleased] — pre-M5 groundwork

Work done in the cloud session before handing development to a Linux host at M5.

### Fixed

- **`--dry-run` was parsed and then ignored.** It set `OPT[dry_run]=1`, nothing ever read
  it, and the scan ran in full — so a flag the README recommends *before committing to a
  large batch* silently performed the 78-second scan it was meant to preview. It now
  prints the resolved plan and returns before the stage modules are even sourced: no work
  directory, no output directory, no tool launched.
- A missing tool no longer suppresses the plan. A hard error is correct for a real scan
  (D7), but refusing to answer "would this run, and how?" because a tool is absent defeats
  the flag. `--dry-run` reports the preflight verdict as a line in the plan instead.

### Added

- **`lib/tier.sh`** — RAM detection (`free -m`, `/proc/meminfo` fallback), Tier A/B/C
  resolution, Tier C's automatic `--light-decompile` with `--force-full-decompile`
  override, and the `--jobs-*`/`--maxmem-ghidra` overrides. The table is v6 §5 unchanged;
  every constant is named and grouped so moving a boundary is a one-line change.
  **The numbers are still unmeasured** — v4 §10 flags them as estimates, and the plan says
  so rather than presenting them as settled.
- **`REVCTF_RAM_MB`** injects a RAM figure so tier *branch* logic can be tested on any
  machine. Every report labels an injected value as injected: a tier chosen from a fake
  number must never look like a measurement.
- **`tools/measure-host.sh`** — captures what M5's constants must be derived from on the
  real host: RAM/CPU/swap, whether `systemd-run` actually works, toolchain versions, stage
  timings, and FLOSS peak RSS with `FLOSS_MAX_MB` lifted.
- **`tools/bootstrap-kali.sh`** — one-shot Kali/WSL setup. Explicitly a stopgap until
  `install.sh` is completed; installs FLOSS via a venv because the `pip
  --break-system-packages` line install.sh still carries is known to fail.
- **`m5` harness section** — 52 checks covering both sides of every tier boundary, the
  injection labelling, Tier C routing, overrides, and that `--dry-run` creates nothing.
- **`CLAUDE.md` §3b** — the WSL/Kali facts: `systemd=true` in `/etc/wsl.conf` (without it
  M5's primary memory path cannot work), `.wslconfig` as the Tier C rig, the ext4-not-/mnt
  rule, and `setsid` rather than `nohup` for background harness runs.

### QA review #2 — the defect class behind both

`--dry-run` and `install.sh` are the same defect: **documented behaviour with no executing
code**, invisible to 188 passing checks because every check tested behaviour someone had
already thought to implement. Nothing tested the inverse. Auditing all 28 flags found
**five more**: `--debug`, `--interactive`, `--yes`, `~/.revctf/error.log`, and the RSS
watchdog / swap offer — all described by README in the present tense, none implemented.

Contributing cause: README was written early from the design documents, describing the
finished v1.0 tool, and has since been maintained only at its status banner.

- **`--help` marks every unfinished flag** `[NOT YET: Mn]` or `[PARTIAL: Mn]`.
- **README carries a "What is not in this build" table** and no longer claims absent
  behaviour in the present tense.
- **New `docs` harness section** — 10 checks that close the class rather than the
  instances. A flag now has two legal states: implemented *and named in the harness*, or
  marked unfinished *in both documents*. There is no third state where it quietly does
  nothing. Also asserts that no placeholder function is called from the entry script.

Full analysis, including the alignment review and the standing rules, in `QA-REVIEW-2.md`.

### Known, unfixed

- **`install.sh` installs nothing.** Its whole dependency block is commented out, while
  README calls it mandatory and preflight tells users to re-run it when a tool is missing —
  a closed loop. Deferred deliberately to the first Claude Code session, where it can be
  written and tested against real Kali in one loop.
- v6 §5's Phase-2 ceiling derivation remains disproved by the measured FLOSS peak
  (~1.46GB). `lib/tier.sh` implements it as written and states the gap in every plan
  rather than inventing a replacement number without measuring.

---

## [v0.1-mvp / M4] — Report assembly, display layer, config extraction

**The MVP gate.** revctf now does end to end what it exists to do: point it at a
challenge file and get back a readable report with the flag at the top.

### Added

- **`lib/report.sh`** — the report. Flags first (v6 §6.1), then a stage table, then
  per-stage detail with a beginner blurb explaining *why you are looking at this*, then
  diagnostics for anything that failed, then a next-steps block derived from what actually
  happened on this file rather than a static checklist. Written to
  `<output>/report.txt` at `0600` and mirrored to stdout from one code path — two
  formatters would drift.
- **`lib/tui.sh`** — three display modes, chosen once at startup: an in-place table when
  both streams are terminals, one line per transition with `--no-tui`, and a periodic
  heartbeat when stdout is redirected. **All progress goes to stderr**, so
  `revctf scan x > report.txt` yields a clean file while the user still sees movement.
  `SIGWINCH` re-measures the width, and rows are truncated rather than wrapped — a wrapped
  row occupies two terminal lines and corrupts the cursor rewind.
- **`lib/config.sh`** — the config loader and key registry, extracted from the entry
  script. It is the single place an untrusted external value enters `OPT`, which is
  exactly the boundary QA-1 broke; one auditable file beats coercion scattered through a
  700-line script. `summary_only` joins the allowlist.
- **`--summary-only`** wired through: keeps the header, flags and stage table, drops
  per-stage detail, and says so rather than leaving the reader wondering.
- **`tools/tui-selftest.sh`** — six interactive checks the automated harness cannot make,
  because it has never had a controlling terminal: in-place redraw, **resize during a run**,
  Ctrl+C latency and cursor state, narrow-terminal truncation, redirection cleanliness, and
  whether the report reads as intended. Run once on a real terminal.
- **`m4` harness section** — 30 checks, plus one added to `qa`. Total suite: **188 checks**.

### Fixed

- The M3 interim summary reported fabricated `0s` for the flag scan and had no way to show
  a failed stage's command or stderr. Both are now in the diagnostics block.

### Fixed — in the harness

- The `qa` timing check parsed the stage table's third column as a bare number. M4 prints
  the unit (`73s`), so it hit an arithmetic test with a non-numeric word — the same class
  of defect as QA-1, in the harness this time.
- The SIGHUP check reported a phantom regression when the harness was launched under
  `nohup`, which sets SIGHUP to SIG_IGN for every descendant; bash then refuses to install
  the trap, the same POSIX rule already documented for SIGINT. The check now reads
  `SigIgn` from `/proc/self/status` and skips itself with a reason, and keeps revctf's
  stderr so a failure carries evidence.

### Notes

Ghidra, the TUI and the report were exercised together on the corpus crackme: 14 stages,
`flag{cr4ckm3_s0lv3d}` recovered at high confidence, report byte-identical on stdout and
on disk. A stage forced to time out produces a diagnostics entry naming the command and
exit code, and the run exits 2 as designed.

---

## [M3] — Heavy stages, decompilers and flag detection

All 13 stages plus the flag scan run end to end. On the corpus crackme, Ghidra recovers
the password `sw0rdf1sh` from the pseudo-C — verified against a real 11.2.1 install.

### Added

- **Dynamic stages** — `ltrace` (stage 7) and `strace`+`ldd` (stage 9), sharing
  `lib/stage_dynamic.sh`: `setsid` process-group isolation, closed stdin, a timeout, and
  an orphan sweep afterwards. Both execute the challenge binary, so every capture they
  produce opens with an unmissable statement of that fact and of what isolation applied.
- **`radare2`** (stage 8) — one analysis session, `\bmain\b` word boundary with an
  `entry0` fallback, reduced analysis depth above `R2_DEEP_MAX_MB`.
- **FLOSS** (stage 10) — format-aware: all modes on PE, `--only static` on ELF, because
  stack/tight/decoded extraction is PE-only. The report states which applied, so a missing
  flag never reads as a clean negative.
- **Managed and Python decompilation** (stages 11–12) — Java via jd-cli/procyon/cfr, .NET
  via ilspycmd/monodis, Python via pycdc/uncompyle6 with `scripts/pyc_disasm.py` as an
  always-available fallback.
- **Ghidra headless** (stage 13) — runtime-appropriate post-script, throwaway project with
  `-deleteProject`, and OOM self-heal that retries once with light decompilation.
- **`lib/flagscan.sh`** — tiered confidence, cross-stage attribution, and the encoding
  sweep (base64/base32/hex/ROT13). Verified end to end against the corpus.
- **`--skip-strace`**, for symmetry with `--skip-ltrace`.
- **`REVCTF_TEST_FAST=1`** skips the large-target checks; the full suite now takes ~15 min.

### Changed

- **Deviation D9: `--sandbox` covers strace as well as ltrace.** v5 §3 scopes it to ltrace,
  which predates the strace stage. Until M6 builds the container, `--sandbox` *refuses* to
  run either stage rather than silently falling back to the host.
- Stage timings, output caps and ANSI stripping now also apply to stderr captures, since
  M9 quotes stderr tails into the report.

### Fixed

- `radare2` rejects the `--` end-of-options marker — it analysed nothing, so **every**
  binary looked stripped and every disassembly used the entry0 fallback.
- The Jython post-script needs a PEP 263 encoding declaration; without it Ghidra produced
  an empty stage while still exiting 0.
- `python3 -m dis` cannot read a `.pyc` — it treats the argument as source.
- The hex encoding sweep was a silent no-op: `xxd` is not part of a base install.
- Flags were listed worst-first (high/medium/low sorts backwards alphabetically).
- Decoded streams produced mirror noise; decoded text now requires a known format.

### Performance

Measured on the 220MB stress blob: **>600s and 1.46GB peak → ~80s and 103MB peak.**

- `radare2`'s `aaa` was being run six times, once per query — 195s and an OOM kill. One
  session now: 195s+ → 0s.
- **FLOSS peaks at ~1.46GB** on that target and is Phase 2's largest consumer by an order
  of magnitude. This **disproves v6 §5's assumption** that Phase 2 can inherit Ghidra's
  ceiling — FLOSS alone exceeds Tier A's 1024M and is ~3x Tier C's. M5 must size Phase 2
  from this measurement. `FLOSS_MAX_MB` (64MB) keeps it inside every tier meanwhile.

A realistic target is unaffected: a 15KB crackme runs all 13 stages, Ghidra included, in
about 15 seconds.

---

## [v0.2-m2-qa] — M2 complete, QA pass applied

A stability checkpoint, not a feature release. Everything through M2 is built, the
pre-M3 QA review is closed, and the verification harness runs **127 checks, all green**
across three consecutive runs with no residue.

This is the known-good rollback point before M3 begins changing the stage framework.

### Fixed — QA review (16 defects, all reproduced against a live build)

Full detail with reproductions in `QA-REVIEW.md`.

**Critical**

- A config value written as a word — `full_hexdump = on` — aborted the shell **from inside
  a stage**. Ten config booleans are consumed in `[[ … -eq 1 ]]`, which is arithmetic
  context, where `set -u` treats a non-numeric word as a variable name and exits outright.
  `stage_run`'s error boundary cannot catch that, so the isolate-and-continue guarantee
  (v5 §4.1) was silently void. Config values are now coerced and validated before they can
  reach an arithmetic test; invalid ones warn and fall back to the default.

**High**

- No `EXIT` trap: any exit path that skipped `stage_end_file` stranded the work directory.
- A container holding a UPX-packed member was itself declared packed, aborting extraction
  and reporting a plain tar as an unreadable packed binary. Packer detection now skips
  containers entirely and scans only the 4KB stub and trailer.
- `Ctrl+C` was ignored for ~77 s and left the running tool orphaned — bash defers a trap
  until the foreground command finishes. Every external tool now launches through
  `st_run_bounded`, which backgrounds it and `wait`s (interruptible), recording the child
  PID so the handler can kill it. Measured 77 s → 8 s, zero orphans.
- FIFOs and character devices were accepted and then hung the scan; `/dev/zero` wedged a
  run for the full 300 s `strings` timeout. Non-regular targets are now rejected up front,
  naming what they are.
- Archive extraction was unbounded: a 1 MB zip wrote 1 GB into the work directory. Now
  bounded by declared expansion (`TRIAGE_MAX_EXPAND_KB`, default 2 GB) and by free space.
- Stage timings were fabricated. `STAGE_SECS` was written only by `stage_capture`, so every
  stage running its own tool reported `0s` behind a `:-0` default — a 72-second binwalk
  looked instant. Timing moved to `stage_run`, the boundary every stage passes through.
- A failed PyInstaller unwrap left `RUN_FORMAT=pyinstaller`, silently skipping the native
  pipeline while the stage still reported `ok`. The format now changes only after a
  *successful* unwrap; failure keeps the native format and marks the stage failed.

**Medium and low**

- Captures were `0644` from the umask; v4 §5 requires `0600`. A scoped `umask 077` fixes it.
- revctf ran `chmod 700` on a **pre-existing** `--output` directory, which would lock other
  users out of a shared location. `0700` is now applied only to a directory revctf creates.
- `SIGHUP` was untrapped, so a dropped SSH session killed the scan with no cleanup.
- Mach-O universal binaries share magic `0xCAFEBABE` with Java `.class` and were routed to
  the Java decompiler. Now disambiguated via `file(1)`, with the other Mach-O magics added.
- Every scan exited `0`, so nothing could distinguish a clean run from one where every
  stage failed. See *Exit status* below.
- An unwritable output directory produced seven misleading per-stage errors instead of
  naming the real cause.
- `output_dir = ~/ctf/reports` — the README's own example — created a directory literally
  named `~`. Tilde is now expanded on config load.
- The upx diagnostic extractor used `[^\n]`, which in a POSIX ERE means "not backslash, not
  the letter n". It truncated the very message it existed to preserve.
- `stage_triage` ran every classification probe unbounded (`file`, `rabin2`, a whole-file
  `strings`, `7z l`, `upx -t`) despite v6 §7.4 bounding every other stage.
- A dead `elif` branch in the PyInstaller unwrap swallowed the extractor's real exit status.

### Added

- **`--strict`** — stop at the first failed stage instead of continuing. The default is
  unchanged (v5 §4.1 isolate-and-continue); `--strict` is for scripted use where a partial
  report is worse than an early exit. New flag beyond v5 §6's surface, logged as **D8** in
  the v6 Deviation Register.
- **Per-stage output size cap** (`ST_MAX_OUT_KB`, default 2 GB). Time bounds never bounded
  disk: a stage staying under its timeout could still write until the filesystem filled.
  Enforced with `ulimit -f`, so the kernel stops the write rather than a polling loop. A
  stage that hits it is reported as truncated and its partial capture is kept.
- **Exit status is now meaningful**, and documented in `--help`:
  `0` clean · `2` completed with stage failures (or stopped by `--strict`) ·
  `1` could not run · `128+N` aborted by signal (130 INT, 143 TERM, 129 HUP).
- **`qa` section in the verification harness** — 32 checks pinning every finding above, so
  none can regress. Total suite: **127 checks**.

### Changed

- Abort exit codes are signal-specific (`128+N`) rather than a flat `130`.
- `rc 137` is no longer reported as a timeout: it is equally the OOM killer's signal, and
  the message now says so rather than asserting something that may not have happened.
- Packer detection order reversed for performance — the O(1) 4 KB marker scan runs first
  and `upx -t`, which reads and decompresses the whole file, only when a marker is present.
  Triage on a 220 MB target: 2 s → 0 s.

### Documented

- **`SIGINT` cannot be trapped when revctf is backgrounded from a non-interactive shell.**
  POSIX requires the shell to set it to ignored for such jobs, and bash will not install a
  trap for a signal ignored on entry (`SigIgn: …6` in `/proc/<pid>/status`). Not fixable
  from inside bash. `SIGTERM` is trapped and takes the identical path; `--help` says so.
- **The flag scan must use `grep -E` and never a PCRE engine.** `--flag-format` takes a
  regex from the user and the scan runs it over megabytes of capture; a backtracking engine
  makes that a self-inflicted denial of service. Documented as a hard constraint in
  `lib/flagscan.sh`, and asserted by the harness, which fails if any PCRE flag appears in
  `lib/`.

### Known limitations at this checkpoint

- Batch mode is not implemented (M7). A directory target exits 1 with a clear message.
- Archive members are extracted and listed but not yet analysed individually — that
  orchestration belongs with batch mode.
- Stages 7–13 (ltrace, strace, FLOSS, radare2, Ghidra, the decompilers) and the flag scan
  are M3; the report and TUI are M4.
- `pyinstxtractor` is not packaged, so PyInstaller extraction fails cleanly with an install
  hint. `install.sh` should vendor it in M6.

---

## [M2] — Stage framework, triage/unwrap, light static stages

- `lib/stage.sh`: the per-stage contract the execution masterplan calls load-bearing — run
  context, streaming capture with split stderr, per-stage error boundary, v6 §7.4 time
  bounds. Only the framework writes the shared `STAGE_*` state.
- `lib/stage_triage.sh` (Stage 0, deviation D3): classifies ELF/PE/Mach-O/.NET/Java/pyc/
  PyInstaller/archive, unpacks UPX, extracts containers, and repoints the pipeline at the
  real payload. The original file is never modified.
- Stages: `file`, `strings`, `binwalk` (numeric major-version branch with output validation
  and raw-capture fallback), `hexdump`, `checksec`+`rabin2`, `objdump`/`readelf`.
- Found and worked around: binwalk 2.x and upx reject `--`; checksec colours
  unconditionally, ignoring `NO_COLOR`.

## [M1] — Preflight and dependency detection

- Two-tier tool registry: core seven and always-needed tools hard-fail at startup;
  format-conditional decompilers fail lazily when a target routes to them.
- Ghidra discovery across `PATH`, `GHIDRA_HOME` and `PF_OPT_ROOT`, newest install winning.
- **Corrected a design error:** v3 §1's "Ghidra 11.x+ → PyGhidra" boundary is wrong. A
  probe against a real 11.2.1 install reports `python_version=2.7.3` — it still bundles
  Jython. PyGhidra became the default in **11.3**. Runtime is now detected by probing
  `Ghidra/Features/{PyGhidra,Jython}`, with the version comparison only as a fallback.
- binwalk version detection via three strategies, numeric major comparison only.
- `systemd-run` probed for real usability, not merely located.

## [M0] — Foundation and scaffolding

- Entry script with the full flag surface, conflict validation, symlink-safe root
  detection, and `~/.revctf/config` with defaults → config → flags precedence.
- `tools/build-test-corpus.sh`: 18 verified artifacts across four groups.
- `tools/run-tests.sh`: the milestone-gate verification harness.
