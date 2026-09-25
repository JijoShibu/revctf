#!/usr/bin/env bash
# Portable regression tests: actual library functions, simulated analysis tools.
# No challenge executable, Docker daemon, compiler or Ghidra install is required.
# REVCTF_TEST_ROOT can point to an older checkout to prove these checks catch defects.
# Library globals and simulated tool functions are consumed across sourced files.
# The selectable checkout prevents ShellCheck from resolving those files statically.
# shellcheck disable=SC1091,SC2034,SC2329
set -uo pipefail
ROOT="${REVCTF_TEST_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/revctf-reliability.XXXXXX") || exit 1
printf 'Test artifacts: %s\n' "$WORK"
# shellcheck source=../lib/stage.sh
source "$ROOT/lib/stage.sh"
# shellcheck source=../lib/flagscan.sh
source "$ROOT/lib/flagscan.sh"
declare -A OPT=([flag_scan]=1 [flag_format]='' [ghidra_script]='')
PASS=0 FAIL=0 SKIP=0
check() {
    local label="$1"; shift
    if ( "$@" ); then
        printf 'PASS %s\n' "$label"; PASS=$((PASS + 1))
    else
        local rc=$?
        if [[ $rc -eq 77 ]]; then
            printf 'SKIP %s (filesystem does not provide real symbolic links)\n' "$label"
            SKIP=$((SKIP + 1)); return 0
        fi
        printf 'FAIL %s\n' "$label"; FAIL=$((FAIL + 1))
    fi
}
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
setup_stage() {
    RUN_WORKDIR="$WORK/$1/work"; RUN_OUTDIR="$WORK/$1/out"
    mkdir -p "$RUN_WORKDIR" "$RUN_OUTDIR"
    RUN_TARGET="$WORK/$1/target"; printf 'dummy input\n' > "$RUN_TARGET"
    RUN_FORMAT=elf
}
has_flag() {
    printf '%s\n' "${FLAG_HITS[@]}" | cut -f4- | grep -Fxq -- "$1"
}
scan() {
    setup_stage "scan-$1"
    REVCTF_SCRIPTS='' # The separate Python reconstruction heuristic is outside this suite.
    cat > "$RUN_WORKDIR/capture"
    STAGE_ORDER=(strings)
    # shellcheck disable=SC2154  # STAGE_OUT is associative, declared by lib/stage.sh.
    STAGE_OUT=([strings]="$RUN_WORKDIR/capture")
    flagscan_run
}
test_collision() {
    local dir="$WORK/collision"
    mkdir -p "$dir"
    printf 'ORIGINAL INPUT\n' > "$dir/report.txt"
    if stage_begin_file "$dir/report.txt" "$dir" 2> "$WORK/collision.err"; then
        stage_end_file; return 1
    fi
    [[ $(cat "$dir/report.txt") == 'ORIGINAL INPUT' && ! -d $dir/.revctf-lock ]] &&
        grep -q 'Choose a new' "$WORK/collision.err"
}
test_existing_link() {
    local kind="$1" dir="$WORK/$1-link"
    mkdir -p "$dir"
    printf 'ORIGINAL INPUT\n' > "$WORK/$1-original"
    if [[ $kind == hard ]]; then
        ln "$WORK/$1-original" "$dir/strings.txt" || return 1
    else
        ln -s "$WORK/$1-original" "$dir/strings.txt" || return 1
        [[ -L $dir/strings.txt ]] || return 77
    fi
    if stage_begin_file "$WORK/$1-original" "$dir" 2>/dev/null; then
        stage_end_file; return 1
    fi
    [[ $(cat "$WORK/$1-original") == 'ORIGINAL INPUT' ]]
}
test_fresh_output() {
    local dir="$WORK/fresh"
    printf input > "$WORK/original"
    mkdir -p "$dir"
    stage_begin_file "$WORK/original" "$dir" || return 1
    [[ -d $dir/.revctf-lock && -d $RUN_WORKDIR ]] || return 1
    # A second process must not steal the lock while the directory is otherwise empty.
    if ( stage_begin_file "$WORK/original" "$dir" 2>/dev/null ); then
        stage_end_file; return 1
    fi
    stage_end_file
    [[ ! -d $dir/.revctf-lock ]]
}
test_runner() {
    local mode="$1" rc=0 expected=9 bound=5
    setup_stage "runner-$mode"
    ST_MEM_MODE=none; ST_MEM_CEIL_MB=0
    if [[ $mode == timeout ]]; then expected=124; bound=0.2; fi
    # shellcheck disable=SC2016  # $1 belongs to the child shell.
    stage_capture probe "$bound" -- bash -c \
        'printf "partial output\n"; if [[ $1 == timeout ]]; then sleep 2; else exit 9; fi' \
        bash "$mode" || rc=$?
    [[ $rc -eq $expected && ${STAGE_RC[probe]} -eq $expected && ${STAGE_STATUS[probe]} == failed ]] &&
        grep -qx 'partial output' "${STAGE_OUT[probe]}"
}
test_plain() { scan plain <<< 'flag{plain_positive}'; has_flag 'flag{plain_positive}'; }
test_noise() { scan noise <<< 'ordinary words'; [[ ${#FLAG_HITS[@]} -eq 0 ]]; }
test_base32() {
    local n val
    for n in a ab abc abcd abcde; do
        val="flag{$n}"
        printf '%s' "$val" | base32 -w0 > "$WORK/b32"
        scan "b32-$n" < "$WORK/b32"
        has_flag "$val" || return 1
    done
}
test_base64() {
    printf 'flag{base64_positive}' | base64 -w0 > "$WORK/b64"
    scan base64 < "$WORK/b64"
    has_flag 'flag{base64_positive}'
}
test_bad_encoding() {
    { printf 'flag{invalid_encoding}' | base64 -w0; printf '=A'; } > "$WORK/bad64"
    scan bad64 < "$WORK/bad64"
    ! has_flag 'flag{invalid_encoding}'
}
test_nul_encoding() {
    printf 'flag{abc\000cd}' | base64 -w0 > "$WORK/nul64"
    scan nul64 < "$WORK/nul64"
    ! has_flag 'flag{abccd}'
}
test_unverified() {
    scan decoy <<< 'flag{decoy}'
    has_flag 'flag{decoy}' || return 1
    flagscan_report > "$WORK/flag-report"
    grep -q 'UNVERIFIED' "$WORK/flag-report" && grep -q 'Search limits' "$WORK/flag-report"
}
test_r2() {
    local fail_call="$1" fail_rc="$2" calls=0
    setup_stage "r2-$fail_call-$fail_rc"
    # shellcheck source=../lib/stage_radare2.sh
    source "$ROOT/lib/stage_radare2.sh"
    st_run_bounded() {
        calls=$((calls + 1))
        printf '=== REVCTF-SECTION Functions ===\nmain\n=== REVCTF-SECTION Imports ===\n' > "$2"
        printf 'diagnostic from call %s\n' "$calls" > "$3"
        [[ $calls -eq $fail_call ]] && return "$fail_rc"
        return 0
    }
    stage_radare2
    if [[ $fail_call -eq 0 ]]; then
        [[ ${STAGE_STATUS[radare2]} == ok && ${STAGE_RC[radare2]} -eq 0 ]]
    else
        [[ ${STAGE_STATUS[radare2]} == failed && ${STAGE_RC[radare2]} -eq $fail_rc &&
           -s ${STAGE_OUT[radare2]} && $calls -eq $fail_call ]]
    fi
}
test_binutils() {
    local fail_call="$1" calls=0
    setup_stage "binutils-$fail_call"
    # shellcheck source=../lib/stage_objdump.sh
    source "$ROOT/lib/stage_objdump.sh"
    st_run_bounded() {
        calls=$((calls + 1)); printf 'parser output\n' > "$2"; : > "$3"
        [[ $fail_call == all || $calls == "$fail_call" ]] && return 7
        return 0
    }
    stage_objdump
    [[ $calls -eq 6 ]] || return 1
    if [[ $fail_call == none ]]; then
        [[ ${STAGE_STATUS[objdump]} == ok ]]
    else
        [[ ${STAGE_STATUS[objdump]} == failed && ${STAGE_RC[objdump]} -eq 7 && -s ${STAGE_OUT[objdump]} ]]
    fi
}
test_ghidra() {
    local mode="$1" rc=0
    setup_stage "ghidra-$mode"
    # shellcheck source=../lib/stage_ghidra.sh
    source "$ROOT/lib/stage_ghidra.sh"
    PF_GHIDRA_HEADLESS=simulated
    mkdir -p "$WORK/custom scripts"
    printf '# custom post-script\n' > "$WORK/custom scripts/custom.py"
    OPT[ghidra_script]="$WORK/custom scripts/custom.py"
    REVCTF_SCRIPTS="$ROOT/scripts"
    pf_check_disk() { return 0; }
    st_run_bounded() {
        printf '%s\n' "$@" > "$RUN_WORKDIR/argv"
        : > "$3"
        {
            [[ $mode == stdoutload ]] && printf 'SCRIPT ERROR: launcher failure\n'
            [[ $mode == reversed ]] && printf '=== REVCTF-GHIDRA-END ===\n'
            printf '=== REVCTF-GHIDRA-BEGIN ===\nuseful partial output\n'
            [[ $mode == success ]] && printf 'puts("SyntaxError is challenge text");\n'
            [[ $mode == error ]] && printf 'REVCTF-ERROR: simulated failure\n'
            [[ $mode == load ]] && printf 'SCRIPT ERROR: failed to load\n' > "$3"
            [[ $mode != incomplete && $mode != reversed ]] && printf '=== REVCTF-GHIDRA-END ===\n'
        } > "$2"
        return 0
    }
    stage_ghidra
    grep -Fxq "$WORK/custom scripts" "$RUN_WORKDIR/argv" || return 1
    [[ $mode == success ]] || rc=1
    [[ ${STAGE_RC[ghidra]} -eq $rc && -s ${STAGE_OUT[ghidra]} ]] || return 1
    if [[ $rc -eq 0 ]]; then [[ ${STAGE_STATUS[ghidra]} == ok ]];
    else [[ ${STAGE_STATUS[ghidra]} == failed ]]; fi
}
test_linkage() {
    local parser_rc="$1" calls=0
    setup_stage "linkage-$parser_rc"
    # shellcheck source=../lib/stage_strace.sh
    source "$ROOT/lib/stage_strace.sh"
    ldd() { printf unsafe > "$RUN_WORKDIR/ldd-called"; return 99; }
    st_run_bounded() {
        calls=$((calls + 1))
        [[ $* == *'-- readelf -d --'* ]] || return 88
        printf 'NEEDED libc.so.6\n' > "$2"; : > "$3"; return "$parser_rc"
    }
    dyn_guard() { stage_skip strace 'sandbox unavailable'; return 1; }
    stage_strace
    [[ $calls -eq 1 && ! -e $RUN_WORKDIR/ldd-called ]] || return 1
    grep -q 'NEEDED libc.so.6' "${STAGE_OUT[strace]}" || return 1
    if [[ $parser_rc -eq 0 ]]; then [[ ${STAGE_STATUS[strace]} == skipped ]];
    else [[ ${STAGE_STATUS[strace]} == failed && ${STAGE_RC[strace]} -eq $parser_rc ]]; fi
}
test_scope() {
    local mode="$1"
    # shellcheck source=../lib/preflight.sh
    source "$ROOT/lib/preflight.sh"
    systemd-run() {
        case "$mode" in
            user) [[ " $* " == *' --user '* ]] ;;
            system) [[ " $* " != *' --user '* ]] ;;
            none) return 1 ;;
        esac
    }
    timeout() { shift; "$@"; }
    pf_check_systemd_run
    ST_MEM_MODE=''; ST_MEM_CEIL_MB=512
    local -a pre=()
    st_mem_prefix pre
    if [[ $mode == none ]]; then [[ ${#pre[@]} -eq 0 ]];
    else "${pre[@]}" /bin/true; fi
}

check 'input cannot be overwritten by report' test_collision
check 'hard-linked output cannot overwrite input' test_existing_link hard
check 'linked output cannot overwrite input' test_existing_link symbolic
check 'empty existing output works; concurrent use is refused' test_fresh_output
check 'real bounded runner retains failed-command output' test_runner failure
check 'real bounded runner times out a benign sleeping command' test_runner timeout
check 'plain known answer recovered exactly' test_plain
check 'no candidate for plain noise' test_noise
check 'base32 padding variants recover exact answers' test_base32
check 'base64 known answer recovered exactly' test_base64
check 'invalid base64 partial output is discarded' test_bad_encoding
check 'NUL-separated fragments are not joined into flags' test_nul_encoding
check 'decoy remains explicitly unverified' test_unverified
check 'radare2 ordinary failure is recorded' test_r2 1 1
check 'radare2 second-session failure is recorded' test_r2 2 2
check 'radare2 timeout preserves failure and partial output' test_r2 1 124
check 'radare2 successful control' test_r2 0 0
check 'all binutils parsers failing is a failed stage' test_binutils all
check 'one binutils failure survives later successes' test_binutils 1
check 'binutils successful control' test_binutils none
check 'Ghidra internal error with output is failed' test_ghidra error
check 'Ghidra missing end marker is failed' test_ghidra incomplete
check 'Ghidra reversed completion markers are failed' test_ghidra reversed
check 'Ghidra loader error with partial output is failed' test_ghidra load
check 'Ghidra stdout launcher error is failed' test_ghidra stdoutload
check 'Ghidra completed output and custom script path work' test_ghidra success
check 'linkage read without ldd when sandbox unavailable' test_linkage 0
check 'linkage failure is not called a static binary' test_linkage 1
check 'user memory scope selected when available' test_scope user
check 'system memory scope selected when user scope fails' test_scope system
check 'memory fallback selected when both scopes fail' test_scope none
printf '\n%d passed; %d failed; %d skipped. Simulated tools do not validate Linux/Docker isolation.\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
