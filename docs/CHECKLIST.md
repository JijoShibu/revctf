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
  <br>M: M3 · lib/stage_dynamic.sh · **re-verified 2026-08-21 — was NOT complete when
  signed off.** Both tracers write to stderr unless given `-o`; without it the trace went
  to the stage error file, which the report reads only on failure. The captures held the
  banner plus the target's own stdout, so **these two stages produced no trace at all** and
  M3's DoD ("all 13 stages run end to end") was false for them. Every ltrace/strace check
  in the harness matched the banner or a skip path. Fixed with `-o` + `dyn_compose`;
  the harness now asserts a real traced call appears.
- [x] **M3 · radare2 — single analysis session, \bmain\b word boundary, entry0 fallback**
  <br>M: M3 · lib/stage_radare2.sh
- [x] **M3 · FLOSS — format-aware (PE all modes, ELF static-only), size-guarded**
  <br>M: M3 · lib/stage_floss.sh
- [x] **M3 · Managed + Python decompilation, with an always-available bytecode fallback**
  <br>M: M3 · stage_managed / stage_pydecomp · `stage_pydecomp` launched its tool outside
  `st_run_bounded` until 2026-08-21, so neither its memory ceiling nor the `ulimit -f`
  output cap applied
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
  <br>M: M5 · resolved, reported AND enforced
- [x] **M5 · Re-derive Phase-2 ceiling from the measured FLOSS peak, not Ghidra's**
  <br>M: M5 · deviation D11 · 1536/1024/512MB, measured on the Kali VM
- [x] **M5 · systemd-run --scope MemoryMax with ulimit -v fallback + report notice**
  <br>M: M5 · ENFORCED in st_run_bounded · systemd path executed for the first time
- [x] **M5 · lib/watchdog.sh — global RSS monitor, kills job tree at 90%**
  <br>M: M5 · fires, spares revctf, partial report still written
- [x] **M5 · Low-RAM/no-swap diagnostic (auto-swap REMOVED, D10)**
  <br>M: M5 · lib/tier.sh · revctf never modifies the host
- [x] **Mutation-test the verification harness (`tools/verify-harness.sh`)**
  <br>2026-08-21 · five mutations; found four product defects and five vacuous flag checks
- [x] **M6 · docker/Dockerfile built by install.sh during the network window**
  <br>2026-08-26 · `step_sandbox` in install.sh; non-fatal, and it names the `docker` group
  when membership is what is actually wrong. Verified from a fresh clone.
- [x] **M6 · Sandboxed ltrace AND strace; verify no network egress**
  <br>2026-08-26 · `lib/sandbox.sh`; ON by default (D13), covers both executing stages (D9).
  Egress is proven by a probe run through `sbx_wrap`'s own argv, with a `--network=bridge`
  positive control that must succeed first — it SKIPs rather than passes on a host that
  cannot demonstrate egress. The `sandbox_bypass` mutation deletes `--network=none` and all
  three checks flip. Written the obvious way (retyping the flags in the check) it stayed
  green under that mutation: it tested Docker, not revctf.
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

- [x] **install.sh completed — full toolchain, venv FLOSS** (Docker image still M6)
  <br>M: M1/M6 · skeleton only
- [x] **pyinstxtractor** — fetched by `install.sh` into `scripts/`, with a `scripts/`
      fallback in `lib/stage_triage.sh`. NOT vendored into the repo: it is GPLv3 and revctf
      declares no licence, so committing it would decide revctf's licensing as a side
      effect. See `implementation-notes.md` § M6.
  <br>M: M6 · unwrap fails cleanly today
- [ ] **Package a Java decompiler — none installable in the build sandbox**
  <br>M: M6 · managed stage unverified on a real .jar
- [x] **Cloud-environment setup script within the 5-minute budget**
  <br>.claude/cloud-setup.sh
- [x] **Create the GitHub repo and push**
  <br>github.com/JijoShibu/revctf · main and tags through v1.0.0 pushed
- [ ] **Connect the Claude GitHub App for automated pushes at v1.0**
  <br>M: v1.0 · hybrid plan
- [x] **README, CHANGELOG, CLAUDE.md and notes current at each milestone**
  <br>M: M0–M4 · re-verify per milestone
- [x] **README documents every flag, tier table, agency model, diagnostics**
  <br>The `docs` harness section asserts `--help` and README agree: every flag is either
  exercised by the harness or marked `[NOT YET: Mn]`/`[PARTIAL: Mn]` in **both**. There is
  no third state in which a flag can quietly do nothing.
- [x] **Tag v0.1-mvp at the M4 gate**
  <br>v0.1-mvp
- [x] **Tag v1.0 — at the M6 gate, not M9**
  <br>2026-08-26 · v1.0.0. M7/M8/M9 are post-1.0 and marked as such in `--help`, README and
  the tag message. The sandbox is safety and batch mode is convenience, so M6 was the
  right line to draw for a 1.0.
- [x] **Acceptance run against a real, unseen CTF challenge before v1.0**
  <br>picoCTF 2022 `unpackme-upx` and `bbbbloat`, scored against criteria written down
  BEFORE the run. Both initially scored 0 high-confidence candidates — the flags were stack
  strings, which `strings` cannot see and FLOSS only looks for on PE. That gap is what
  `scripts/le_decode.py` closes; both flags now land at HIGH, re-verified under the sandbox.
- [x] **Verify on the actual Kali VM, not just the build sandbox**
  <br>M5 onward was built on the VM — the first time `systemd-run --scope -p MemoryMax`
  ever executed in this project. M6's Docker contract was verified there too.
- [ ] **`./tools/tui-selftest.sh` on a real terminal** — OUTSTANDING AT v1.0.0, and named
  as outstanding in the tag message.
  <br>The script hard-exits 1 unless stdin AND stdout are TTYs, and five of its six checks
  are human judgements about what the screen looked like: did a resize tear the table, did
  the cursor come back after Ctrl+C, did long notes truncate or wrap. `script(1)` can fake
  the pty but cannot answer those, and piping `y` would fabricate a pass indistinguishable
  from a real one. A fabricated pass is worse than an open gate.
- [ ] **Clean-VM install rehearsal** — OUTSTANDING AT v1.0.0. Procedure: `REHEARSAL.md`.
  <br>`install.sh` has run end-to-end exactly once, on a machine that already had the whole
  toolchain — so that run could not detect a missing dependency, because nothing was
  missing. It already hid one: `curl`, `ca-certificates` and `python3-venv` are needed by
  install.sh's own steps (the Ghidra fetch and the FLOSS venv) and it never installed them.
  Found by reading, fixed 2026-08-28, still unproven. Revert the VM to a pre-revctf
  snapshot, clone from GitHub, `sudo ./install.sh`, build the corpus, run the suite, scan
  `unpackme-upx`. This is the only test that proves the documented deployment path works.

- [ ] **`./tools/verify-tier-c.sh` on a real 2048MB boot** — OUTSTANDING AT v1.0.0, and
  named as outstanding in the tag message.
  <br>Confirmed refusing on 2026-08-26: "This host has 3917MB — that is Tier A, not Tier C."
  It refuses above 2560MB by design, so it cannot be satisfied by `REVCTF_RAM_MB` injection.
  The reboot is the whole point of the check.

## Phase 8 — Known Risks & Open Questions  — 2/9

Each is tracked to the milestone that resolves it. Two are load-bearing.

- [!] **Phase-2 memory ceiling: FLOSS peaks ~1.46GB, disproving v6 §5's inheritance assumption**
  <br>RESOLVED · M: M5 · D11 sizes Phase 2 from its own measurement
- [!] **upx 4.2.4 unpacks PIE, so `packed_upx_broken` no longer forces a stage failure**
  <br>Risk · M: M5 · 6 harness checks depend on that fixture failing; needs a version-independent trigger
- [!] **Tier A `-P 2` cannot afford two concurrent Phase-2 jobs (2x1536 > 2946MB usable)**
  <br>Risk · M: M7 · Phase-2 concurrency must decouple from Phase-3 · recorded in D11
- [x] **install.sh run end-to-end on real Kali (2026-08-20)** — 4 defects found and fixed
  <br>M: M5 · $HOME-under-sudo, unconditional escalation, unchecked ln, "latest" Ghidra
- [!] **PyGhidra post-script has never run against a real PyGhidra (Ghidra 12.x headless)**
  <br>Risk · M: M6+ · Ghidra pinned to 11.2.x meanwhile; `support/pyghidraRun` is GUI-only
- [x] **ghidra harness section asserts the decompile output, not just that Ghidra runs**
  <br>M: M5 · was vacuous; v0.3-m5 was tagged against it · now asserts sw0rdf1sh
- [!] **Tier boundaries 3.8GB / 2.5GB are unvalidated estimates (v4 §10)**
  <br>Risk · M: M5 · STILL UNMEASURED · the 4GB VM lands 26MB inside Tier A
- [!] **Tier B/C never entered on hardware that really has that much RAM**
  <br>Risk · M: M5 · REVCTF_RAM_MB tests the branch, never the behaviour. Boot the VM at 2048MB to close QA-REVIEW-2 §7's "forced 2GB host" criterion
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
