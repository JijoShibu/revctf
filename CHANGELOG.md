# Changelog

All notable changes to `revctf`. Milestones refer to `revctf_executionmasterplan.md`;
section references (v3 §8, v5 §4.1, v6 §11) point at the design documents.

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
