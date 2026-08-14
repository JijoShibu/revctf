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

stage_objdump() {
    local name="objdump" out err
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
            timeout -k 5 "$ST_T_LIGHT" readelf -h -- "$RUN_TARGET" 2>>"$err"

            printf '\n=== Sections (readelf -S) ===\n'
            timeout -k 5 "$ST_T_LIGHT" readelf -S -W -- "$RUN_TARGET" 2>>"$err"

            printf '\n=== Dynamic symbols (readelf --dyn-syms) ===\n'
            timeout -k 5 "$ST_T_LIGHT" readelf --dyn-syms -W -- "$RUN_TARGET" 2>>"$err"

            printf '\n=== Relocations (readelf -r) ===\n'
            timeout -k 5 "$ST_T_LIGHT" readelf -r -W -- "$RUN_TARGET" 2>>"$err"
        else
            printf '=== Headers (objdump -f) ===\n'
            timeout -k 5 "$ST_T_LIGHT" objdump -f -- "$RUN_TARGET" 2>>"$err"

            printf '\n=== Section headers (objdump -h) ===\n'
            timeout -k 5 "$ST_T_LIGHT" objdump -h -- "$RUN_TARGET" 2>>"$err"
        fi

        printf '\n=== Symbol table (objdump -t) ===\n'
        timeout -k 5 "$ST_T_LIGHT" objdump -t -- "$RUN_TARGET" 2>>"$err" \
            || printf '(no symbol table — the binary is probably stripped)\n'

        printf '\n=== Disassembly of executable sections (objdump -d, first %s lines) ===\n' \
            "$OBJDUMP_DISASM_LINES"
        timeout -k 5 "$ST_T_LIGHT" objdump -d -- "$RUN_TARGET" 2>>"$err" \
            | head -n "$OBJDUMP_DISASM_LINES"
        printf '\n(disassembly capped at %s lines; radare2 and Ghidra sections below go deeper)\n' \
            "$OBJDUMP_DISASM_LINES"
    } > "$out"

    stage_write "$name"
    return 0
}
