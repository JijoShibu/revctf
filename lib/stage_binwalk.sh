#!/usr/bin/env bash
# lib/stage_binwalk.sh — Stage 3: embedded-file and signature scan.
#
# Implemented in: M2.  Per v5 §4.1 this file must not enable `set -e`.
#
# Two things this stage has to get right, both called out in the masterplans:
#
#  1. Version branching by NUMERIC MAJOR, never a `"3."` substring match (v3 §4 item 9),
#     so a future binwalk 4.x does not silently fall through to the legacy branch.
#     PF_BINWALK_MAJOR comes from M1's three-strategy detection.
#
#  2. Output validation with a raw-capture fallback (v4 §5). If a future binwalk renames
#     a column or changes its banner, the parse can quietly yield nothing — which reads
#     in the report as "no embedded files found", a confident and wrong negative. So the
#     output is checked for a recognisable signature table, and on failure the stage keeps
#     the raw text and says the validation failed rather than reporting an empty result.

stage_binwalk() {
    local name="binwalk" out err rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"

    # No `--` end-of-options marker: binwalk 2.x treats it as a filename and fails with
    # "Cannot open file --". RUN_TARGET is absolutised by stage_begin_file(), so it can
    # never be mistaken for an option anyway.
    local -a cmd
    if [[ ${PF_BINWALK_MAJOR:-0} -ge 3 ]]; then
        # binwalk 3.x is the Rust rewrite; it takes an explicit output format.
        cmd=(binwalk --format=text "$RUN_TARGET")
    else
        # 2.x (Python). A bare invocation is the signature scan.
        cmd=(binwalk "$RUN_TARGET")
    fi

    # Via st_run_bounded so Ctrl+C is honoured immediately — running the tool in the
    # foreground made this stage swallow an interrupt for its whole 70s duration on a
    # large target.
    st_run_bounded "$ST_T_BINWALK" "$out" "$err" -- "${cmd[@]}" || rc=$?

    stage_record_exec "$name" "${cmd[*]}" "$rc"

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        stage_set_status "$name" failed "timed out after ${ST_T_BINWALK}s (partial output kept)"
        return 0
    fi
    if [[ $rc -ne 0 ]]; then
        stage_set_status "$name" failed "binwalk exited $rc"
        return 0
    fi

    # --- output validation ---
    # Both generations print a DECIMAL/HEXADECIMAL/DESCRIPTION header for a signature
    # scan. Its absence means either a genuinely empty scan or a changed output format,
    # and those two must not look the same in the report.
    if grep -qiE '^[[:space:]]*DECIMAL[[:space:]]+HEX' "$out"; then
        # Header present: count the data rows beneath it.
        local rows
        rows=$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+0x[0-9A-Fa-f]+' "$out")
        if [[ ${rows:-0} -gt 0 ]]; then
            stage_set_status "$name" ok ""
        else
            stage_set_status "$name" empty "no embedded files or known signatures found"
        fi
        return 0
    fi

    if [[ -s $out ]]; then
        {
            printf '\n'
            printf '=== parse validation failed — raw output above ===\n'
            printf 'binwalk %s produced output that does not match the expected\n' \
                "${PF_VERSION[binwalk]:-unknown}"
            printf 'signature-table format, so revctf is showing it verbatim rather than\n'
            printf 'reporting an empty result. Treat this section as unparsed, not as\n'
            printf 'evidence that nothing was found.\n'
        } >> "$out"
        stage_set_status "$name" ok "parse validation failed — raw output kept verbatim"
    else
        stage_set_status "$name" empty "no embedded files or known signatures found"
    fi
    return 0
}
