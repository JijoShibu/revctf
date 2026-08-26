#!/usr/bin/env bash
# lib/stage_strace.sh — Stage 9: syscall trace, plus dynamic linkage.
#
# Implemented in: M3 (new in v6, deviation D2).  Must not enable `set -e`.
#
# EXECUTES THE TARGET. See lib/stage_dynamic.sh for the safety model.
#
# Complements ltrace rather than duplicating it: ltrace shows library calls, strace shows
# the syscalls underneath. A statically-linked binary — common for Go and Rust CTF
# challenges — has no library calls for ltrace to see at all, and strace is the only
# dynamic view that works on it.
#
# `ldd` does not execute anything; it is folded in here because linkage is what tells you
# whether ltrace had a chance of producing output.
stage_strace() {
    local name="strace" out err rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"

    if [[ ${OPT[skip_strace]:-0} -eq 1 ]]; then
        stage_skip "$name" "skipped by user request (--skip-strace)"
        return 0
    fi

    # Linkage first: it is cheap, it does not execute the target, and it is worth having
    # even when the trace itself is skipped.
    {
        printf '=== Dynamic linkage (ldd) ===\n'
        if [[ $RUN_FORMAT == elf ]]; then
            timeout -k 2 "$ST_T_LIGHT" ldd "$RUN_TARGET" 2>&1 \
                || printf '(not a dynamic executable — likely statically linked)\n'
        else
            printf '(not applicable to a %s target)\n' "$RUN_FORMAT"
        fi
        printf '\n'
    } > "$out" 2>>"$err"

    if ! dyn_guard "$name" strace; then
        # Keep the ldd section: a skipped trace should not discard useful output.
        stage_write "$name" ok
        stage_set_status "$name" skipped "${STAGE_NOTE[$name]:-not applicable}; linkage still captured"
        return 0
    fi

    # `-o` for the same reason as ltrace: strace's default output stream is stderr, so
    # without it the syscall trace went to the error file and never reached the report.
    dyn_banner strace "$ST_T_STRACE" >> "$out"
    dyn_run "$name" "$ST_T_STRACE" "$out.stdout" "$err" "$DYN_TRACE_HOST" \
        -- strace -f -tt -T -o "$DYN_TRACE_ARG" "$DYN_EXEC_ARG" || rc=$?
    dyn_compose "$out" "$DYN_TRACE_HOST" "$out.stdout" "syscall trace"

    stage_record_exec "$name" "$(dyn_cmdline strace "$ST_T_STRACE" "-f -tt -T -o $DYN_TRACE_ARG $DYN_EXEC_ARG")" "$rc"
    dyn_finish "$name" strace "$ST_T_STRACE" "$rc"
    return 0
}
