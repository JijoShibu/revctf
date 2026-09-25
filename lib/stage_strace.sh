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
# Read linkage from ELF metadata. Never use ldd on an untrusted challenge: some
# implementations can execute the target or its interpreter outside the sandbox.
stage_strace() {
    local name="strace" out err rc=0 linkage_rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"

    if [[ ${OPT[skip_strace]:-0} -eq 1 ]]; then
        stage_skip "$name" "skipped by user request (--skip-strace)"
        return 0
    fi

    # Linkage first: it is cheap, it does not execute the target, and it is worth having
    # even when the trace itself is skipped.
    {
        printf '=== Direct library dependencies (readelf -d; does not run the target) ===\n'
        if [[ $RUN_FORMAT == elf ]]; then
            st_run_bounded "$ST_T_LIGHT" "$out.linkage" "$err.linkage" \
                -- readelf -d -- "$RUN_TARGET" || linkage_rc=$?
            cat "$out.linkage"
            cat "$err.linkage" >> "$err"
            rm -f "$out.linkage" "$err.linkage"
            [[ $linkage_rc -eq 0 ]] || printf '(library metadata could not be read; exit %s)\n' "$linkage_rc"
        else
            printf '(not applicable to a %s target)\n' "$RUN_FORMAT"
        fi
        printf '\n'
    } > "$out" 2>>"$err"

    if ! dyn_guard "$name" strace; then
        # Keep the metadata section even when execution is unavailable.
        stage_write "$name" ok
        stage_set_status "$name" skipped "${STAGE_NOTE[$name]:-not applicable}; linkage still captured"
        if [[ $linkage_rc -ne 0 ]]; then
            stage_record_exec "$name" "readelf -d -- $RUN_TARGET" "$linkage_rc"
            stage_set_status "$name" failed "library metadata failed (exit $linkage_rc); trace skipped"
        fi
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
    if [[ $linkage_rc -ne 0 && $rc -eq 0 ]]; then
        stage_record_exec "$name" "readelf -d -- $RUN_TARGET" "$linkage_rc"
        stage_set_status "$name" failed "trace captured, but library metadata failed (exit $linkage_rc)"
    fi
    return 0
}
