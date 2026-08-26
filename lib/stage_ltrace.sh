#!/usr/bin/env bash
# lib/stage_ltrace.sh — Stage 7: library-call trace.
#
# Implemented in: M3.  Per v5 §4.1 this file must not enable `set -e`.
#
# EXECUTES THE TARGET. See lib/stage_dynamic.sh for the safety model.
#
# Invocation is v3 §5 step 8 verbatim: setsid + `timeout -k 5 <t>` + `-f` to follow forks
# + stdin closed, followed by an orphan process-group sweep.
stage_ltrace() {
    local name="ltrace" out err rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"

    if [[ ${OPT[skip_ltrace]:-0} -eq 1 ]]; then
        stage_skip "$name" "skipped by user request (--skip-ltrace)"
        return 0
    fi
    dyn_guard "$name" ltrace || return 0

    # `-o` is not optional. Without it ltrace writes the trace to STDERR, which dyn_run
    # routes to the stage error file — a file the report reads only when the stage fails.
    # The capture then contained the banner and the target's own stdout, and nothing else.
    #
    # Under the sandbox DYN_EXEC_ARG and DYN_TRACE_ARG are CONTAINER paths (/target,
    # /work/trace.ltrace); without it they are host paths. dyn_guard resolves which.
    dyn_banner ltrace "${OPT[timeout]}" > "$out"
    dyn_run "$name" "${OPT[timeout]}" "$out.stdout" "$err" "$DYN_TRACE_HOST" \
        -- ltrace -f -o "$DYN_TRACE_ARG" "$DYN_EXEC_ARG" || rc=$?
    dyn_compose "$out" "$DYN_TRACE_HOST" "$out.stdout" "library call trace"

    stage_record_exec "$name" "$(dyn_cmdline ltrace "${OPT[timeout]}" "-f -o $DYN_TRACE_ARG $DYN_EXEC_ARG")" "$rc"
    dyn_finish "$name" ltrace "${OPT[timeout]}" "$rc"
    return 0
}
