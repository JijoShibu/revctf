#!/usr/bin/env bash
# lib/stage_file.sh — Stage 1: classify the target.
#
# Implemented in: M2.  Per v5 §4.1 this file must not enable `set -e`.
#
# Stage 0 already classified the target into RUN_FORMAT; this stage records the raw
# evidence behind that classification so the report shows what the decision was based on,
# and so a misclassification is visible rather than silent.
stage_file() {
    local name="file" out
    out="$(stage_out_path "$name")"

    {
        printf '=== file(1) on the target ===\n'
        file -- "$RUN_TARGET" 2>&1
        if [[ $RUN_TARGET != "$RUN_ORIGINAL" ]]; then
            printf '\n=== file(1) on the original (before unwrap) ===\n'
            file -- "$RUN_ORIGINAL" 2>&1
        fi
        printf '\n=== MIME type ===\n'
        file -bi -- "$RUN_TARGET" 2>&1
        printf '\n=== First 16 bytes (magic) ===\n'
        head -c 16 -- "$RUN_TARGET" 2>/dev/null | od -An -tx1z
        printf '\nresolved format: %s\n' "$RUN_FORMAT"
    } > "$out" 2>&1

    stage_write "$name"
    return 0
}
