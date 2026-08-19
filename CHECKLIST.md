# revctf — Development Checklist

Generated companion to `revctf-checklist.html`. Milestones refer to
`revctf_executionmasterplan.md`; this file is the source of truth for status.

**84 tracked items** — 48 done · 25 pending · 5 open risk · 6 deferred.
Milestones M0–M4 complete of M0–M9 (tag v0.1-mvp). Verification harness: 262 checks, all green.

Legend: `[x]` done · `[ ]` pending · `[!]` open risk · `[-]` deferred (decided against).

---

## Phase 1 — Design & Specification  — 8/8

Requirements, architecture and the decisions everything else is built on.

- [x] **Requirements captured (v3): tool set, report format, RAM target, batch model**
  <br>revctfmasterplanv3.md
- [x] **Adaptive RAM tiers + RSS-accurate isolation designed (v4)**
  <br>revctfmasterplan_v4.md §3
- [x] **User agency + crash resilience designed (v5)**
  <br>revctfmasterplan_v5.md
- [x] **Execution roadmap: M0–M9, DoD gates, dependency order**
  <br>revctf_executionmasterplan.md
- [x] **Consolidated current-state spec written; document precedence rule fixed**
  <br>revctfmasterplan_v6.md §1
- [x] **Deviation register maintained (D1–D9) with rationale per departure**
  <br>M: ongoing · v6 §11
- [x] **Standing engineering conventions recorded for cold sessions**
  <br>CLAUDE.md §2
- [x] **Three-phase batch model defined (was two) to fit the added heavy stages**
  <br>v6 §7.2 / D4

## Phase 2 — Foundation  — 8/8

Repo, CLI surface, dependency discovery and the test corpus everything is verified against.

- [x] **M0 · Repo scaffold, entry script, module layout, .gitignore**
  <br>M: M0 · commit 4d174bd
- [x] **M0 · Full 25-flag CLI surface with conflict validation**
  <br>M: M0 · revctf --help
- [x] **M0 · Config file with defaults→config→flags precedence + allowlist**
  <br>M: M0 · ~/.revctf/config
- [x] **M0 · Test corpus generator — 18 verified artifacts, 4 groups**
  <br>M: M0 · tools/build-test-corpus.sh
- [x] **M1 · Two-tier tool registry; core hard-fails, conditional fails lazily**
  <br>M: M1 · lib/preflight.sh
- [x] **M1 · Ghidra discovery (PATH → GHIDRA_HOME → install root), newest wins**
  <br>M: M1 · pf_find_ghidra
- [x] **M1 · Post-script runtime detected by probing, not version number**
  <br>M: M1 · corrected v3 §1: boundary is 11.3
- [x] **M1 · binwalk version branch, systemd-run probe, disk check**
  <br>M: M1 · commit bc11182

## Phase 3 — Core Analysis Engine  — 9/9

The stage framework and all 13 analysis stages.

- [x] **M2 · Stage framework: contract, streaming capture, error boundary, time bounds**
  <br>M: M2 · lib/stage.sh
- [x] **M2 · Stage 0 triage/unwrap: classify + UPX/archive/managed/Python routing**
  <br>M: M2 · lib/stage_triage.sh
- [x] **M2 · Light static stages: file, strings, binwalk, hexdump, checksec, objdump**
  <br>M: M2 · 6 modules
- [x] **M3 · Dynamic stages: ltrace + strace, setsid, orphan sweep, execution banner**
  <br>M: M3 · lib/stage_dynamic.sh
- [x] **M3 · radare2 — single analysis session, \bmain\b word boundary, entry0 fallback**
  <br>M: M3 · lib/stage_radare2.sh
- [x] **M3 · FLOSS — format-aware (PE all modes, ELF static-only), size-guarded**
  <br>M: M3 · lib/stage_floss.sh
- [x] **M3 · Managed + Python decompilation, with an always-available bytecode fallback**
  <br>M: M3 · stage_managed / stage_pydecomp
- [x] **M3 · Ghidra headless + both post-scripts + OOM self-heal**
  <br>M: M3 · verified on real 11.2.1
- [x] **M3 · Flag detection: confidence tiers, cross-stage attribution, encoding sweep**
  <br>M: M3 · lib/flagscan.sh

## Phase 4 — MVP Gate (M4)  — 8/8

The milestone at which the tool is genuinely usable end to end. Currently the active work.

- [x] **M4 · lib/report.sh — beginner blurbs, raw output, found/failed/empty markers**
  <br>M: M4 · lib/report.sh · per-stage blurbs
- [x] **M4 · Flag section at the top of the report, ASCII [FLAG] fallback**
  <br>M: M4 · harness asserts flags precede the table
- [x] **M4 · lib/tui.sh — in-place stage table on TTY, SIGWINCH re-measure, truncation**
  <br>M: M4 · prompts pane deferred to M8
- [x] **M4 · --no-tui line mode + heartbeat when redirected**
  <br>M: M4 · 3 modes; all progress on stderr
- [x] **M4 · Report file naming, stdout mirroring, 700/600 permissions**
  <br>M: M4 · stdout byte-identical to report.txt
- [x] **M4 · --summary-only ordering (flags first, condensed status lines)**
  <br>M: M4 · keeps flags/table/diagnostics
- [x] **M4 · Config loader extracted to lib/config.sh for batch subshells**
  <br>M: M4 · registry + config_coerce
- [x] **M4 · GATE: single-file autonomous run produces a complete report on all corpus files**
  <br>M: M4 · 188 checks green · tagged v0.1-mvp

## Phase 5 — Resource, Safety & Scale  — 2/13

Everything after the MVP: adaptivity, isolation, batch, agency, resilience.

- [x] **M5 · lib/tier.sh — RAM detection, Tier A/B/C, per-value overrides**
  <br>M: M5 · resolved + reported; limits not yet enforced
- [ ] **M5 · Re-derive Phase-2 ceiling from the measured FLOSS peak, not Ghidra's**
  <br>M: M5 · BLOCKS M5 — see Risks
- [ ] **M5 · systemd-run --scope MemoryMax with ulimit -v fallback + report notice**
  <br>M: M5 · probe already implemented
- [ ] **M5 · lib/watchdog.sh — global RSS monitor, kills job tree at 90%**
  <br>M: M5 · never prompted, by design
- [x] **M5 · Low-RAM/no-swap diagnostic (auto-swap REMOVED, D10)**
  <br>M: M5 · lib/tier.sh · revctf never modifies the host
- [ ] **M6 · docker/Dockerfile built by install.sh during the network window**
  <br>M: M6 · --sandbox currently refuses
- [ ] **M6 · Sandboxed ltrace AND strace; verify no network egress**
  <br>M: M6 · deviation D9
- [ ] **M7 · Batch mode — three-phase concurrency, per-job isolation, flock results**
  <br>M: M7 · directory target exits 1 today
- [ ] **M7 · Per-file failure isolation + merged run summary**
  <br>M: M7
- [ ] **M8 · lib/prompt.sh — TTY detection, per-run answer memoization**
  <br>M: M8
- [ ] **M8 · --interactive guided mode; wire confirmations to sandbox/OOM retry**
  <br>M: M8 · marked [NOT YET: M8] in --help
- [ ] **M9 · lib/errorlog.sh — structured diagnostics, persistent log, 5MB rotation**
  <br>M: M9
- [ ] **M9 · lib/spinner.sh, --verbose/--debug plumbing, full SIGINT abort semantics**
  <br>M: M9 · abort semantics partly done

## Phase 6 — QA Process (recurring, every milestone)  — 9/11

Run this block for M5 through M9. It is what kept M0–M4 honest.

- [x] **shellcheck -S style clean across every shell file**
  <br>M: M0–M4 · asserted by the harness
- [x] **Verification harness green before advancing past a DoD gate**
  <br>M: M0–M4 · 188 checks
- [x] **New milestone adds its own harness section; earlier gates re-run**
  <br>M: M0–M4 · lint/corpus/m0/m1/m2/m3/m4/qa/ghidra
- [x] **Adversarial QA pass — security, fault tolerance, load, error handling**
  <br>M: pre-M3 · 16 defects, all fixed
- [x] **Every QA finding pinned by a regression check so it cannot return**
  <br>M: pre-M3 · qa section, 32 checks
- [x] **Findings and rejected approaches appended to implementation-notes.md**
  <br>M: M0–M4 · ongoing discipline
- [x] **Commit at each green gate; tag the named checkpoints**
  <br>M: M0–M4 · v0.2-m2-qa · v0.1-mvp
- [x] **Repeat the full QA block for M4 (report + TUI)**
  <br>M: M4 · 30 m4 checks; TTY gap covered by tui-selftest.sh
- [ ] **Repeat for M5–M9; add tier/sandbox/batch/agency/resilience sections**
  <br>M: M5–M9
- [ ] **Second adversarial pass before v1.0, covering the M4–M9 surface**
  <br>M: pre-v1.0
- [x] **Stability: 3 consecutive clean full runs, zero residue**
  <br>M: pre-M3 · re-run before v1.0

## Phase 7 — Deployment & Release Readiness  — 2/12

What has to be true before calling it v1.0.

- [ ] **install.sh completed — full toolchain, venv FLOSS, Docker image**
  <br>M: M1/M6 · skeleton only
- [ ] **Vendor pyinstxtractor (not packaged anywhere)**
  <br>M: M6 · unwrap fails cleanly today
- [ ] **Package a Java decompiler — none installable in the build sandbox**
  <br>M: M6 · managed stage unverified on a real .jar
- [x] **Cloud-environment setup script within the 5-minute budget**
  <br>.claude/cloud-setup.sh
- [ ] **Create the private GitHub repo and push (first push must be yours)**
  <br>sandbox token cannot create repos
- [ ] **Connect the Claude GitHub App for automated pushes at v1.0**
  <br>M: v1.0 · hybrid plan
- [x] **README, CHANGELOG, CLAUDE.md and notes current at each milestone**
  <br>M: M0–M4 · re-verify per milestone
- [ ] **README documents every flag, tier table, agency model, diagnostics**
  <br>M: M9 · partially done
- [ ] **Tag v0.1-mvp at the M4 gate**
  <br>M: M4 · fallback-good-state
- [ ] **Tag v1.0 at the M9 gate**
  <br>M: M9
- [ ] **Acceptance run against a real, unseen CTF challenge before v1.0**
  <br>M: pre-v1.0 · the corpus is synthetic
- [ ] **Verify on the actual Kali VM, not just the build sandbox**
  <br>M: pre-v1.0 · target environment

## Phase 8 — Known Risks & Open Questions  — 2/9

Each is tracked to the milestone that resolves it. Two are load-bearing.

- [!] **Phase-2 memory ceiling: FLOSS peaks ~1.46GB, disproving v6 §5's inheritance assumption**
  <br>Risk · M: M5 · exceeds Tier A 1024M, ~3x Tier C
- [!] **Tier boundaries 3.8GB / 2.5GB are unvalidated estimates (v4 §10)**
  <br>Risk · M: M5 · a version boundary was already wrong once
- [!] **Ghidra's 1800s time bound is a guess, never tested on a slow-path binary**
  <br>Risk · M: M4/M5 · no prior plan bounded it at all
- [!] **TUI is the highest-defect-density component; redraw + resize + signals in Bash**
  <br>Risk · M: M4 · isolated behind --no-tui fallback
- [!] **Polyglot targets (packed AND archive) route down one path only**
  <br>Risk · M: M7 · depth cap bounds the damage
- [ ] **Archive members extracted but not yet analysed individually**
  <br>M: M7 · belongs with batch orchestration
- [x] **Auto-swap mutating /etc/fstab — RESOLVED by removing the feature (D10)**
  <br>M: M5 · diagnostic replaces it; revctf never modifies the host
- [x] **SIGINT untrappable when backgrounded from a non-interactive shell**
  <br>POSIX; documented, SIGTERM works
- [ ] **D7 two-tier interpretation (startup vs lazy tool checks) flagged for review**
  <br>one-line change if wrong

## Phase 9 — Deferred / Out of Scope  — 0/6

Decided against. Recorded so they are not re-litigated or mistaken for gaps.

- [-] **Intra-file stage concurrency — invalidates v3 §8's memory derivation**
  <br>Deferred · parallelism belongs at batch level
- [-] **Markdown / HTML / JSON report emitters — plain text only**
  <br>Deferred · explicit scope decision
- [-] **Named profiles (--profile quick|deep) — config file covers the need**
  <br>Deferred
- [-] **Drop-in custom stages (~/.revctf/stages.d/)**
  <br>Deferred
- [-] **Full-pipeline containerization — sandbox covers executing stages only**
  <br>Deferred · v3–v5 constant
- [-] **A --stage-timeout flag — v5's CLI surface is authoritative**
  <br>Deferred · internal constants instead

---

_Status is maintained here. The HTML tracker renders this same data; its checkboxes
are a scratch view for the current browser session only and are not persisted._
