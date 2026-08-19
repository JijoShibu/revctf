# revctf

Automated reverse-engineering CTF analysis pipeline for Kali Linux.

Point it at a challenge binary — or a directory of them — and it runs a staged toolchain
(triage/unwrap, static analysis, dynamic tracing, decompilation) and writes a
beginner-friendly plain-text report with flag candidates surfaced at the top.

> **Status: M4 complete — this is the MVP (`v0.1-mvp`).** Single-file scanning works end
> to end: 14 stages including Ghidra headless, flag detection with the
> base64/base32/hex/ROT13 sweep, a readable report, and three display modes. Verification:
> **262 checks, all green** (`./tools/run-tests.sh`). M5–M9 add RAM tiers, the Docker
> sandbox, batch mode, user agency and resilience. New here? Read `HANDOFF.md`.

---

## Install

```bash
git clone <repo> revctf && cd revctf
sudo ./install.sh
```

`install.sh` is not optional. It installs the complete toolchain and builds the sandbox
container during a network window; at scan time a missing tool is a hard error rather than
a silently thinner report. Run it while online.

## Usage

```bash
revctf scan ./crackme                                   # single file
revctf scan ./challenges/ --summary-only                # batch, flags first
revctf scan ./bin --flag-format 'picoCTF\{.*?\}'        # custom flag pattern
revctf scan ./sample --sandbox                          # ltrace in a container
revctf scan ./big.elf --dry-run                         # resolved plan, runs nothing
revctf --help                                           # every flag
```

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

| Tier | RAM | Phase-1 jobs | radare2 ceiling | Phase-2/3 jobs | Ghidra `MAXMEM` | Decompile |
|---|---|---|---|---|---|---|
| A | ≥ 3.8GB | 4 | 640MB | 2 | 1024M | Full |
| B | 2.5–3.8GB | 2 | 450MB | 1 | 768M | Full |
| C | < 2.5GB | 1 | 400MB | 1 (forced only) | 512M | Light (auto) |

Override individually with `--jobs-light`, `--jobs-ghidra`, `--maxmem-ghidra`. Use
`--dry-run` to see the resolved plan — tier, limits, and exactly which stages would run —
before committing to a large batch. It executes nothing.

> The tier boundaries and the Phase-2 memory ceiling are **not yet measured**. v4 §10 flags
> them as estimates, and the measured FLOSS peak (~1.46GB) already exceeds every tier's
> Ghidra ceiling. `--dry-run` says so in its Notes. M5 replaces them with real numbers.

**revctf never modifies your system.** On a Tier B/C host with no active swap it says so
and names the two remedies — run with `--skip-ghidra`, or add swap yourself — and then
gets on with the scan. Earlier designs had it create a swap file automatically; that was
removed (deviation D10). Reading a binary and writing a report does not require write
access to `/etc/fstab`.

**Planned for M5, not in this build:** the RSS watchdog, and actual *enforcement* of the
tier limits. Today the tier is detected, resolved and reported — `--dry-run` shows exactly
what it decided — but nothing constrains a stage to those numbers yet.

## Control and safety

- `--skip-ltrace`, `--skip-strace` — skip the stages that **execute** the challenge binary
- `--skip-ghidra` — skip decompilation; radare2 substitutes
- `--strict` — stop at the first failed stage. By default a failure is isolated and the
  run continues
- `--sandbox` — run the executing stages inside a `--network=none --read-only
  --cap-drop=ALL` container. Until M6 builds the image, `--sandbox` **refuses** to run them
  rather than quietly falling back to the host
- Prompts appear only on a TTY; piped output never blocks waiting for input

`--sandbox` combined with a large batch is the tightest resource combination on 4GB
hardware. It is supported, not blocked — just be aware.

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

## Configuration

Optional `~/.revctf/config`, `key=value` per line. CLI flags always win.

```ini
flag_format  = HTB\{.*?\}
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
| `--jobs-light`, `--jobs-ghidra`, `--maxmem-ghidra` | resolved and reported, **not enforced** | M5 |
| RSS watchdog | not present | M5 |
| Auto-created swap file | **removed** — replaced by a diagnostic (D10) | n/a |
| `--sandbox` | *refuses* the executing stages rather than falling back to the host | M6 |
| Batch mode (a directory target) | exits 1 with a clear message | M7 |
| `install.sh` dependency installation | **stub — installs nothing** | next |

`tools/bootstrap-kali.sh` covers the `install.sh` gap meanwhile.

## Requirements

Kali Linux (or Debian-derived), Bash 4+, and the toolchain `install.sh` sets up: `file`,
`strings`, `binwalk`, `hexdump`, `ltrace`, `strace`, `radare2`, `checksec`, `objdump`,
`readelf`, `upx`, FLOSS, Java/.NET/Python decompilers, and Ghidra (10.x or 11.x+, found via
`PATH`, `GHIDRA_HOME`, or `/opt/ghidra*`). Docker is needed only for `--sandbox`;
`systemd-run` is preferred for memory bounding, with a documented `ulimit -v` fallback.

## Development

```bash
./tools/bootstrap-kali.sh                 # one-shot setup on a fresh Kali / WSL Kali
./tools/build-test-corpus.sh              # 18 test artifacts (gitignored)
./tools/run-tests.sh                      # 262 checks (~15 min)
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

`HANDOFF.md` is the cold-start entry point. `CLAUDE.md` holds the conventions that must not
be violated — read it before changing `lib/`.

## Design documents

`revctfmasterplan_v6.md` is the consolidated build spec — read that one.
`revctf_executionmasterplan.md` holds milestone order and gates. v3/v4/v5 are historical.
