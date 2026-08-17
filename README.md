# revctf

Automated reverse-engineering CTF analysis pipeline for Kali Linux.

Point it at a challenge binary — or a directory of them — and it runs a staged toolchain
(triage/unwrap, static analysis, dynamic tracing, decompilation) and writes a
beginner-friendly plain-text report with flag candidates surfaced at the top.

> **Status: M2 complete — `v0.2-m2-qa`.** Triage/unwrap and the seven light static stages
> work end to end; a pre-M3 QA pass is closed (`QA-REVIEW.md`). The heavy stages, flag
> detection and the report land in M3–M4. Verification: 127 checks, all green
> (`./tools/run-tests.sh`). See `CHANGELOG.md` and `implementation-notes.md`.

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
revctf scan ./big.elf --dry-run                         # show plan, run nothing
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
`--dry-run` to see the resolved plan before committing to a large batch.

On a Tier B/C host with no active swap, revctf offers to create a 1–2GB swap file
(`--no-auto-swap` opts out). A background watchdog kills the run if total RSS passes 90%
of system RAM — that one action is never prompted, by design.

## Control and safety

- `--interactive` / `-i` — pause before each stage: Continue / Skip stage / Skip file / Abort
- `--yes` / `-y` — auto-accept every prompt; makes CI runs unhangable
- `--skip-ltrace`, `--skip-ghidra` — skip the two heaviest stages
- `--strict` — stop at the first failed stage. By default a failure is isolated and the
  run continues
- `--sandbox` — run `ltrace` inside a `--network=none --read-only --cap-drop=ALL` container
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

Reports are plain text, written to `./revctf-reports/<name>-<timestamp>/` (directory `700`,
files `600`) and mirrored to stdout. A stage that finds nothing says so; a stage that fails
says so with the command, exit code, and a stderr tail. One failed stage never stops the
run.

Display adapts: a live stage table on a terminal, periodic heartbeat lines when redirected.
`--no-tui` forces plain line output.

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
- `--debug` — full command trace to `<output>/<name>.debug.log`
- `~/.revctf/error.log` — every stage failure across every run, `600`, rotated at 5MB

## Requirements

Kali Linux (or Debian-derived), Bash 4+, and the toolchain `install.sh` sets up: `file`,
`strings`, `binwalk`, `hexdump`, `ltrace`, `strace`, `radare2`, `checksec`, `objdump`,
`readelf`, `upx`, FLOSS, Java/.NET/Python decompilers, and Ghidra (10.x or 11.x+, found via
`PATH`, `GHIDRA_HOME`, or `/opt/ghidra*`). Docker is needed only for `--sandbox`;
`systemd-run` is preferred for memory bounding, with a documented `ulimit -v` fallback.

## Development

```bash
./tools/build-test-corpus.sh     # 18 test artifacts (gitignored)
./tools/run-tests.sh             # 127 checks: lint corpus m0 m1 m2 qa ghidra
./tools/run-tests.sh m2 qa       # just those sections
```

The `ghidra` section self-skips when no Ghidra is installed. `CLAUDE.md` holds the
conventions that must not be violated — read it before changing `lib/`.

## Design documents

`revctfmasterplan_v6.md` is the consolidated build spec — read that one.
`revctf_executionmasterplan.md` holds milestone order and gates. v3/v4/v5 are historical.
