#!/usr/bin/env bash
# lib/stage_pydecomp.sh — Stage 12: Python bytecode decompilation.
#
# Implemented in: M3 (new in v6, deviation D2).  Must not enable `set -e`.
#
# Entered only when Stage 0 classified the target as .pyc, or extracted bytecode from a
# PyInstaller bundle. For those targets `strings` gets you the string constants and
# nothing else — this stage recovers the actual logic.
#
# Falls back through pycdc -> uncompyle6 -> Python's own `dis`. The last one always works
# because it ships with CPython, and a disassembly listing still shows the constants and
# control flow even when no decompiler is installed.
PYDECOMP_MAX_FILES="${PYDECOMP_MAX_FILES:-20}"

stage_pydecomp() {
    local name="pydecomp" out err
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"
    : > "$err"

    local -a targets=()
    case "$RUN_FORMAT" in
        pyc)         targets=("$RUN_TARGET") ;;
        pyinstaller) targets=("${TRIAGE_MEMBERS[@]:-}") ;;
        *)           stage_skip "$name" "not Python bytecode (this one is $RUN_FORMAT)"; return 0 ;;
    esac
    # An empty first element means TRIAGE_MEMBERS was unset.
    [[ ${#targets[@]} -gt 0 && -n ${targets[0]} ]] || {
        stage_skip "$name" "no Python bytecode was recovered to decompile"; return 0; }

    local tool="" 
    for cand in pycdc uncompyle6 decompyle3; do
        command -v "$cand" >/dev/null 2>&1 && { tool="$cand"; break; }
    done

    {
        if [[ -n $tool ]]; then
            printf '=== Python decompilation (%s) ===\n\n' "$tool"
        else
            printf '=== Python bytecode disassembly ===\n'
            printf 'No decompiler is installed (pycdc or uncompyle6 would give readable\n'
            printf 'source). Falling back to a bytecode listing, which still shows string\n'
            printf 'constants and control flow — a flag stored in a variable appears\n'
            printf 'verbatim in a LOAD_CONST.\n\n'
        fi
    } > "$out"

    local f n=0 any=0
    for f in "${targets[@]}"; do
        [[ -n $f && -f $f ]] || continue
        n=$(( n + 1 ))
        [[ $n -gt $PYDECOMP_MAX_FILES ]] && {
            printf '\n(capped at %s files)\n' "$PYDECOMP_MAX_FILES" >> "$out"; break; }

        printf '\n/* ---- %s ---- */\n' "$(basename "$f")" >> "$out"
        if [[ -n $tool ]]; then
            timeout -k 5 "$ST_T_DECOMP" "$tool" "$f" 2>>"$err" | st_strip_ansi >> "$out" && any=1
        else
            # NOT `python3 -m dis`: dis treats its argument as source, so a .pyc fails
            # with "source code string cannot contain null bytes". scripts/pyc_disasm.py
            # unmarshals the code object first.
            timeout -k 5 "$ST_T_DECOMP" python3 "$REVCTF_SCRIPTS/pyc_disasm.py" "$f" \
                2>>"$err" >> "$out" && any=1
        fi
    done

    stage_record_exec "$name" "${tool:-pyc_disasm.py} <${n} bytecode file(s)>" 0
    if [[ $any -eq 1 ]]; then
        stage_write "$name" ok
        stage_set_status "$name" ok "${tool:-bytecode listing} over $n file(s)"
    else
        stage_set_status "$name" failed \
            "could not decompile any bytecode — $(tail -c 160 "$err" 2>/dev/null | tr '\n' ' ')"
    fi
    return 0
}
