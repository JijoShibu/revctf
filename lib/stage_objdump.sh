#!/usr/bin/env bash
# lib/stage_objdump.sh — Stage 6 (new in v6, deviation D2): binutils cross-check.
#
# Implemented in: M2.  Per v5 §4.1 this file must not enable `set -e`.
#
# readelf/objdump give a second, independent reading of the binary's structure. When they
# and radare2 disagree, that disagreement is itself a finding — obfuscated and
# deliberately-malformed CTF binaries often break one parser but not the other.
#
# Disassembly is capped: a full -d of a large binary can run to hundreds of megabytes, and
# the report is meant to be read.
OBJDUMP_DISASM_LINES="${OBJDUMP_DISASM_LINES:-4000}"

# Run each parser through the common limits and keep its real exit code. Truncate the
# saved disassembly only after the command exits, so head cannot hide a parser failure.
_objdump_part() {
    local lines="$1"; shift
    local rc=0 raw="$RUN_WORKDIR/binutils.raw" err="$RUN_WORKDIR/binutils.err"
    st_run_bounded "$ST_T_LIGHT" "$raw" "$err" -- "$@" || rc=$?
    cat "$err" >> "$(stage_err_path objdump)" 2>/dev/null
    if [[ $lines -gt 0 ]]; then head -n "$lines" "$raw"; else cat "$raw"; fi
    if [[ $rc -ne 0 ]]; then
        printf '\n(command failed with exit %s; partial output kept)\n' "$rc"
        stage_record_exec objdump "$*" "$rc"
    fi
    rm -f "$raw" "$err"
    return "$rc"
}

stage_objdump() {
    local name="objdump" out err rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"
    : > "$err"

    case "$RUN_FORMAT" in
        java|pyc|pyinstaller|archive)
            stage_skip "$name" "not applicable to a $RUN_FORMAT target"
            return 0 ;;
    esac

    {
        if [[ $RUN_FORMAT == elf ]]; then
            printf '=== ELF header (readelf -h) ===\n'
            _objdump_part 0 readelf -h -- "$RUN_TARGET" || rc=$?

            printf '\n=== Sections (readelf -S) ===\n'
            _objdump_part 0 readelf -S -W -- "$RUN_TARGET" || rc=$?

            printf '\n=== Dynamic symbols (readelf --dyn-syms) ===\n'
            _objdump_part 0 readelf --dyn-syms -W -- "$RUN_TARGET" || rc=$?

            printf '\n=== Relocations (readelf -r) ===\n'
            _objdump_part 0 readelf -r -W -- "$RUN_TARGET" || rc=$?
        else
            printf '=== Headers (objdump -f) ===\n'
            _objdump_part 0 objdump -f -- "$RUN_TARGET" || rc=$?

            printf '\n=== Section headers (objdump -h) ===\n'
            _objdump_part 0 objdump -h -- "$RUN_TARGET" || rc=$?
        fi

        printf '\n=== Symbol table (objdump -t) ===\n'
        _objdump_part 0 objdump -t -- "$RUN_TARGET" || rc=$?

        printf '\n=== Disassembly of executable sections (objdump -d, first %s lines) ===\n' \
            "$OBJDUMP_DISASM_LINES"
        _objdump_part "$OBJDUMP_DISASM_LINES" objdump -d -- "$RUN_TARGET" || rc=$?
        printf '\n(disassembly capped at %s lines; radare2 and Ghidra sections below go deeper)\n' \
            "$OBJDUMP_DISASM_LINES"
    } > "$out"

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        stage_set_status "$name" failed "$(st_explain_kill "$rc" "$ST_T_LIGHT")"
    elif [[ $rc -ne 0 ]]; then
        stage_set_status "$name" failed "one or more binutils commands failed (last failure: exit $rc; partial output kept)"
    else
        stage_write "$name"
    fi
    return 0
}
