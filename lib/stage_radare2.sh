#!/usr/bin/env bash
# lib/stage_radare2.sh — Stage 8: disassembly.
#
# Implemented in: M3.  Per v5 §4.1 this file must not enable `set -e`.
#
# Two things this stage has to get right.
#
# 1. FIND `main` WITH A WORD BOUNDARY (v3 §4 item 10). A substring match happily selects
#    `domain_main_init` and then disassembles the wrong function with total confidence.
#    The test corpus carries exactly that symbol so the check has something to fail
#    against. Stripped binaries have no `main` at all — the normal case in CTF — hence the
#    `entry0` fallback.
#
# 2. ANALYSE ONCE. radare2's `aaa` is the expensive part by orders of magnitude: measured
#    at 195s on a 220MB target before being OOM-killed. An earlier version of this stage
#    ran a separate `r2 -c 'aaa; ...'` per query and paid that cost SIX times over. Every
#    command now runs in a single session, so `aaa` happens once and the stage is bounded
#    by one timeout rather than six.
#
# Also note: no `--` before the filename. radare2 takes it AS the filename and silently
# analyses nothing, so `afl` returns zero functions and every binary looks stripped.
# RUN_TARGET is absolutised by stage_begin_file(), so it can never be read as an option.
R2_DISASM_MAX="${R2_DISASM_MAX:-4000}"

# Above this size, use `aa` (basic analysis) instead of `aaa`. A 200MB target is firmware
# or a data blob, not a crackme; `aaa`'s emulation and reference passes over that much
# non-code is where the time and memory go, for output nobody reads.
R2_DEEP_MAX_MB="${R2_DEEP_MAX_MB:-64}"

stage_radare2() {
    local name="radare2" out err size_mb analysis="aaa" rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"
    : > "$err"

    case "$RUN_FORMAT" in
        java|pyc|pyinstaller|archive)
            stage_skip "$name" "not a native binary (this one is $RUN_FORMAT)"
            return 0 ;;
    esac

    size_mb=$(( $(st_file_size "$RUN_TARGET") / 1048576 ))
    if [[ $size_mb -gt $R2_DEEP_MAX_MB ]]; then
        analysis="aa"
    fi

    # One session, one analysis pass. `~` is r2's internal grep; keeping the filtering
    # inside r2 avoids shipping megabytes through a pipe.
    local script
    script="$analysis
?e === REVCTF-SECTION Binary info ===
i
?e
?e === REVCTF-SECTION Functions ===
afl
?e
?e === REVCTF-SECTION Imports ===
ii
?e
?e === REVCTF-SECTION Strings in data sections ===
iz
?e
?e === REVCTF-SECTION Entry points ===
ie"

    local raw="$RUN_WORKDIR/r2.raw"
    st_run_bounded "$ST_T_RADARE2" "$raw" "$err" \
        -- r2 -N -q -e scr.color=0 -c "$script" "$RUN_TARGET" || rc=$?

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        {
            printf '=== radare2 ===\n'
            printf 'Analysis was stopped after %ss (or ran out of memory).\n' "$ST_T_RADARE2"
            printf 'This target is %sMB; radare2 full analysis over a large non-code blob\n' "$size_mb"
            printf 'is expensive and rarely informative. objdump above has the raw\n'
            printf 'disassembly, and binwalk has the structural view.\n'
        } > "$out"
        cat "$raw" >> "$out" 2>/dev/null; rm -f "$raw"
        stage_record_exec "$name" "r2 -N -q -c '$analysis; ...' $RUN_TARGET" "$rc"
        stage_set_status "$name" failed "analysis stopped after ${ST_T_RADARE2}s on a ${size_mb}MB target"
        return 0
    fi

    # --- pick the disassembly target from the function list we already have -----------
    local funcs target_sym how
    funcs=$(sed -n '/REVCTF-SECTION Functions/,/REVCTF-SECTION Imports/p' "$raw" 2>/dev/null)
    if grep -qE '(^|[^A-Za-z0-9_])main([^A-Za-z0-9_]|$)' <<< "$funcs"; then
        target_sym="main"; how="symbol table"
    else
        target_sym="entry0"; how="entry0 fallback (no main — binary is probably stripped)"
    fi

    # Second session, only for the disassembly itself. Re-analysing is unavoidable here
    # (r2 sessions do not persist), but it is one extra pass rather than five.
    local dis="$RUN_WORKDIR/r2.dis"
    st_run_bounded "$ST_T_RADARE2" "$dis" "$err" \
        -- r2 -N -q -e scr.color=0 \
             -c "$analysis; s $target_sym; axt; ?e === REVCTF-SECTION Disassembly ===; pdf" \
             "$RUN_TARGET" || true

    {
        printf '=== Analysis summary ===\n'
        printf 'Disassembly target: %s  (%s)\n' "$target_sym" "$how"
        printf 'Analysis depth    : %s%s\n\n' "$analysis" \
            "$([[ $analysis == aa ]] && printf '  (reduced: target is %sMB, over the %sMB deep-analysis limit)' "$size_mb" "$R2_DEEP_MAX_MB")"
        st_strip_ansi < "$raw"
        printf '\n'
        head -n "$R2_DISASM_MAX" "$dis" 2>/dev/null | st_strip_ansi
        printf '\n(disassembly capped at %s lines)\n' "$R2_DISASM_MAX"
    } > "$out"
    rm -f "$raw" "$dis"

    stage_record_exec "$name" "r2 -N -q -c '$analysis; s $target_sym; pdf' $RUN_TARGET" 0
    stage_write "$name"
    [[ ${STAGE_STATUS[$name]} == ok ]] && \
        stage_set_status "$name" ok "disassembled $target_sym via $how"
    return 0
}
