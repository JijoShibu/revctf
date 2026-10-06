# revctf

**Created by Jijo Shibu <jijoshibu@gmail.com>** · MIT licence ([LICENSE](LICENSE)) · <https://github.com/JijoShibu/revctf>

Automated reverse-engineering CTF analysis pipeline for Kali Linux.

Point it at a challenge binary and it runs a staged toolchain (triage/unwrap, static
analysis, dynamic tracing, decompilation), then writes a beginner-friendly plain-text
report with flag candidates surfaced at the top. The two stages that **execute** the
challenge do so inside a network-isolated, read-only Docker container by default; without
Docker they skip rather than running the binary on your machine.

Directory targets are M7 and are not in this build — a directory exits 1 with a message.

> **Status: v2.0.0 — prepared for final release checks.** This version improves
> resource limits, cleanup, and the handling of incomplete results. It requires an
> approximate 4 GB RAM check before scanning. All recovered candidates remain unverified.
> Read the [release notes](docs/releases/2.0.0.md) and
> [validation results](docs/reliability-validation.md) before upgrading.
> Batch scanning, interactive solving, and persistent debug logging remain planned.

---

## Install

```bash
git clone https://github.com/JijoShibu/revctf.git && cd revctf
sudo ./install.sh
```

Run `install.sh` while online. It installs the required tools, including Java 21 for
Ghidra, and builds the sandbox when Docker is available. Optional Java/.NET decompilers
are attempted separately; an unavailable package is reported. A scan that needs a
missing analysis tool reports the problem rather than claiming that step succeeded.

The proposed 2.0 profile uses Ghidra 12.1.4 and verifies downloaded Ghidra and extractor
files before installing them. Existing unrelated tools are preserved. See the
[dependency profile](dependencies/README.md) for versions and remaining validation.
The tested installation profile is Kali 2026.3 with Python 3.14 on Intel/AMD 64-bit
computers. Python tool and build dependencies are pinned with download hashes;
another Python version needs a separately validated profile. RevCTF analyzes Linux and
Windows executables. A Windows host or automatic execution of Windows programs is not
part of this release's support promise.

It does **not** install Docker — Kali does not ship it, and pulling in a ~500MB daemon
uninvited is not the installer's call. Without Docker the two stages that execute the target
skip and say so; install.sh warns, tells you the command, and still exits 0, because an
install that placed every other tool correctly has not failed. Run
`sudo apt-get install docker.io` and re-run install.sh to enable them.

This is the whole deployment path: clone, install, done. `docs/REHEARSAL.md` is the
procedure for proving it from zero.

For a published release, use its exact tag instead of following the development branch.
The `v2.0.0` tag becomes available when the reviewed release is published. See
[installation, upgrade and rollback](docs/RELEASING.md#install-upgrade-and-rollback)
for the commands and the release checks.

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

Before dependency checks or analysis, revctf checks Linux's **total RAM**, not free RAM
or swap. Allocate at least **4 GB (4096 MB)** to Kali. The approximate check accepts
3891 MiB or more of reported total RAM, allowing for memory reserved by the system;
it cannot prove the virtual machine's configured allocation.

Below that threshold, or if RAM cannot be measured, scans stop with exit 1 and explain
how to increase the allocation. `--allow-low-memory` explicitly accepts a potentially
slower or incomplete scan. This option is command-line only: configuration, `--yes`,
and reduced-analysis flags cannot bypass the check. The warning appears both at startup
and in the report. `--help` and `--version` still work; `--dry-run` shows whether a real
scan would be blocked. revctf does not change system memory or swap settings.

RAM is then mapped to a tier that sets concurrency and memory ceilings:

| Tier | RAM | Phase-1 jobs | radare2 ceiling | Phase-2 ceiling | Ghidra analysis heap | Decompile |
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

`--maxmem-ghidra` controls the Java analysis heap. Ghidra receives a separate process
allowance of heap + max(256 MiB, 25% of heap rounded up), so a 1024M heap has a 1280 MiB
process ceiling. A pre-analysis Java script verifies the actual heap; the report records
its measurement. Only the child Java environment is changed, not your installation.
Without usable systemd limits, whole-process enforcement is unavailable and is reported
as such. A memory failure may trigger one inventory-only retry; that result is **partial**.

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
- `--strict` — stop at the first failed or partial stage. By default a failure is isolated and the
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

**Partial** means useful evidence was retained but a requested step did not finish.
This includes timeouts, output limits and a reduced retry after memory exhaustion.
Candidates recovered from partial captures remain **UNVERIFIED**. Finding no candidate
in an incomplete scan does not establish that no flag exists.

On interruption, revctf saves available captures and an incomplete report, then removes
only containers bearing this scan's unique ownership label. Docker cleanup has a ten-second
deadline. If removal cannot be verified, `cleanup-warning.txt` identifies the container
and recovery command, and further challenge execution is blocked. SIGKILL and host crashes
can prevent cleanup entirely. Original challenge files are never modified.

`ST_MAX_OUT_KB` is a positive whole number of 1024-byte units, enforced per file both
outside and inside Docker. Reaching the boundary without reliable completion evidence
marks the result incomplete. This is not an overall disk budget, and limits are never
automatically increased to hide an incomplete result.

| Code | Meaning |
|---|---|
| `0` | No requested stage failed or was partial; inapplicable or unavailable optional stages may be skipped |
| `2` | Scan completed with failed or partial stages — or `--strict` stopped it early |
| `1` | The scan could not run: RAM check, bad arguments, missing tools, unwritable output |
| `130` / `143` / `129` | Aborted by SIGINT / SIGTERM / SIGHUP |

> **Stopping a backgrounded scan.** When revctf is launched from a script
> (`revctf scan x &`), POSIX requires the shell to make it ignore `SIGINT`, and bash will
> not install a trap for a signal that was ignored on entry. **Send `SIGTERM` instead** —
> it is trapped and takes the identical cleanup path. Interactive Ctrl+C works normally.

### Limits

Commands have time and file-size limits. These limits reduce resource use; they are not
a total disk budget, and a large or complicated challenge can still exceed available resources:

| Bound | Default | Override |
|---|---|---|
| ltrace timeout | 10s | `--timeout` |
| Other stage timeouts | 120–1800s by stage | `ST_T_*` env vars |
| Per raw output or trace file | 2 GiB | `ST_MAX_OUT_KB` (1024-byte units) |
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

A stage that finds nothing says so; one that stops early is marked failed or partial.
Other stages continue unless `--strict` was selected.

Choose a **new or empty directory** for `--output`. revctf refuses to reuse a directory
containing files, so earlier reports and the original challenge cannot be overwritten by
its captures. A `.revctf-lock` directory prevents two scans from sharing the same output.
If a scan is forcibly killed and leaves a lock behind, choose another output directory.
Keep shell redirections outside that directory, and never redirect output onto the input
file: the shell opens redirected files before revctf can check them.

**Every flag candidate is unverified.** High confidence means the text looks like a
familiar flag; a convincing decoy can receive the same rating. Confirm an answer against
the challenge's known answer or acceptance check before calling it solved.

The final candidate search uses a separate worker with a 384 MiB memory allowance and
a 300-second default time limit. It searches full preserved captures, including output
beyond the short managed-code and radare2 report previews. The previous encoding-token
and ROT byte cutoffs have been removed. The report loads at most 10,000 candidate records;
a reached limit or failed worker marks the search partial and keeps its evidence.
Stack reconstruction skips exceptionally long lines or runs with an explicit incomplete
status. Ghidra analyzes up to 200 selected functions and reports failed or unprocessed
functions. These protections can still leave work unfinished; no result proves that a
file contains no flag.

Custom `--ghidra-script` files are loaded from their own directory. They must use the
same output contract as the bundled scripts: print `=== REVCTF-GHIDRA-BEGIN ===` before
results, `=== REVCTF-GHIDRA-END ===` after successful completion, and `REVCTF-ERROR:`
when an error prevents completion. Missing markers or reported script errors fail the
stage even if Ghidra itself returns a successful exit code.

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


The installer sets up system packages, FLOSS and uncompyle6 in an isolated Python
environment, and Ghidra with its Java development kit. The current installation results
and unavailable optional packages are recorded in [the validation report](docs/reliability-validation.md).
It installs the **pinned, verified** Ghidra build rather than the newest release —
`GHIDRA_LATEST=1` opts into newest, but Ghidra 12.x needs PyGhidra wiring that does not
exist yet. `tools/bootstrap-kali.sh` remains as the alternative that also pulls the
build-only dependencies the test corpus needs.

## Requirements

Kali Linux amd64, Bash 4+, **4GB RAM** recommended and at least 4GB free disk
(Ghidra alone unpacks to ~400MB). Plus the toolchain `install.sh` sets up: `file`,
`strings`, `binwalk`, `hexdump`, `ltrace`, `strace`, `radare2`, `checksec`, `objdump`,
`readelf`, `upx`, FLOSS, Java/.NET/Python decompilers, and Ghidra (**12.1.4, pinned**), found via
`PATH`, `GHIDRA_HOME`, or `/opt/ghidra*`. **Docker is recommended, not required** — the two
executing stages (`ltrace`, `strace`) are sandboxed by default and need it; without it they
skip rather than running the target on your machine, and everything else runs normally. `systemd-run` is preferred for memory bounding,
with a documented `ulimit -v` fallback.

Ghidra versions outside the release profile are rejected before analysis. Update the
selected installation or explicitly use `--skip-ghidra`. `GHIDRA_LATEST` is no longer an
installer upgrade route; upgrades need a reviewed profile and affected tests.

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
| `docs/CONTRIBUTING.md` | The conventions that must not be violated. Read before changing `lib/` |
| `docs/implementation-notes.md` | What was learned while building, per milestone |
| `docs/CHECKLIST.md` | Release checklist, including what is still outstanding |
| `docs/REHEARSAL.md` | Clean-install rehearsal procedure |
| `docs/QA-REVIEW.md`, `docs/QA-REVIEW-2.md` | The two QA passes and the rules they produced |
| `docs/design/` | The five design documents. `revctfmasterplan_v6.md` is the consolidated spec — read that one; v3/v4/v5 are historical and `docs/design/README.md` flags where they are now wrong |

## Credits

Created by **Jijo Shibu <jijoshibu@gmail.com>**. MIT licence — see [LICENSE](LICENSE).

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
