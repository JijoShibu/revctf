#!/usr/bin/env bash
#
# verify-tier-c.sh — close the one M5 exit criterion that injection cannot close.
#
# WHAT THIS IS FOR
# ----------------
# Every Tier C check in tools/run-tests.sh sets REVCTF_RAM_MB=2000 or 2048. That tests the
# BRANCH: given the number 2048, is the right tier chosen and the right ceiling printed?
# It cannot test the BEHAVIOUR, because the host it runs on has 4GB and never once has to
# survive at 2GB. QA review #2 §7 asks for the other half — correct tier selection, and
# correct degradation, on hardware that genuinely has that much memory — and it is the
# only M5 exit criterion still open.
#
# So this script REFUSES to run unless the host really is in the Tier C range, and then
# asserts everything with no injection at all. If it passes on a 2048MB VM, the criterion
# is closed and its transcript is the evidence.
#
#   1. Shut the Kali VM down (a running VM cannot be resized).
#   2. VirtualBox -> Settings -> System -> Motherboard -> Base Memory = 2048 MB.
#      Or on the host: VBoxManage modifyvm "<name>" --memory 2048
#   3. Boot, open a terminal, and:
#          cd ~/revctf && ./tools/verify-tier-c.sh
#   4. Set Base Memory back to 4096 MB afterwards.
#
# Per v5 §4.1 this file must not enable `set -e`.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RC="$ROOT/revctf"
CORPUS="$ROOT/test-corpus"
WORK="${TMPDIR:-/tmp}/revctf-tierc.$$"
# Written to a temp file first and only moved into the repo once the host has passed the
# Tier C gate. A refused run on the wrong-sized host should leave nothing behind — an empty
# "verification" file in the tree is exactly the sort of artefact a later session mistakes
# for evidence.
TRANSCRIPT_FINAL="$ROOT/tier-c-verification-$(date +%Y%m%d-%H%M%S).txt"
TRANSCRIPT=""

PASS=0; FAIL=0; SKIP=0
declare -a FAILURES=()

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILURES+=("$1"); }
skip() { printf '  \033[33mSKIP\033[0m  %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }
sect() { printf '\n\033[1m--- %s ---\033[0m\n' "$1"; }

# match <desc> <ere> <file-or-->  — the assertion, always against a captured file so the
# transcript can hold the evidence rather than a claim about it.
match() {
    if grep -Eq -- "$2" "$3" 2>/dev/null; then ok "$1"
    else no "$1" "no line matched /$2/ in $3"; fi
}
nomatch() {
    if grep -Eq -- "$2" "$3" 2>/dev/null; then no "$1" "unexpectedly matched /$2/ in $3"
    else ok "$1"; fi
}

# One trap, installed before anything can fail. `keep_transcript` is a no-op until the host
# has passed the Tier C gate, so a refused run leaves nothing in the repo, and the tee that
# is still draining is given a moment before its directory goes away — without that, the
# transcript of a genuine FAILING run (the one most worth reading) could be truncated.
# keep_transcript — copy the transcript into the repo, but only for a run that meant
# something. A file named tier-c-verification-<date>.txt in the tree is evidence, and a
# later session will read it as such; a refused run must not produce one.
# shellcheck disable=SC2329  # invoked from the EXIT trap installed above
keep_transcript() {
    [[ $TIER_C_CONFIRMED -eq 1 ]] || return 0
    # The tee is still draining; copy what exists rather than truncating it.
    cp -- "$TRANSCRIPT" "$TRANSCRIPT_FINAL" 2>/dev/null || return 0
    return 0
}

TIER_C_CONFIRMED=0
trap 'keep_transcript; sleep 0.2; rm -rf "$WORK"' EXIT

mkdir -p "$WORK"
TRANSCRIPT="$WORK/transcript.txt"
exec > >(tee "$TRANSCRIPT") 2>&1

printf '\033[1mrevctf — Tier C verification on real hardware\033[0m\n'
printf 'repo : %s\n' "$ROOT"
printf 'date : %s\n' "$(date -Is)"
printf 'host : %s %s\n' "$(uname -s)" "$(uname -r)"

# ======================================================================================
# The gate. Everything below is worthless on a host that is not actually small.
# ======================================================================================
sect "the host really is a Tier C machine"

RAM_MB=0
if command -v free >/dev/null 2>&1; then
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
fi
if [[ ! $RAM_MB =~ ^[0-9]+$ || $RAM_MB -eq 0 ]]; then
    RAM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
fi
# Coerced before any arithmetic test: CLAUDE.md §2 forbids letting an unvalidated value
# reach `[[ -eq ]]`, which under `set -u` exits the shell outright rather than failing.
[[ $RAM_MB =~ ^[0-9]+$ ]] || RAM_MB=0

printf '  detected RAM : %s MB\n' "$RAM_MB"
printf '  swap         : %s MB\n' "$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')"
printf '  CPUs         : %s\n' "$(nproc 2>/dev/null)"

# 2560MB is TIER_B_MIN_MB. Below it is Tier C, which is the whole point.
if [[ $RAM_MB -eq 0 ]]; then
    no "RAM detection" "could not read total memory; nothing below can be trusted"
    exit 1
elif [[ $RAM_MB -ge 2560 ]]; then
    printf '\n\033[31mThis host has %sMB — that is Tier %s, not Tier C.\033[0m\n' \
        "$RAM_MB" "$( [[ $RAM_MB -ge 3891 ]] && printf A || printf B )"
    printf 'Shut the VM down and set Base Memory to 2048 MB, then run this again.\n'
    printf '  VBoxManage modifyvm "<vm-name>" --memory 2048\n'
    printf '\nRefusing to run: injecting REVCTF_RAM_MB here would test the branch that\n'
    printf 'tools/run-tests.sh already tests, and would close the criterion dishonestly.\n'
    exit 1
fi
ok "host RAM is ${RAM_MB}MB — genuinely inside the Tier C range (< 2560MB)"
TIER_C_CONFIRMED=1

if [[ ! -f $CORPUS/crackme ]]; then
    printf '\nThe corpus is missing. Run ./tools/build-test-corpus.sh first.\n'
    exit 1
fi

# ======================================================================================
sect "tier selection comes from the hardware, not from an injected number"
# REVCTF_RAM_MB is deliberately unset for every command in this section.
unset REVCTF_RAM_MB
P="$WORK/plan.txt"
"$RC" scan "$CORPUS/crackme" --dry-run > "$P" 2>&1

match   "the plan selects Tier C"                     'Tier +: C'            "$P"
nomatch "and it is NOT labelled as injected"          'INJECTED'             "$P"
match   "the RAM figure is credited to a real source" 'via (free -m|/proc/meminfo)' "$P"
match   "the plan reports the hardware's own figure"  "$RAM_MB *MB"          "$P"

# ======================================================================================
sect "Tier C's degradations are chosen for this host"
match "Phase-1 concurrency drops to 1"        'Phase-1 jobs  : 1'          "$P"
match "Ghidra MAXMEM is the Tier C value"     'MAXMEM : 512M'              "$P"
match "the Phase-2 cap is the Tier C value"   'Phase-2 cap +512MB'         "$P"
match "light decompilation is automatic"      'light-decompile enabled automatically' "$P"
match "Ghidra is skipped by default"          '\[skip\] ghidra'            "$P"
match "FLOSS emulation is called unaffordable" 'does not fit|not given room' "$P"
match "the watchdog threshold is an absolute figure" \
      'Watchdog +: kills the job tree above [0-9]+% of RAM \([0-9]+MB\)'    "$P"
match "the enforcement mechanism is named"    'Enforced by +: (systemd-run|ulimit -v|nothing)' "$P"

# The mechanism matters: on this VM it must be systemd-run. The ulimit -v fallback cannot
# bound a JVM (measured — a hello-world java needs 2-4GB of virtual size), so falling back
# here would mean Ghidra is unbounded, not bounded at 512M.
if grep -q 'Enforced by *: systemd-run' "$P"; then
    ok "bounding uses systemd-run (a real RSS limit), not the ulimit -v fallback"
else
    no "bounding mechanism" "expected systemd-run; got: $(grep -E 'Enforced by' "$P")"
fi

# --- the override still works on real hardware ---------------------------------------
"$RC" scan "$CORPUS/crackme" --dry-run --force-full-decompile > "$WORK/plan-full.txt" 2>&1
match "--force-full-decompile restores Ghidra on a real Tier C host" \
      '\[run \] ghidra'      "$WORK/plan-full.txt"
match "and the reported mode changes with it" \
      'Decompilation : full'  "$WORK/plan-full.txt"

# ======================================================================================
sect "a real scan is actually bounded at the Tier C ceilings"
# The numbers must reach the tools, on this hardware, with nothing injected.
V="$WORK/verbose.txt"
"$RC" scan "$CORPUS/crackme" --skip-ghidra --verbose --output "$WORK/o1" > "$V" 2>&1
match "radare2 is held to Tier C's 400MB"     '\[radare2\] memory ceiling 400MB' "$V"
match "a Phase-2 stage is held to Tier C's 512MB" '\[floss\] memory ceiling 512MB' "$V"
if [[ -s $WORK/o1/report.txt ]]; then
    ok "the scan completed and wrote a report at 2GB"
else
    no "scan at 2GB" "no report.txt was produced"
fi
nomatch "no stage was killed by the watchdog on a normal Tier C scan" \
        'watchdog' "$WORK/o1/report.txt"

# ======================================================================================
sect "FLOSS degrades instead of being OOM-killed (the measured 900MB problem)"
if [[ -f $CORPUS/winsample.exe ]]; then
    "$RC" scan "$CORPUS/winsample.exe" --skip-ghidra --output "$WORK/o2" > "$WORK/pe.txt" 2>&1
    match "FLOSS runs static-only on a PE at Tier C" \
          'static strings only \(emulation does not fit' "$WORK/o2/floss.txt"
    match "and the report blames RAM, not the file format" \
          'not given room to look'                       "$WORK/o2/floss.txt"
    # The point of degrading: the stage must SUCCEED, not fail cleanly.
    if grep -qE '^floss +(ok|empty)' "$WORK/o2/report.txt"; then
        ok "the FLOSS stage survives at 2GB rather than being killed"
    else
        no "FLOSS at Tier C" "status was: $(grep -E '^floss ' "$WORK/o2/report.txt")"
    fi
else
    skip "FLOSS degradation" "winsample.exe absent — run ./tools/build-test-corpus.sh"
fi

# ======================================================================================
sect "Ghidra at Tier C — the JVM must fit in 512M on a 2GB host"
# This is the check that only real hardware can make. --force-full-decompile puts Ghidra
# back, and a 512M MAXMEM on a machine with 2GB total is where an unbounded JVM would take
# the host down. If Ghidra completes here, the tier's Ghidra number is survivable.
if command -v analyzeHeadless >/dev/null 2>&1 || [[ -n ${GHIDRA_HOME:-} ]]; then
    "$RC" scan "$CORPUS/crackme" --force-full-decompile --verbose \
        --output "$WORK/o3" > "$WORK/gh.txt" 2>&1
    match "Ghidra is bounded at Tier C's 512MB" '\[ghidra\] memory ceiling 512MB' "$WORK/gh.txt"
    gs=$(grep -oE '^ghidra +[a-z]+' "$WORK/o3/report.txt" 2>/dev/null | awk '{print $2}')
    if [[ ${gs:-absent} == ok ]]; then
        ok "the Ghidra stage completes at Tier C (512M MAXMEM is survivable on 2GB)"
    else
        no "ghidra at Tier C" "status '${gs:-absent}' — record this: it may mean 512M is too small on real 2GB hardware, which is a TIER TABLE finding, not a bug"
    fi
    if grep -q 'sw0rdf1sh' "$WORK/o3/ghidra.txt" 2>/dev/null; then
        ok "and it still recovers the crackme's password inside the ceiling"
    else
        no "ghidra output at Tier C" "sw0rdf1sh absent — the JVM ran but decompiled nothing"
    fi
else
    skip "Ghidra at Tier C" "no Ghidra install found"
fi

# ======================================================================================
sect "the harness's own M5 sections, on this hardware"
# These still inject, but running them here proves the injected branches and the real
# hardware agree rather than diverging — and re-checks every earlier M5 gate at 2GB.
if "$ROOT/tools/run-tests.sh" m5 m5enforce > "$WORK/harness.txt" 2>&1; then
    ok "run-tests.sh m5 m5enforce is green on a 2GB host"
else
    no "harness at 2GB" "see the tail below"
fi
sed -e 's/\x1b\[[0-9;]*m//g' "$WORK/harness.txt" | grep -E '^  (FAIL|SKIP)' | sed 's/^/    /'
sed -e 's/\x1b\[[0-9;]*m//g' "$WORK/harness.txt" | tail -1 | sed 's/^/    /'

# ======================================================================================
printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
printf 'transcript: %s\n' "$TRANSCRIPT_FINAL"
if [[ $FAIL -gt 0 ]]; then
    printf 'failed:\n'; printf '  - %s\n' "${FAILURES[@]}"
    printf '\nDo NOT mark the M5 exit criterion closed. Paste this transcript back.\n'
    exit 1
fi
printf '\nM5 exit criterion closed: Tier C selected and enforced on genuinely %sMB of RAM.\n' "$RAM_MB"
printf 'Paste the transcript back so it can be recorded in implementation-notes.md.\n'
exit 0
