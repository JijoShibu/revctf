# revctf

**Created by Jijo Shibu** · MIT licence ([LICENSE](LICENSE)) · <https://github.com/JijoShibu/revctf>

Automated reverse-engineering CTF analysis pipeline for Kali Linux.

Point it at a challenge binary and it runs a staged toolchain (triage/unwrap, static
analysis, dynamic tracing, decompilation), then writes a beginner-friendly plain-text
report with flag candidates surfaced at the top. The two stages that **execute** the
challenge do so inside a network-isolated, read-only Docker container by default; without
Docker they skip rather than running the binary on your machine.

Directory targets are M7 and are not in this build — a directory exits 1 with a message.

> **Status: v1.0 — M6 complete.** Single-file scanning works end to end: 14 stages
> including Ghidra headless, flag detection with the base64/base32/hex/ROT13/ROT47 sweep
> plus a stack-string decoder, a readable report, and three display modes. The RAM-tier
> memory ceilings are *enforced* via `systemd-run --scope`, with a global RSS watchdog
> behind them, and the two stages that execute the challenge binary run inside a
> network-isolated Docker container **by default**.
> Batch mode (M7), the prompt layer (M8) and the debug log (M9) are post-1.0.
> Everything you need to use revctf is on this page. Maintainer documents are in `docs/`.

---

## Install

```bash
git clone https://github.com/JijoShibu/revctf.git && cd revctf
sudo ./install.sh
```

`install.sh` is not optional. It installs the complete toolchain and builds the sandbox
container during a network window; at scan time a missing tool is a hard error rather than
a silently thinner report. Run it while online.

It does **not** install Docker — Kali does not ship it, and pulling in a ~500MB daemon
uninvited is not the installer's call. Without Docker the two stages that execute the target
skip and say so; install.sh warns, tells you the command, and still exits 0, because an
install that placed every other tool correctly has not failed. Run
`sudo apt-get install docker.io` and re-run install.sh to enable them.

This is the whole deployment path: clone, install, done. `docs/REHEARSAL.md` is the
procedure for proving it from zero.

## Usage

```bash
# 1. The normal case. Report at ./revctf-reports/<name>-<timestamp>/report.txt
revctf scan ./crackme

# 2. The picoCTF 2022 acceptance run — this is the one that recovered both flags.
#    unpackme-upx is a statically-linked UPX-packed ELF with no section headers, and its
#    flag is a stack string: invisible to `strings` before and after unpacking. revctf
#    unpacks it, decompiles the payload with Ghidra, and the flag scanner's ROT47 sweep
#    over the pseudo-C recovers picoCTF{up><_m3_f7w_77ad107e} at HIGH confidence.
revctf scan ~/unpackme-upx --output ~/reports/unpackme

# 3. A non-picoCTF event. --flag-format takes POSIX extended regex (grep -E) — no lazy
#    quantifiers, no PCRE. Your pattern is run over megabytes of capture, and a
#    backtracking engine there is a self-inflicted DoS.
revctf scan ./challenge --flag-format 'HTB\{[^}]+\}'

# 4. A fast first look: skip the decompile (radare2 substitutes) and lead with a summary.
revctf scan ./challenge --skip-ghidra --summary-only

# 5. Redirect the report, keep the progress display. stdout is the report and the live
#    stage table goes to stderr, so this produces a clean file.
revctf scan ./challenge > findings.txt

revctf scan ./big.elf --dry-run    # resolved plan, executes nothing
revctf --help                      # every flag
```

Your original file is never modified. Packed and archived targets are unwrapped to copies
in a temporary working directory.

## What it runs

Stage 0 is a **triage/unwrap** pass: it detects packed binaries (UPX), Java/.NET
assemblies, Python artifacts (`.pyc`, PyInstaller) and archive/firmware containers, and
retargets the pipeline at the real payload. It always works on a copy — your original file
is never modified. `--no-unwrap` turns it off.

Analysis then runs in three phases that never overlap, so heavy memory consumers never
compete:

| Phase | Stages |
|---|---|
| 1 — light static + tracing | `file`, `strings`, `binwalk`, `hexdump`, `checksec`+`rabin2`, `objdump`+`readelf`, `ltrace`, `radare2` |
| 2 — heavy extras | `strace`+`ldd`, FLOSS, Java/.NET decompile, Python decompile |
| 3 — decompilation | Ghidra headless |

## Adapting to your hardware

RAM is detected at startup and mapped to a tier that sets concurrency and memory ceilings:

| Tier | RAM | Phase-1 jobs | radare2 ceiling | Phase-2 ceiling | Ghidra `MAXMEM` | Decompile |
|---|---|---|---|---|---|---|
| A | ≥ 3.8GB | 4 | 640MB | 1536MB | 1024M | Full |
| B | 2.5–3.8GB | 2 | 450MB | 1024MB | 768M | Full |
| C | < 2.5GB | 1 | 400MB | 512MB | 512M | Light (auto) |

These ceilings are **enforced**, not just reported: every external tool runs under
`systemd-run --scope -p MemoryMax`, and a stage that exceeds its ceiling is killed and
reported as killed. Where systemd is unavailable revctf falls back to `ulimit -v` and says
so — that bounds virtual size rather than RSS, so it is weaker, and JVM stages are exempt
from it because a JVM needs 2–4GB of *address space* to start at all and would simply fail.

A global RSS watchdog is the backstop: if the whole run reaches 90% of detected RAM it
kills the running tools, stops the scan, and still writes the partial report.

Override individually with `--jobs-light`, `--jobs-ghidra`, `--maxmem-ghidra`. Use
`--dry-run` to see the resolved plan — tier, limits, and exactly which stages would run —
before committing to a large batch. It executes nothing.

> **The tier boundaries (3.8GB / 2.5GB) are still estimates** — v4 §10 flags them as such
> and they have not been measured. The **Phase-2 ceiling has**: it used to inherit Ghidra's
> `MAXMEM`, which the measured FLOSS peak disproved, so it is now derived from its own
> measurement (deviation D11). FLOSS costs ~900MB on even a 264KB PE, because the cost is
> emulation rather than file size — so on Tier C, where that cannot fit, FLOSS runs
> static-only and the report says it was RAM rather than the file format.

**revctf never modifies your system.** On a Tier B/C host with no active swap it says so
and names the two remedies — run with `--skip-ghidra`, or add swap yourself — and then
gets on with the scan. Earlier designs had it create a swap file automatically; that was
removed (deviation D10). Reading a binary and writing a report does not require write
access to `/etc/fstab`.

Use `--dry-run` to see exactly what was decided — tier, ceilings, which mechanism is
enforcing them, and the watchdog threshold — before committing to a large batch.

## Control and safety

- `--skip-ltrace`, `--skip-strace` — skip the stages that **execute** the challenge binary
- `--skip-ghidra` — skip decompilation; radare2 substitutes
- `--strict` — stop at the first failed stage. By default a failure is isolated and the
  run continues
- **The sandbox is on by default.** `ltrace` and `strace` execute the challenge binary, so
  they run inside a `--network=none --read-only --cap-drop=ALL` container, as an
  unprivileged user, with the tier's memory ceiling applied by `docker --memory`. The exact
  flags are printed in the capture, so the guarantee is auditable rather than asserted
- `--no-sandbox` — execute the binary **directly on this machine**. The report says so in
  as many words
- **Without a usable Docker, those two stages are skipped**, not run unisolated. The skip
  names Docker as the cause and `--no-sandbox` as the deliberate override. revctf never
  silently drops the isolation: a command that is a security boundary on one machine and
  not on another, with the user believing they were isolated either way, is worse than no
  isolation at all
- Prompts appear only on a TTY; piped output never blocks waiting for input

The sandbox costs one container start per executing stage (~1s here). If Docker is not
available and you accept the risk, `--no-sandbox` is the explicit opt-out.

### Exit status

| Code | Meaning |
|---|---|
| `0` | Scan completed, every stage succeeded |
| `2` | Scan completed, but one or more stages failed — or `--strict` stopped it early |
| `1` | The scan could not run: bad arguments, missing tools, unwritable output |
| `130` / `143` / `129` | Aborted by SIGINT / SIGTERM / SIGHUP |

> **Stopping a backgrounded scan.** When revctf is launched from a script
> (`revctf scan x &`), POSIX requires the shell to make it ignore `SIGINT`, and bash will
> not install a trap for a signal that was ignored on entry. **Send `SIGTERM` instead** —
> it is trapped and takes the identical cleanup path. Interactive Ctrl+C works normally.

### Limits

Every stage is bounded in both time and output size, so a pathological target cannot hang
a run or fill a disk:

| Bound | Default | Override |
|---|---|---|
| ltrace timeout | 10s | `--timeout` |
| Other stage timeouts | 120–1800s by stage | `ST_T_*` env vars |
| Per-stage capture size | 2GB | `ST_MAX_OUT_KB` |
| Archive expansion | 2GB, and never more than half the free disk | `TRIAGE_MAX_EXPAND_KB` |
| Container recursion depth | 2 | `TRIAGE_MAX_DEPTH` |

## Output

Reports are plain text, written to `./revctf-reports/<name>-<timestamp>/report.txt`
(directory `700`, files `600`) and mirrored to stdout byte-for-byte. The order is fixed:

1. **Possible flags** — first, so you never scroll for the answer
2. **What ran** — every stage with status, time and output size
3. **Stage detail** — each capture with a plain-English note on why you are looking at it
4. **Diagnostics** — any stage that failed, with its command, exit code and stderr tail
5. **What to try next** — derived from what happened on *your* file, not a generic list

A stage that finds nothing says so; one that fails says so. A failure is isolated and the
run continues.

`--summary-only` keeps items 1, 2, 4 and 5 and drops the per-stage detail.

**Progress goes to stderr, the report to stdout**, so `revctf scan x > report.txt` gives a
clean file while you still see movement. Display adapts: an in-place stage table when
you are on a terminal, one line per stage with `--no-tui`, and a periodic heartbeat when
stdout is redirected.

## When a scan finds nothing

A zero-flag report is a normal result, not a failure. In order:

1. **Read `WHAT TO TRY NEXT` at the bottom of `report.txt`.** It is generated from what
   actually happened in your run, not from a generic list.

2. **Check what did not run.** The `WHAT RAN` table gives every stage a status and a reason
   for any skip. A flag hiding behind a skipped stage is the most common cause — usually
   `ltrace`/`strace` skipped for a missing Docker, or Ghidra skipped on Tier C.

3. **Read `ghidra.txt` and `radare2.txt` together**, in the output directory beside the
   report. Pseudo-C tells you what the program decides; the disassembly tells you exactly
   how. Both picoCTF acceptance flags lived here and nowhere else.

4. **Check whether FLOSS was format-limited.** On ELF, FLOSS can only do static strings —
   stack, tight and decoded extraction are PE-only. `floss.txt` says so in plain words. An
   absent flag there means the tool could not look, not that nothing is hidden.

5. **Consider a flag built at runtime.** Stack strings are assembled from immediates and
   never appear in `strings`. The scanner sweeps base64, base32, hex, ROT13, ROT47 and
   little-endian byte order over every capture, but a custom transform needs you.

6. **If the event uses an unusual flag format**, re-run with `--flag-format`. Without it
   only the known prefixes match at high confidence; anything `word{...}`-shaped lands low.

Every stage's raw output is kept in the output directory as `<stage>.txt` and
`<stage>.stderr`. The report summarises those files; it does not replace them.

## Configuration

Optional `~/.revctf/config`, `key=value` per line. CLI flags always win.

```ini
flag_format  = HTB\{[^}]+\}
output_dir   = ~/ctf/reports
jobs_light   = 2
tui          = no
strict       = yes
```

Unknown keys are reported and ignored rather than silently applied. Booleans accept
`yes/no`, `true/false`, `on/off` or `1/0`; a value that is neither a valid boolean nor a
valid number warns and falls back to the default rather than failing the run. `~` is
expanded in path values.

## Diagnostics

- `--verbose` — stage trace on stderr
- Every failed stage is reported in the report's DIAGNOSTICS block with its command, exit
  code and a stderr tail; the raw `<stage>.stderr` capture is kept alongside it

Planned, **not in this build**: `--debug` (M9), the persistent `~/.revctf/error.log` (M9),
and the `--interactive` / `--yes` prompt layer (M8). `--help` marks each of these
`[NOT YET: Mn]`.

## What is not in this build

`revctf --help` marks these `[NOT YET: Mn]` or `[PARTIAL: Mn]`, and the verification
harness asserts that this list and that one agree — so neither can drift.

| Flag / feature | Status | Lands in |
|---|---|---|
| `--interactive` / `-i` | parses, no effect | M8 |
| `--yes` / `-y` | parses, no effect | M8 |
| `--debug`, `~/.revctf/error.log` | parses, no effect | M9 |
| `--jobs-light`, `--jobs-ghidra` | resolved and reported; there is no concurrency to govern until batch mode | M7 |
| Auto-created swap file | **removed** — replaced by a diagnostic (D10) | n/a |
| Batch mode (a directory target) | exits 1 with a clear message | M7 |


`install.sh` is complete and has been run end-to-end on Kali: apt groups, FLOSS and
uncompyle6 into a venv (a system-wide `pip install` fails on modern Debian/Ubuntu), and
Ghidra. It installs the **pinned, verified** Ghidra build rather than the newest release —
`GHIDRA_LATEST=1` opts into newest, but Ghidra 12.x needs PyGhidra wiring that does not
exist yet. `tools/bootstrap-kali.sh` remains as the alternative that also pulls the
build-only dependencies the test corpus needs.

## Requirements

Kali Linux (or Debian-derived), Bash 4+, **4GB RAM** for full behaviour and ~4GB free disk
(Ghidra alone unpacks to ~400MB). Plus the toolchain `install.sh` sets up: `file`,
`strings`, `binwalk`, `hexdump`, `ltrace`, `strace`, `radare2`, `checksec`, `objdump`,
`readelf`, `upx`, FLOSS, Java/.NET/Python decompilers, and Ghidra (**11.2.1, pinned** —
12.x breaks the headless post-script; `GHIDRA_LATEST=1` opts in with a warning), found via
`PATH`, `GHIDRA_HOME`, or `/opt/ghidra*`. **Docker is recommended, not required** — the two
executing stages (`ltrace`, `strace`) are sandboxed by default and need it; without it they
skip rather than running the target on your machine, and everything else runs normally. `systemd-run` is preferred for memory bounding,
with a documented `ulimit -v` fallback.

The verification harness needs the test corpus, which is gitignored — a fresh clone must
run `./tools/build-test-corpus.sh` before `./tools/run-tests.sh`.

## Development

```bash
./tools/bootstrap-kali.sh                 # one-shot setup on a fresh Kali / WSL Kali
./tools/build-test-corpus.sh              # 18 test artifacts (gitignored)
./tools/run-tests.sh                      # full suite (~15 min)
./tools/run-tests.sh m4 m5 docs qa       # just those sections
REVCTF_TEST_FAST=1 ./tools/run-tests.sh   # skip the 220MB-target checks (~3 min)
./tools/tui-selftest.sh                   # 6 interactive checks — needs a real terminal
./tools/measure-host.sh                   # the numbers M5's constants derive from
```

Launch long background harness runs with `setsid`, **not** `nohup` — `nohup` sets SIGHUP
to ignored for every descendant, which makes the SIGHUP check report a phantom failure.

The `ghidra` section self-skips when no Ghidra is installed. `tui-selftest.sh` covers what
the harness structurally cannot: whether a resize corrupts the redraw, whether Ctrl+C
leaves the cursor hidden, whether the report reads as intended. Run it once on a real
terminal before trusting the display layer.

### Maintainer documents

Everything below `docs/` is for people changing revctf, not people using it.

| File | What it is |
|---|---|
| `docs/HANDOFF.md` | Cold-start entry point. Start here |
| `docs/CLAUDE.md` | The conventions that must not be violated. Read before changing `lib/` |
| `docs/implementation-notes.md` | What was learned while building, per milestone |
| `docs/CHECKLIST.md` | Release checklist, including what is still outstanding |
| `docs/REHEARSAL.md` | Clean-install rehearsal procedure |
| `docs/QA-REVIEW.md`, `docs/QA-REVIEW-2.md` | The two QA passes and the rules they produced |
| `docs/design/` | The five design documents. `revctfmasterplan_v6.md` is the consolidated spec — read that one; v3/v4/v5 are historical and `docs/design/README.md` flags where they are now wrong |

## Credits

Created by **Jijo Shibu**. MIT licence — see [LICENSE](LICENSE).

revctf is an orchestrator: nearly all of the analysis is done by other people's tools, and
it would not exist without them.

| Tool | Authors |
|---|---|
| [Ghidra](https://ghidra-sre.org/) | NSA Research Directorate |
| [radare2](https://rada.re/) | pancake and the radare2 contributors |
| [FLOSS](https://github.com/mandiant/flare-floss) | Mandiant FLARE team |
| [binwalk](https://github.com/ReFirmLabs/binwalk) | Craig Heffner and ReFirm Labs |
| [ltrace](https://ltrace.org/) | Juan Cespedes and contributors |
| [strace](https://strace.io/) | Paul Kranenburg, Dmitry Levin and contributors |
| [UPX](https://upx.github.io/) | Markus Oberhumer, László Molnár and John Reiser |
| [checksec](https://github.com/slimm609/checksec) | Brian Davis and contributors |
| GNU Binutils (`strings`, `objdump`, `readelf`) | the GNU Project |
| [pyinstxtractor](https://github.com/extremecoders-re/pyinstxtractor) | extremecoders-re (GPLv3; fetched by `install.sh`, not vendored) |

Each is used as a separate process under its own licence. The picoCTF challenges used for
acceptance testing are the work of the picoCTF team at Carnegie Mellon University.
