#!/usr/bin/env bash
# lib/stage_hexdump.sh — Stage 4: hex preview or full dump.
#
# Implemented in: M2.  Per v5 §4.1 this file must not enable `set -e`.
#
# Capped preview by default (v6 §8: 512 bytes), full dump under --full-hexdump. Both are
# streamed. v4 §5 requires a disk-space check immediately before a full dump, since that
# is one of the two steps most likely to consume a lot of disk mid-run.
stage_hexdump() {
    local name="hexdump" out size
    out="$(stage_out_path "$name")"
    size=$(st_file_size "$RUN_TARGET")

    if [[ ${OPT[full_hexdump]:-0} -eq 1 ]]; then
        # A full dump is roughly 4x the input. Check before committing to it.
        local need_mb=$(( (size * 4) / 1048576 + 16 ))
        if ! pf_check_disk "$RUN_OUTDIR" >/dev/null 2>&1 || [[ $PF_DISK_FREE_MB -lt $need_mb ]]; then
            stage_skip "$name" \
                "--full-hexdump needs about ${need_mb}MB but only ${PF_DISK_FREE_MB}MB is free"
            return 0
        fi
        printf '=== Full hex dump (%s) ===\n' "$(st_human_size "$size")" > "$out"
        local rc=0
        timeout -k 5 "$ST_T_LIGHT" hexdump -C -- "$RUN_TARGET" \
            >> "$out" 2>"$(stage_err_path "$name")" || rc=$?
        stage_record_exec "$name" "hexdump -C $RUN_TARGET" "$rc"
        if [[ $rc -eq 0 ]]; then
            stage_write "$name" ok
        else
            stage_set_status "$name" failed "hexdump exited $rc"
        fi
        return 0
    fi

    {
        printf '=== First %s bytes (preview — use --full-hexdump for the whole file) ===\n' \
            "$ST_HEXDUMP_PREVIEW"
        head -c "$ST_HEXDUMP_PREVIEW" -- "$RUN_TARGET" 2>/dev/null | hexdump -C
        if [[ $size -gt $((ST_HEXDUMP_PREVIEW * 2)) ]]; then
            printf '\n=== Last %s bytes ===\n' "$ST_HEXDUMP_PREVIEW"
            tail -c "$ST_HEXDUMP_PREVIEW" -- "$RUN_TARGET" 2>/dev/null | hexdump -C
        fi
        printf '\n(file is %s; preview capped at %s bytes per end)\n' \
            "$(st_human_size "$size")" "$ST_HEXDUMP_PREVIEW"
    } > "$out" 2>"$(stage_err_path "$name")"

    stage_write "$name"
    return 0
}
