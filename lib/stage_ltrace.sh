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

    if [[ ${OPT[sandbox]:-0} -eq 1 ]]; then
        # The container path is M6. Failing loudly is the right behaviour meanwhile: a
        # silent fall-back to the host would run untrusted code the user explicitly asked
        # to isolate.
        stage_skip "$name" \
            "--sandbox was requested but the container is not built until M6; refusing to run the target on the host"
        return 0
    fi

    dyn_banner ltrace "${OPT[timeout]}" > "$out"
    dyn_run "$name" "${OPT[timeout]}" "$out.trace" "$err" \
        -- ltrace -f "$RUN_TARGET" || rc=$?
    cat "$out.trace" >> "$out" 2>/dev/null; rm -f "$out.trace"

    stage_record_exec "$name" "setsid timeout -k 5 ${OPT[timeout]} ltrace -f $RUN_TARGET </dev/null" "$rc"
    dyn_finish "$name" ltrace "${OPT[timeout]}" "$rc"
    return 0
}
