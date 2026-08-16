# revctf — QA Review (pre-M3)

**Scope:** everything built through M2 — the entry script, the stage framework, preflight,
the Stage 0 triage/unwrap layer and the seven Phase-1 stages.
**Method:** adversarial black-box testing against a live build, plus an independent static
read of the source. Every finding below was *reproduced* against the real tool; nothing here
is inferred from reading code alone.
**Result:** 16 defects found. All 16 fixed. Harness went from 95 to **122 checks, all green**,
with a new `qa` section that pins every one of these so they cannot come back.

Run the evidence yourself:

```bash
./tools/build-test-corpus.sh
./tools/run-tests.sh qa
```

---

## Verdict

**Not ready to deploy before these fixes; ready to continue to M3 after them.**

The single most serious finding is QA-1: an ordinary config file could abort the shell
*inside a stage*, which silently broke the isolate-and-continue guarantee (v5 §4.1) that the
entire error-handling design rests on. Everything else was contained, but three findings
(QA-1, QA-8, QA-12) would each have produced a bad first impression on a real challenge.

Nothing found was a code-execution or injection vulnerability. Argument quoting is solid —
filenames containing `;`, `$(...)`, backticks, pipes, newlines and leading dashes were all
handled correctly, and the config file is parsed rather than sourced, so config values
cannot execute either.

---

## Findings

Severity is by *user impact on a real CTF challenge*, not by exploitability.

| # | Sev | Area | Finding |
|---|---|---|---|
| QA-1 | **Critical** | Error handling | A config boolean written as a word aborts the shell — from inside a stage |
| QA-2 | High | Fault tolerance | No `EXIT` trap: any early exit stranded the work directory |
| QA-3 | High | Functionality | A container holding a UPX-packed member was itself declared "packed" |
| QA-4 | High | Fault tolerance | `Ctrl+C` was ignored for ~77s, and left the running tool orphaned |
| QA-5 | High | Fault tolerance | FIFOs and character devices were accepted, then hung the scan |
| QA-6 | High | Performance | Archive extraction was unbounded: a 1MB zip wrote 1GB to disk |
| QA-7 | High | Usability | Stage timings were fabricated — a 72-second stage reported `0s` |
| QA-8 | High | Functionality | A failed PyInstaller unwrap silently disabled the native pipeline |
| QA-9 | Medium | Security | Capture files were `0644`, not the `0600` v4 §5 requires |
| QA-10 | Medium | Security | revctf silently `chmod 700`'d a pre-existing `--output` directory |
| QA-11 | Medium | Fault tolerance | `SIGHUP` was untrapped — a dropped SSH session killed the run dirty |
| QA-12 | Medium | Functionality | Mach-O universal binaries were routed to the Java decompiler |
| QA-13 | Medium | Usability | Every scan exited `0`, even when every stage failed |
| QA-14 | Medium | Fault tolerance | An unwritable output directory produced seven misleading errors |
| QA-15 | Low | Usability | `output_dir = ~/reports` created a directory literally named `~` |
| QA-16 | Low | Usability | The upx diagnostic truncated the message it existed to preserve |

---

### QA-1 — Critical: a config value aborts the shell mid-stage

**Reproduction**

```bash
printf 'full_hexdump = on\n' > cfg
revctf scan ./crackme --config cfg
# lib/stage_hexdump.sh: line 14: on: unbound variable      → exit 1
```

**Why it matters.** Ten config keys are booleans consumed in `[[ … -eq 1 ]]`, which is
bash *arithmetic* context. Under `set -u` a non-numeric word there is treated as a variable
name and the shell **exits immediately**. `tui = yes` killed the run at startup;
`full_hexdump = on` killed it *inside a stage*, where `stage_run`'s error boundary cannot
help — `set -u` exits rather than returning non-zero. That is precisely the failure mode
v5 §4.1 and CLAUDE.md forbid. It also stranded a work directory each time (see QA-2).

The README invites users to hand-write this file, so `tui = false` is a realistic input,
not a contrived one.

**Fix.** Config values are coerced and validated before they can reach an arithmetic test:
booleans accept `yes/no/true/false/on/off/1/0`, integers are checked with `is_uint`, and
anything else warns and falls back to the default rather than terminating. A defensive
assertion in `validate_opts` catches any non-boolean that slips through.

---

### QA-2 — High: no `EXIT` trap, so early exits stranded the work directory

Only `INT`/`TERM` were trapped. Any other path out of the process — a `die`, or the QA-1
crash — skipped `stage_end_file`, leaving `/tmp/revctf-work.*` behind. Reproduced: one
stranded directory per crash, each up to the size of whatever had been unwrapped.

**Fix.** `trap 'stage_end_file' EXIT`, plus `HUP` alongside `INT`/`TERM`.

---

### QA-3 — High: an archive containing a packed file was itself called "packed"

**Reproduction**

```bash
tar cf container.tar packed_upx planted_flag
revctf scan container.tar
# triage  failed  … target is upx-packed and could not be unpacked
```

`_triage_packer` ran `grep -qa 'UPX!'` over the **whole file**. Any container holding a
UPX-packed member contains those bytes, so the archive was declared packed, extraction never
ran, and the report told the user their perfectly ordinary tar was an unreadable packed
binary whose "missing strings and empty disassembly" should be treated as unreliable. The
`Routing` section was never written either, so the report was missing a documented section.

**Fix.** Packer detection is skipped for containers and managed formats entirely, and the
marker scan is limited to the first and last 4KB — where a real UPX stub and trailer live.
Cheaper on a large target, and correct.

---

### QA-4 — High: `Ctrl+C` ignored for 77 seconds, tool left orphaned

**Reproduction**

```bash
revctf scan large_blob.bin &        # 220MB target
sleep 8; kill -INT $!               # during binwalk
# → exited 130 after 77 seconds; 2 orphaned `strings` processes after an earlier run
```

Two separate causes. Bash defers a trap until the current **foreground** command finishes,
so any stage that ran its tool in the foreground swallowed the signal for its whole
duration. And a bare `exit` in the handler left the tool running as an orphan.

This matters much more from M3 onward, where `ltrace` and `strace` **execute the challenge
binary** — an orphan there is untrusted code still running after the user believes they
stopped the scan.

**Fix.** Every external tool now launches through one helper, `st_run_bounded`, which
backgrounds it and `wait`s — `wait` is interruptible, so the handler fires immediately. The
child PID is recorded and killed on abort (`TERM`, then `KILL` after a grace period).
Measured: **77s → 8s**, zero orphans, zero stranded directories.

> **Documented limitation, not fixable in bash.** When revctf is backgrounded from a
> *non-interactive* shell (`revctf scan x &` in a script or CI job), POSIX requires the
> shell to set `SIGINT` to ignored for that job, and bash will not install a trap for a
> signal that was ignored on entry — visible as `SigIgn: …6` in `/proc/<pid>/status`. Use
> `SIGTERM`, which is trapped and takes the identical path. Interactive Ctrl+C is
> unaffected. This is now stated in `--help`.

---

### QA-5 — High: FIFOs and device files were accepted, then hung the scan

`/dev/zero` wedged a scan for the full 300-second `strings` timeout; a FIFO blocked
indefinitely. Only `-e` and `-r` were checked, never `-f`.

**Fix.** Non-regular targets are rejected up front, naming what they are — "target is a
named pipe (FIFO), not a regular file". Rejection is now instant.

---

### QA-6 — High: unbounded archive extraction (decompression bomb)

**Reproduction:** a 1,043,752-byte zip wrote **1,048,584 KB** into the work directory. No
check of expansion ratio, absolute size, or free space. On the 2GB Tier C hardware v4 §3
targets, this fills the disk.

**Fix.** `7z` reports uncompressed totals in its listing, so the cost is known before a byte
is written. Two bounds now apply: an absolute cap (`TRIAGE_MAX_EXPAND_KB`, default 2GB) and
a free-space check requiring 2× headroom. A 3GB bomb is refused with
`container expands to 3072MB, over the 2048MB limit` and disk usage does not move.

---

### QA-7 — High: fabricated stage timings

`STAGE_SECS` was written only by `stage_capture`. Every stage that ran its own tool never
had the key set, and the summary's `${STAGE_SECS[$s]:-0}` default printed a convincing `0`.
Verified: `binwalk` on a 220MB target takes **72 seconds** and reported `0s`.

This is the worst kind of bug — a plausible wrong number. It would also have poisoned M5's
tier measurements, which are meant to be *measured* rather than estimated.

**Fix.** Timing moved to `stage_run`, the boundary every stage passes through. Now reports
72s.

---

### QA-8 — High: a failed PyInstaller unwrap silently disabled the native pipeline

`RUN_FORMAT` was set to `pyinstaller` *before* attempting extraction and never reverted on
failure — and extraction fails on every stock install, since `pyinstxtractor` is not
packaged. Result: `checksec` and `objdump` skipped "not applicable to a pyinstaller target",
and in M3 `ltrace`/`strace` would have too — while the stage reported **`ok` with no note**.
A normal ELF that merely mentions "PyInstaller" in a string lost most of its analysis
silently.

**Fix.** The format changes only after a *successful* unwrap. On failure the native format
is kept, the stage is marked `failed`, and the report explains that the bootloader rather
than the program logic is being analysed. Detection also now looks only at the trailing
1MB, where the real marker lives.

---

### QA-9 / QA-10 — Medium: file permissions

Captures were created `0644` from the umask, though v4 §5 explicitly requires `0600`
because they quote strings, symbols and decompiled logic from the analysed binary.
Separately, revctf ran `chmod 700` on the output directory **even when the user already had
one** — point `--output` at a shared or published directory and revctf silently locked
everyone else out of it.

**Fix.** A scoped `umask 077` for the run gives `0600` captures; `0700` is applied only to a
directory revctf itself creates, and a pre-existing one is left exactly as found.

---

### QA-11 to QA-16 — the rest

- **QA-11** `SIGHUP` untrapped: a dropped SSH session killed the scan with no cleanup. Now
  trapped, exits 129. Abort exit codes are now signal-specific (130/143/129).
- **QA-12** Mach-O universal binaries share magic `0xCAFEBABE` with Java `.class` and were
  routed to the Java decompiler. Now disambiguated using `file(1)`, with the other Mach-O
  magics recognised too.
- **QA-13** Every scan exited `0`, so no script could distinguish a clean run from one where
  every stage failed. Now: `0` clean, `2` completed-with-failures, `1` could-not-run,
  `128+N` aborted — documented in `--help`.
- **QA-14** An unwritable output directory produced seven separate "strings exited 1"-style
  errors and never named the real cause. Now fails fast with
  `output directory is not writable: …`.
- **QA-15** `output_dir = ~/ctf/reports` — the README's own example — created a directory
  literally named `~`. Tilde is now expanded on config load.
- **QA-16** The upx diagnostic extractor used `[^\n]`, which in a POSIX ERE means "not
  backslash, not the letter n". It truncated at the first `n`, mangling the very message it
  existed to preserve. It only looked right because "checksum error" happens to contain no
  `n`.

Also fixed while in the area: `stage_triage` ran every classification probe unbounded
(`file`, `rabin2`, a whole-file `strings`, `7z l`, `upx -t`) despite v6 §7.4 bounding every
other stage — all now carry timeouts; and a dead `elif` branch in the PyInstaller unwrap
that swallowed the extractor's real exit status.

---

## What was tested and found sound

Worth recording, so the next review does not redo it:

- **Command injection** — filenames containing `;`, `$(…)`, backticks, `|`, `&&`, `$IFS`,
  embedded newlines and leading `-` all handled correctly. No marker file was ever created.
- **Config injection** — the config file is parsed, not sourced; `$(…)` and backticks in
  values are inert.
- **Zip slip** — an archive entry named `../../../../tmp/QA_ZIPSLIP` did not escape the
  extraction directory.
- **Streaming discipline** — a 220MB target scans at ~103MB peak RSS. Nothing is buffered
  in a shell variable.
- **Temp directories** — created via `mktemp -d`, mode `0700`, not predictable.
- **Isolate-and-continue** — a failed triage does not stop later stages (this was already
  covered by the M2 suite and still passes).

---

## Recommendations before v1.0

Not defects, but they will become ones:

1. **A `--strict` / fail-fast mode.** Isolate-and-continue is right by default, but a
   scripted user may want the run to stop at the first failed stage. Cheap now, awkward once
   batch mode (M7) exists.
2. **Bound the flag-scan regex work (M3).** `--flag-format` is validated as a valid ERE but
   nothing bounds its *cost*. A catastrophic-backtracking pattern over a multi-megabyte
   strings capture is a self-inflicted denial of service. Bound the scan, or use `grep -E`
   (already DFA-based) exclusively and never a PCRE engine.
3. **Decide what `--sandbox` means for M3's `strace`.** v5 scopes the sandbox to `ltrace`
   only, but `strace` executes the challenge binary just as directly. Shipping a stage that
   runs untrusted code with no sandbox option is a gap the design predates.
4. **Cap total capture size per stage.** Time bounds exist; size bounds do not. A pathological
   target can still fill the disk through a long-but-not-timed-out stage.
5. **Re-measure the tier boundaries in M5.** v4 §10 already flags 3.8GB/2.5GB as estimates.
   The Ghidra version boundary was an estimate too, and it was wrong — treat these the same
   way.
