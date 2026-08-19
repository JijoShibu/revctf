# revctf — Masterplan v6 (Consolidated Current-State Spec)

A Bash CLI for Kali Linux that ingests a Reverse Engineering CTF challenge file — or a
directory of them — runs an automated Kali toolchain against it, and produces a
beginner-friendly plain-text report with auto-detected flag candidates surfaced at the top.

**This document supersedes v3, v4 and v5 as the single reference for what is being built.**
Where v3/v4/v5 are consistent, v6 restates them so no reader needs four documents open.
Where this session's decisions changed something, §11 records it explicitly as a deviation
with rationale. Milestone sequencing, Definition-of-Done gates and verification steps live
in `revctf_executionmasterplan.md` and are **not** restated here — v6 is *what*, the
execution masterplan is *when and in what order*.

---

## 1. Document Precedence

Four prior documents exist. When they disagree, resolve in this order:

| Rank | Document | Authority |
|---|---|---|
| 1 | **This session's explicit decisions** (§11 Deviation Register) | Final. Overrides everything below. |
| 2 | **`revctfmasterplan_v5.md`** + **`revctf_executionmasterplan.md`** | Authoritative for behavior, CLI surface, and build order. |
| 3 | `revctfmasterplan_v4.md` | Supplies detail only where 1–2 are silent: the RAM tier table, resource-isolation mechanics, watchdog, swap, OOM auto-retry. |
| 4 | `revctfmasterplanv3.md` | Supplies detail only where 1–3 are silent: memory derivations, base CLI semantics, per-stage invocation detail, sandbox hardening flags. |

**Worked example of this rule.** v3 §3 defines `--timeout` as "defaults to 10 (seconds,
applies to `ltrace`)". Nothing in v5 or the execution masterplan redefines it, and the
execution masterplan's M3 quotes `setsid timeout -k 5 10 ltrace -f … </dev/null` verbatim.
Therefore `--timeout` **is** the ltrace timeout, default 10s. No `--stage-timeout` flag is
added; every other stage's time bound is an internal constant (§7.4).

---

## 2. Target Environment

- Kali Linux VM, XFCE desktop running alongside (~600–800MB OS baseline).
- RAM auto-detected at runtime via `free -m` and mapped to one of three tiers (§5).
- Brief network access available during setup/install; not assumed thereafter.
- Docker required only for `--sandbox`. `systemd-run` preferred for isolation, `ulimit -v`
  is the documented fallback.

---

## 3. Consolidated Decision Summary

| Area | Decision | Source |
|---|---|---|
| Interface | Pure CLI, flags/args; default execution fully autonomous and CI-safe | v3–v5 |
| Language | Bash; Python only for the two Ghidra post-scripts | v3, session |
| Orchestration | Fixed pipeline per file, no pauses by default | v3 |
| File scope | Single file **or** directory (batch) | v3 |
| Target types | ELF, PE, Mach-O, other — **plus** first-class routing for packed, managed (Java/.NET), Python-artifact, and archive/firmware targets | v3 + §4.1 |
| Stage count | **13 analysis stages + 1 triage/unwrap pre-stage** (v3–v5 specified 7) | §4 |
| Report format | Plain text only, stdout + saved file; `--summary-only` condensed view | v3, session |
| Flag detection | On by default; tiered confidence + `--flag-format`; **plus encoding sweep** | v3 + §6 |
| RAM handling | Auto-detected 3-tier system, overridable per-value | v4 |
| Resource isolation | `systemd-run --scope -p MemoryMax=` preferred; `ulimit -v` fallback with report notice | v4 |
| Global watchdog | Kills job tree at 90% of detected RAM; **never prompted** | v4, v5 |
| Swap | Auto-creates 1–2GB when low tier + none active; prompt-gated; `--no-auto-swap` opts out | v4, v5 |
| Batch model | **Three phases, never interleaved** (v3–v5 had two) | §7.2 |
| User agency | Targeted confirmations + `--interactive` guided mode; TTY-gated; `--yes` overrides | v5 |
| Stage errors | Isolate-and-continue; no top-level `set -e`; full diagnostic block per failure | v5 |
| Diagnostics | `--verbose`, `--debug`, persistent `~/.revctf/error.log` (600, 5MB rotation) | v5 |
| Interrupt | Ctrl+C aborts whole run; `trap` cleanup still fires | v5 |
| Display | **Full-screen live TUI on a TTY**, heartbeat lines when redirected, `--no-tui` fallback | session |
| Customization | **`~/.revctf/config` sourced at startup; CLI flags override** | session |
| Optional-tool policy | **`install.sh` installs everything up front; missing at scan time = hard error** | session |

---

## 4. Stage Inventory

### 4.1 Stage 0 — Triage & Unwrap (new)

Runs **before every analysis stage**, per file. Its purpose is to guarantee that
downstream stages analyze the *real* payload rather than a wrapper. This ordering is
load-bearing: running `strings`/`radare2`/Ghidra on a UPX-packed binary or a `.jar`
produces confidently wrong output, which is worse than no output.

| Detection | Action | Tool |
|---|---|---|
| UPX / known packer signature | `upx -d` to a copy in the work dir; downstream stages retarget the unpacked copy; report records both | `upx` |
| PE with CLR header | Route to .NET decompile in Phase 2; skip radare2/Ghidra native path | `ilspycmd` / `monodis` |
| `PK\x03\x04` + `.class` entries, or `.class` magic `CAFEBABE` | Route to Java decompile in Phase 2 | `jd-cli` / `procyon` / `cfr` |
| `.pyc` magic, or PyInstaller/py2exe stub | Extract then decompile in Phase 2 | `pyinstxtractor`, `pycdc` / `uncompyle6` |
| Archive / firmware container | Extract, enumerate contained binaries, analyze each; **recursion depth capped at 2** | `binwalk`, `7z`, `unsquashfs` |

Every unwrap writes to a copy — **the original target file is never modified**. If unwrap
fails, the stage is marked failed per v5 §4.1 and analysis proceeds on the original bytes.
`--no-unwrap` disables the layer entirely (§8, new flag).

### 4.2 Analysis stages

| # | Stage | Phase | Notes |
|---|---|---|---|
| 1 | `file` | 1 | Classifies ELF/PE/Mach-O/other; gates ltrace/strace |
| 2 | `strings` | 1 | `strings -a -n 6`, streamed to disk |
| 3 | `binwalk` | 1 | Numeric major-version branch (`≥3`); output validated, raw-capture fallback |
| 4 | `hexdump` | 1 | 512-byte capped preview; `--full-hexdump` for the complete dump, streamed |
| 5 | `checksec` + `rabin2` | 1 | *New.* NX/PIE/RELRO/canary, imports, exports, sections, libraries |
| 6 | `objdump` / `readelf` | 1 | *New.* Full headers/sections/symbols/relocations; disassembly cross-check |
| 7 | `ltrace` | 1 | `setsid timeout -k 5 10 ltrace -f "$t" </dev/null` + orphan sweep; ELF-only; `--sandbox` routes to Docker |
| 8 | `radare2` | 1 | `\bmain\b` word-boundary before `entry0` fallback; bounded at the tier's r2 ceiling |
| 9 | `strace` + `ldd` | 2 | *New.* Syscall trace complements ltrace; dynamic-linkage listing |
| 10 | FLOSS | 2 | *New.* Deobfuscated / stack / encoded strings |
| 11 | Managed decompile | 2 | *New.* Java or .NET, only when Stage 0 routed here |
| 12 | Python decompile | 2 | *New.* `.pyc` / PyInstaller, only when Stage 0 routed here |
| 13 | `ghidra` headless | 3 | Tier `MAXMEM` + `-XX:MaxRAMPercentage=25`; version-selected post-script; OOM → auto-retry `--light-decompile` |

Stages 5, 6, 9–12 are **new in v6**. Stages 1–4, 7, 8, 13 are v3's original seven, unchanged
in invocation.

---

## 5. RAM Tiers

Detected via `free -m` (`total`) at preflight, resolved once per run, not per file.
**Table carried from v4 §3 unchanged.**

| Tier | RAM range | Phase-1 concurrency | radare2 ceiling | Phase-2 / Phase-3 concurrency | Ghidra `MAXMEM` | Decompile default |
|---|---|---|---|---|---|---|
| **A** | ≥ 3.8GB | `-P 4` | 640MB | `-P 2` | 1024M | Full Ghidra decompile |
| **B** | 2.5–3.8GB | `-P 2` | 450MB | `-P 1` | 768M | Full Ghidra decompile |
| **C** | < 2.5GB | `-P 1` | 400MB | `-P 1`, only if forced | 512M | **`--light-decompile` (auto)** |

All tiers carry `-XX:MaxRAMPercentage=25` alongside `MAXMEM`, and use
`systemd-run --scope -p MemoryMax=<ceiling>` for every bounded process where available.

**Tier C:** Ghidra is skipped by default, replaced with a radare2-only disassembly pass.
`--force-full-decompile` overrides, still at `-P 1` / `MAXMEM=512M`.

**Phase-2 budget (new, derived).** Phase 2's per-job memory ceiling is set to the tier's
Ghidra `MAXMEM` value, and Phase 2 runs at the tier's Ghidra concurrency. This is
deliberate: it means Phase 2's worst-case aggregate footprint is *identical* to Phase 3's,
which v3 §8 and v4 §3 already derived and sized. No new memory derivation is required and
the existing tier numbers remain valid untouched — the only cost is that Phase 2 and
Phase 3 cannot overlap, which the three-phase model already guarantees (§7.2).

**Overrides:** `--jobs-light N`, `--jobs-ghidra N` (applies to Phases 2 and 3),
`--maxmem-ghidra M`.

---

## 6. Flag Detection

### 6.1 Confidence tiers

**High** — any of the known formats below, plus any `--flag-format REGEX` the user supplies.
**Low** — generic `[A-Za-z0-9_]{2,}\{[^}]{1,200}\}` bracket fallback.
High-confidence results are listed first. Results are deduplicated across all stages.

Known High-confidence formats:

- **Generic wrappers:** `flag{…}`, `FLAG{…}`, `ctf{…}`, `CTF{…}`
- **Platform prefixes:** `HTB{`, `THM{`, `picoCTF{`, `pico{`
- **Competition/vendor prefixes:** `DUCTF{`, `uiuctf{`, `corctf{`, `SEE{`, `csawctf{`, `justCTF{`
- **Hash/key-style (unwrapped):** bare 32/40/64-char hex, and `[A-Za-z0-9_-]{20,}` tokens

> **Ranking caveat.** Hash/key-style patterns match ELF build IDs, GUIDs, embedded
> checksums and CRC tables — a normal binary yields dozens. They are retained in the
> known-format set per the session decision, but the report **ranks braced matches above
> unwrapped ones** within the High tier, so the flag section stays scannable. This is a
> presentation-order decision only; nothing is dropped.

### 6.2 Encoding sweep (new)

After the direct regex pass, candidate tokens from every stage's captured output are
decoded and re-scanned:

- base64, base32, hex, ROT13 (and ROT-n where cheap)
- Decode is attempted only on tokens meeting a plausibility filter (length + charset), to
  avoid decoding the entire `strings` output
- A hit found via decoding is reported at the confidence tier its **decoded** form earns,
  annotated with the encoding and the originating stage

### 6.3 Cross-stage attribution

Every candidate records which stage produced it (strings, FLOSS, Ghidra pseudo-C, ltrace
call args, radare2 disassembly, …). `--no-flag-scan` disables the whole subsystem.

---

## 7. Execution Model

### 7.1 Per-file pipeline (single-file mode)

Stage 0 triage/unwrap → Phase-1 stages in order → Phase-2 stages → Phase-3 Ghidra →
flag scan → report assembly.

### 7.2 Batch model — three phases (changed from two)

v3–v5 specified two phases, and stated the reason plainly: the two phases never compete
for memory, which is what makes independent per-phase concurrency safe. v6 preserves that
guarantee by adding a phase rather than by widening one.

1. **Phase 1 — light static + ltrace.** Triage/unwrap and stages 1–8, at the tier's
   `-P N`, per-job `mktemp -d` isolation, `flock`-protected results file. Completes fully
   across the whole batch before Phase 2 starts.
2. **Phase 2 — heavy extras.** Stages 9–12 (strace, FLOSS, managed and Python decompile)
   at the tier's Ghidra concurrency and per-job ceiling. Completes fully before Phase 3.
3. **Phase 3 — Ghidra.** Stage 13, at the tier's Ghidra concurrency.

Final run summary (files scanned / flags found / stages failed) is merged only after all
three phases finish. Per-file failure isolation: one bad file never stops the batch.

### 7.3 Error isolation

Per v5 §4.1, unchanged. Each stage runs inside its own `ERR`-trapped boundary; no blanket
top-level `set -e`. A failure is marked `STAGE FAILED: <name>` in the report with the full
diagnostic block (command + args, exit code or signal name, stderr tail, file, stage,
timestamp, suggested next step), appended to `~/.revctf/error.log`, and execution moves on.
Only the RSS watchdog and an explicit user abort stop a run outright.

### 7.4 Internal time bounds

`--timeout` is the ltrace bound (default 10s) and is the **only** user-facing time control,
per §1. Other stages carry internal constants:

| Stage | Bound |
|---|---|
| strace | 10s (matches ltrace; same hang-risk profile) |
| Unwrap / UPX | 60s |
| radare2 | 120s |
| Managed / Python decompile | 180s |
| FLOSS | 300s |
| Ghidra headless | 1800s |

Ghidra previously had no time bound at all (only memory bounds). The 1800s ceiling is a new
safety addition — a Ghidra run that exceeds it is marked failed with the standard diagnostic
block rather than hanging a batch indefinitely.

---

## 8. CLI Surface

```
revctf scan <file|dir>
  # Output & reporting
  [--output DIR] [--summary-only] [--dry-run]
  # Flag detection
  [--no-flag-scan] [--flag-format REGEX]
  # Analysis depth / stage control
  [--full-hexdump] [--skip-ltrace] [--skip-strace] [--skip-ghidra] [--no-unwrap]
  [--light-decompile] [--force-full-decompile] [--ghidra-script PATH]
  # Resource tuning
  [--timeout SECONDS] [--jobs-light N] [--jobs-ghidra N]
  [--maxmem-ghidra M] [--no-auto-swap]
  # Sandboxing
  [--sandbox]
  # Agency & interactivity
  [--interactive|-i] [--yes|-y]
  # Display & config
  [--no-tui] [--config PATH] [--strict]
  # Diagnostics
  [--verbose] [--debug]
  [-h]
```

**New in v6:** `--no-unwrap`, `--no-tui`, `--config`. Everything else is v5 §6 verbatim.

**Defaults:** `--output` → `./revctf-reports/<basename>-<timestamp>/`; `--timeout` → 10;
hexdump preview → 512 bytes.

**Per-stage disabling.** v5 §3.4 grants `--skip-ltrace` and `--skip-ghidra` only, with the
other original stages mandatory. v6 does not add a skip flag per new stage — that would
bloat the surface to 19 flags. The six new stages are toggled through the config file's
stage-enable list (§9), and `--interactive` mode's per-stage Skip option covers ad-hoc
cases, exactly as v5 §3.2 intended.

---

## 9. Configuration File

`~/.revctf/config`, sourced at startup if present. **Precedence: built-in defaults →
config file → CLI flags.** `--config PATH` selects an alternate file.

Settable: default flag format, tier value overrides, enabled/disabled stage list, default
output directory, TUI on/off, default `--sandbox` behavior, unwrap recursion depth.

Because it is sourced Bash, the file is validated on load: only a known key allowlist is
honored and anything else is reported as a warning. This keeps a stray line in a config
file from silently changing what a scan does.

---

## 10. Display Model

Three display modes, auto-selected:

| Condition | Mode |
|---|---|
| TTY attached, `--no-tui` not set | **Full-screen live TUI** — stage table with per-stage status, elapsed time, running flag count. In `--interactive`, the 4-option prompt (`[C]ontinue / [S]kip stage / s[K]ip file / [A]bort`) renders in a fixed bottom pane while the table stays live. |
| Output redirected / non-TTY | **Heartbeat lines**, per v5 §5 — e.g. `[ghidra] still analyzing chall.bin... 45s elapsed` roughly every 15s |
| `--no-tui` on a TTY | **Line mode** — v5 §5's spinner + elapsed time on stderr |

`lib/tui.sh` is isolated behind a narrow interface (`tui_init`, `tui_stage_update`,
`tui_prompt`, `tui_teardown`) with line mode as the always-available fallback, so a TUI
defect can degrade the display but never cost a scan or corrupt a report. The report **file**
is plain text with no escape sequences in every mode.

---

## 11. Deviation Register

Ten documented departures from v3/v4/v5. D1–D9 were decided during the design session;
D10 was decided after QA review #2, once the build existed to argue about.

| # | Deviation | Contradicts | Rationale |
|---|---|---|---|
| D1 | Full-screen live TUI, including during `--interactive` | v3 §7 and v4 §9 "No TUI/interactive mode"; v5 §5 spinner/heartbeat model | Chosen for at-a-glance batch visibility. Mitigated by isolation behind `lib/tui.sh` + `--no-tui` line-mode fallback, and heartbeat mode still applies when redirected. **Frozen after QA review #2:** bug fixes only, enforced by a line-count ceiling in the harness. Deletion trigger — a second dedicated debugging session — is recorded in the file header, along with the fact that deleting it costs only the in-place table. |
| D2 | Six added stages (checksec/rabin2, objdump/readelf, strace/ldd, FLOSS, managed decompile, Python decompile) | v3 §7 / v4 §9 "fixed 7-tool pipeline", "no general modular tool selection" | The original seven cover native ELF/PE well and managed/obfuscated targets poorly — a large share of real RE-CTF challenges. v5 already breached "no modular selection" with `--skip-*`. |
| D3 | Stage 0 triage/unwrap layer, on by default | No prior document | Running the pipeline on a packed binary or a `.jar` yields confidently wrong output. Must precede all analysis to be useful. Never modifies the original file; `--no-unwrap` opts out. |
| D4 | Two-phase batch model becomes three-phase | v3 §4.2, v4 §9 "No change to the two-phase batch model" | Preserves the *reason* for the two-phase rule (heavy consumers never overlap) while accommodating D2's new heavy stages. Phase 2 reuses the tier's Ghidra ceiling, so v3 §8's derivation stays valid unmodified. |
| D5 | Encoding sweep added to flag detection | v3 §11 / v4 §13 tiered regex only | Base64-in-`.rodata` is among the most common RE-CTF flag hiding techniques; the regex-only scan misses it entirely. |
| D6 | `~/.revctf/config` configuration file | v3–v5 flags-only surface | Keeps the CLI from growing a flag per new stage while still allowing persistent per-user defaults. Allowlist-validated on load. |
| D7 | Optional tools are `install.sh`'s responsibility; missing at scan time is a hard error | v3–v5 only preflight the core 7 | Makes runtime behavior predictable — a scan either has its full declared toolchain or tells you to re-run `install.sh`, rather than silently producing a thinner report. Core-7 preflight per v5/M1 is unchanged. |
| D10 | **Auto-swap removed entirely**, replaced by a diagnostic | v4 §3 and v5 §3.1 ("auto-creates a 1–2GB swap file when none exists and RAM is low"), and the `--no-auto-swap` flag in v4 §9's new-flag list | Creating a swap file and writing `/etc/fstab` is a system-administration action; revctf reads a binary and writes a report. It needs privilege, mutates the host persistently, and is not what a CTF player expects an analysis tool to do. v5 gated it behind a prompt, which concedes the discomfort without resolving it — and the prompt layer is M8, so every Tier C user before M8 would have got the mutation unprompted. The underlying risk (Ghidra OOM-killed on a small host) is real, so it is now **named rather than acted on**: on Tier B/C with no active swap, `tier_resolve` reports the risk, gives both remedies (`--skip-ghidra`, or add swap yourself) and states that revctf will not modify your system. Removed: `lib/swap.sh`, `--no-auto-swap`, the `auto_swap` config key. CLI surface 28 → 27 flags. Two harness tripwires fail the build if it reappears, because v4 and v5 both still specify it. |

---

## 12. Repo Layout

```
revctf/
├── revctf                        # main entry script (bash), chmod +x
├── lib/
│   ├── preflight.sh              # tools + versions + RAM tier + systemd-run test + disk + swap
│   ├── config.sh                 # NEW — ~/.revctf/config load + allowlist validation
│   ├── tier.sh                   # RAM-tier resolution + override handling
│   ├── watchdog.sh               # global RSS monitor, kills job tree on breach
│   ├── swap.sh                   # auto-swap creation (prompt-gated)
│   ├── prompt.sh                 # TTY detection, prompt display, per-run memoization
│   ├── errorlog.sh               # structured diagnostics + persistent log + rotation
│   ├── tui.sh                    # NEW — TUI / line / heartbeat display modes
│   ├── spinner.sh                # line-mode spinner + heartbeat (fallback path)
│   ├── stage_triage.sh           # NEW — detection + unwrap routing (Stage 0)
│   ├── stage_file.sh
│   ├── stage_strings.sh
│   ├── stage_binwalk.sh
│   ├── stage_hexdump.sh
│   ├── stage_checksec.sh         # NEW — checksec + rabin2 metadata
│   ├── stage_objdump.sh          # NEW — objdump + readelf
│   ├── stage_ltrace.sh
│   ├── stage_radare2.sh
│   ├── stage_strace.sh           # NEW — strace + ldd
│   ├── stage_floss.sh            # NEW
│   ├── stage_managed.sh          # NEW — Java / .NET decompile
│   ├── stage_pydecomp.sh         # NEW — .pyc / PyInstaller
│   ├── stage_ghidra.sh
│   ├── flagscan.sh               # tiered regex + encoding sweep + attribution
│   └── report.sh                 # blurbs, markers, flag section, permission hardening
├── scripts/
│   ├── pyghidra_decompile.py     # Ghidra 11.x+
│   └── jython_decompile.py       # Ghidra 10.x and earlier
├── docker/
│   └── Dockerfile                # minimal image with ltrace + timeout
├── implementation-notes.md       # per execution masterplan §4
├── README.md
└── install.sh                    # PATH symlink + Docker image + all optional tooling (D7)
```

`~/.revctf/` holds `config`, `error.log` (600, 5MB rotation) and `error.log.1` — outside
the repo and outside any report directory, since they persist across runs and targets.

---

## 13. What Will Not Change

- No full-pipeline containerization — `--sandbox` isolates only the `ltrace` step.
- Default invocation (no flags) stays fully autonomous, non-interactive and CI-safe.
- The RSS watchdog's authority to kill without prompting is reaffirmed (v5 §3.1).
- Heavy memory consumers never run concurrently across phase boundaries (D4 preserves this).
- Report output stays plain text. No Markdown, HTML or JSON emitters.
- The original target file is never modified by any stage, including unwrap.

---

## 14. Residual Risks

Carried forward from v4 §10 and v5 §10 (systemd-run availability, watchdog polling gap,
auto-swap touching `/etc/fstab`, unvalidated tier boundaries, TTY-detection edge cases,
prompt memoization coarseness, silently-failed stages in a "successful" run), plus:

- **The TUI is the highest-defect-density component** in the project — redraw, terminal
  resize, output interleaving and signal handling are all hard in pure Bash. Mitigated by
  D1's isolation and fallback, but expect this to need the most iteration.
- **Unwrap can pick the wrong payload.** A binary that is both packed and an archive, or a
  polyglot file, may route down a single path and miss the other. Depth cap of 2 bounds the
  blast radius; the report always states what unwrap did so the choice is visible.
- **Hash/key-style flag patterns are noisy by construction** (§6.1) — ranking mitigates but
  does not eliminate this.
- **Optional-tool hard-fail (D7) makes a fresh clone unusable until `install.sh` runs.**
  That is the intended contract, but it is a sharper edge than v3–v5's soft preflight.
- **Phase 2's ceiling is inherited, not independently derived.** It is safe because it
  matches Phase 3's already-tested profile, but FLOSS's real memory behavior on a large
  binary should be measured rather than assumed.

---

## 15. Approval Gate

This is the consolidated build spec. Milestone order, DoD gates and verification steps
remain as written in `revctf_executionmasterplan.md`, with M2 and M3 expanded to absorb
D2/D3 and M7 expanded to absorb D4.

Reply **`implement`** to begin at **M0 — Foundation & Scaffolding**, or specify changes first.
