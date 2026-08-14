#!/usr/bin/env bash
# lib/stage_checksec.sh — Stage 5 (new in v6, deviation D2): mitigations + metadata.
#
# Implemented in: M2.  Per v5 §4.1 this file must not enable `set -e`.
#
# The first thing any RE practitioner looks at: which mitigations are on, what the binary
# imports, what it exports, how it is linked. Cheap, fast, and it frames everything the
# heavier stages produce.
stage_checksec() {
    local name="checksec" out err
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"
    : > "$err"

    case "$RUN_FORMAT" in
        java|pyc|pyinstaller|archive)
            stage_skip "$name" "not applicable to a $RUN_FORMAT target"
            return 0 ;;
    esac

    {
        printf '=== Exploit mitigations (checksec) ===\n'
        # checksec 2.6.0 colours unconditionally — it ignores NO_COLOR and TERM=dumb —
        # so its output is filtered before it reaches the capture file.
        timeout -k 5 "$ST_T_LIGHT" checksec --file="$RUN_TARGET" 2>>"$err" | st_strip_ansi \
            || printf '(checksec produced no result for this format)\n'

        printf '\n=== Mitigations, machine-readable ===\n'
        timeout -k 5 "$ST_T_LIGHT" checksec --format=json --file="$RUN_TARGET" 2>>"$err" \
            | st_strip_ansi
        printf '\n'

        printf '\n=== Binary info (rabin2 -I) ===\n'
        timeout -k 5 "$ST_T_LIGHT" rabin2 -I -- "$RUN_TARGET" 2>>"$err"

        printf '\n=== Imports (rabin2 -i) ===\n'
        timeout -k 5 "$ST_T_LIGHT" rabin2 -i -- "$RUN_TARGET" 2>>"$err"

        printf '\n=== Exports (rabin2 -E) ===\n'
        timeout -k 5 "$ST_T_LIGHT" rabin2 -E -- "$RUN_TARGET" 2>>"$err"

        printf '\n=== Sections (rabin2 -S) ===\n'
        timeout -k 5 "$ST_T_LIGHT" rabin2 -S -- "$RUN_TARGET" 2>>"$err"

        printf '\n=== Linked libraries (rabin2 -l) ===\n'
        timeout -k 5 "$ST_T_LIGHT" rabin2 -l -- "$RUN_TARGET" 2>>"$err"
    } > "$out"

    stage_write "$name"
    return 0
}
