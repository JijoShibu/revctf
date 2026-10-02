#!/usr/bin/env bash
# Linux resource regressions; no challenge execution or external analysis tools.
# shellcheck disable=SC1091,SC2034,SC2329
set -uo pipefail
ROOT=${REVCTF_TEST_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/revctf-resources.XXXXXX") || exit 1
printf 'Evidence: %s\n' "$WORK"
source "$ROOT/lib/stage.sh"
source "$ROOT/lib/memory.sh"
source "$ROOT/lib/tier.sh"
source "$ROOT/lib/flagscan.sh"
declare -A OPT=([flag_scan]=1 [flag_format]='' [allow_low_memory]=0)
PASS=0 FAIL=0
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
warn() { printf '%s\n' "$*" >&2; }
check() {
    local label=$1; shift
    if ( "$@" ); then printf 'PASS %s\n' "$label"; PASS=$((PASS+1));
    else printf 'FAIL %s\n' "$label"; FAIL=$((FAIL+1)); fi
}
gate_test() {
    RAM_MEASURED=1 RAM_TOTAL_MIB=$1
    OPT[allow_low_memory]=$2
    OPT[assume_yes]=1 OPT[light_decompile]=1
    REVCTF_RAM_MB=65536
    local rc=0
    ram_gate > "$WORK/gate.out" 2> "$WORK/gate.err" || rc=$?
    [[ $rc -eq $3 ]] || return 1
    if [[ $1 -lt 3891 && $2 -eq 1 ]]; then
        [[ $RAM_GATE_NOTE == *'LOW MEMORY OVERRIDE'* ]] || return 1
    fi
}
for amount in 0 2048 3890; do check "RAM $amount blocked despite --yes and simulated tier" gate_test "$amount" 0 1; done
for amount in 3891 4096 16384; do check "RAM $amount accepted" gate_test "$amount" 0 0; done
check 'explicit low RAM override warns' gate_test 2048 1 0
check 'unknown RAM override warns' gate_test 0 1 0

output_test() {
    local own=$1 mode=$2 bytes=$3 rc=0
    [[ $mode == posix ]] && set -o posix
    ST_OWN_SESSION=$own ST_MAX_OUT_KB=16 ST_MEM_MODE=none ST_LIMIT_NOTE=''
    st_run_bounded 5 "$WORK/out" "$WORK/err" -- head -c "$bytes" /dev/zero || rc=$?
    local actual; actual=$(stat -c %s "$WORK/out")
    if [[ $bytes -lt 16384 ]]; then [[ $actual -eq $bytes && $rc -eq 0 && -z $ST_LIMIT_NOTE ]];
    else [[ $actual -eq 16384 && -n $ST_LIMIT_NOTE ]]; fi
}
for own in 0 1; do
    for mode in normal posix; do
        for bytes in 8192 16384 32768; do
            check "output $bytes bytes session=$own mode=$mode" output_test "$own" "$mode" "$bytes"
        done
    done
done
bad_limit() {
    ST_MAX_OUT_KB=$1
    ! st_run_bounded 5 "$WORK/out" "$WORK/err" -- touch "$WORK/should-not-run" && [[ ! -e $WORK/should-not-run ]]
}
for value in 0 -1 word 99999999999999999999; do check "invalid limit $value refuses execution" bad_limit "$value"; done

partial_flag() {
    RUN_OUTDIR=$WORK RUN_WORKDIR=$WORK ST_MAX_OUT_KB=1 ST_MEM_MODE=none REVCTF_SCRIPTS=''
    produce() { stage_capture strings 5 -- bash -c 'printf "flag{early_known_answer}\n"; head -c 2048 /dev/zero; printf "flag{late_known_answer}\n"'; }
    stage_run strings strings produce
    [[ ${STAGE_STATUS[strings]} == partial ]] || return 1
    flagscan_run
    flagscan_report > "$WORK/flags"
    grep -q 'flag{early_known_answer}' "$WORK/flags" && ! grep -q 'flag{late_known_answer}' "$WORK/flags" && grep -q UNVERIFIED "$WORK/flags"
}
check 'partial capture preserves early answer without inventing the missing one' partial_flag
heap_budget() {
    TIER_MAXMEM_GHIDRA=$1 TIER_CEIL_OVERRIDE=''
    [[ $(tier_ceiling_for_stage ghidra) -eq $2 ]]
}
check '512 MiB heap has supporting memory' heap_budget 512M 768
check '768 MiB heap has supporting memory' heap_budget 768M 1024
check '1024 MiB heap has supporting memory' heap_budget 1024M 1280

cli_gate_test() {
    local mask="$WORK/mask"
    mkdir -p "$mask"
    cat > "$mask/awk" <<'SH'
#!/bin/bash
if [[ $1 == *MemTotal* ]]; then printf '2048'; else exec /usr/bin/awk "$@"; fi
SH
    cat > "$mask/file" <<'SH'
#!/bin/bash
touch "$DEPENDENCY_SENTINEL"
exit 91
SH
    chmod +x "$mask/awk" "$mask/file"
    printf 'allow_low_memory = yes\n' > "$WORK/forbidden-config"
    local rc=0
    PATH="$mask:$PATH" DEPENDENCY_SENTINEL="$WORK/probed" REVCTF_RAM_MB=65536 \
        bash "$ROOT/revctf" scan /bin/true --yes --light-decompile --config "$WORK/forbidden-config" \
        --output "$WORK/blocked-out" > "$WORK/cli.log" 2>&1 || rc=$?
    [[ $rc -eq 1 && ! -e $WORK/probed && ! -e $WORK/blocked-out ]] || return 1
    grep -q 'scan blocked' "$WORK/cli.log" && grep -q -- '--allow-low-memory' "$WORK/cli.log"
}
check 'CLI gate precedes dependency probes; config and tier simulation cannot bypass it' cli_gate_test

cleanup_failure_test() {
    source "$ROOT/lib/sandbox.sh"
    RUN_OUTDIR=$WORK
    sbx_register fixture || return 1
    local mask="$WORK/docker-failure"
    mkdir -p "$mask"
    printf '#!/bin/bash\nsleep 20\n' > "$mask/docker"
    chmod +x "$mask/docker"
    local started=$SECONDS rc=0
    PATH="$mask:$PATH" sbx_cleanup_all 2> "$WORK/cleanup.err" || rc=$?
    [[ $rc -eq 1 && $SBX_CLEANUP_FAILED -eq 1 && $((SECONDS-started)) -le 12 ]] || return 1
    grep -q 'The challenge may still be running' "$WORK/cleanup-warning.txt"
}
check 'unresponsive Docker cleanup is bounded and never claims success' cleanup_failure_test

unowned_cleanup_test() {
    source "$ROOT/lib/sandbox.sh"
    docker() { touch "$WORK/wrong-cleanup"; return 99; }
    sbx_teardown unrelated-container
    [[ ! -e $WORK/wrong-cleanup ]]
}
check 'cleanup refuses unregistered container names' unowned_cleanup_test

oom_evidence_test() {
    source "$ROOT/lib/stage_ghidra.sh"
    { printf 'java.lang.OutOfMemoryError: Java heap space\n'; head -c 200000 /dev/zero; } > "$WORK/real-oom"
    _ghidra_saw_oom "$WORK/real-oom" || return 1
    printf '=== REVCTF-GHIDRA-BEGIN ===\njava.lang.OutOfMemoryError\n=== REVCTF-GHIDRA-END ===\n' > "$WORK/decoy-oom"
    ! _ghidra_saw_oom "$WORK/decoy-oom"
}
check 'OOM detection consumes large diagnostics and ignores challenge-text decoys' oom_evidence_test

limit_setup_failure() {
    ST_MAX_OUT_KB=16 ST_MEM_MODE=none
    ulimit() { return 1; }
    local rc=0
    st_run_bounded 5 "$WORK/refused.out" "$WORK/refused.err" -- touch "$WORK/limit-not-applied" || rc=$?
    [[ $rc -eq 125 && ! -e $WORK/limit-not-applied && $ST_LIMIT_NOTE == *'could not'* ]]
}
check 'failure to apply a file limit refuses the command' limit_setup_failure
printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
