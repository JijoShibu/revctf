#!/usr/bin/env bash
# lib/stage_ghidra.sh — Stage 13: headless decompilation.
#
# Implemented in: M3.  Per v5 §4.1 this file must not enable `set -e`.
#
# Three things this stage has to get right:
#
#  1. THE POST-SCRIPT RUNTIME. Chosen by preflight, which probes the install for
#     Ghidra/Features/{PyGhidra,Jython} rather than trusting a version number. v3 §1's
#     "11.x+ means PyGhidra" is wrong: 11.2.1 still ships Jython and runs .py under
#     Jython 2.7.3. Handing a Python-3 script to that interpreter fails on the first
#     f-string. PF_GHIDRA_SCRIPT_KIND carries the answer.
#
#  2. THE PROJECT IS THROWAWAY. `-deleteProject` plus a work-directory project root, so
#     nothing survives the scan. A Ghidra project left behind is both clutter and a disk
#     leak across a batch.
#
#  3. OOM SELF-HEALS. v4 §4 item 6: on an out-of-memory in stderr, retry that file once
#     with light decompilation rather than merely suggesting it. --force-full-decompile
#     disables the retry for someone who wants the hard failure.

stage_ghidra() {
    local name="ghidra" out err rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"
    : > "$err"

    if [[ ${OPT[skip_ghidra]:-0} -eq 1 ]]; then
        stage_skip "$name" "skipped by user request (--skip-ghidra); radare2 disassembly substitutes"
        return 0
    fi
    if [[ ${OPT[light_decompile]:-0} -eq 1 ]]; then
        stage_skip "$name" "--light-decompile: radare2 disassembly substitutes for Ghidra"
        return 0
    fi
    if [[ -z ${PF_GHIDRA_HEADLESS:-} ]]; then
        stage_skip "$name" "no Ghidra install was found"
        return 0
    fi
    case "$RUN_FORMAT" in
        java|pyc|pyinstaller|archive)
            stage_skip "$name" "not a native binary (this one is $RUN_FORMAT); decompiled elsewhere"
            return 0 ;;
    esac

    # --- choose the post-script -------------------------------------------------------
    local script
    if [[ -n ${OPT[ghidra_script]} ]]; then
        script="${OPT[ghidra_script]}"
    elif [[ ${PF_GHIDRA_SCRIPT_KIND:-jython} == pyghidra ]]; then
        script="$REVCTF_SCRIPTS/pyghidra_decompile.py"
    else
        script="$REVCTF_SCRIPTS/jython_decompile.py"
    fi
    if [[ ! -r $script ]]; then
        stage_set_status "$name" failed "post-script not readable: $script"
        return 0
    fi

    # v4 §5: check disk before creating a project — Ghidra projects are one of the two
    # steps most likely to consume a lot of disk mid-run.
    if ! pf_check_disk "$RUN_WORKDIR" >/dev/null 2>&1; then
        stage_set_status "$name" failed "not enough free disk to create a Ghidra project"
        return 0
    fi

    _ghidra_attempt "$name" "$script" "$out" "$err" 0
    rc=$?

    # --- OOM self-heal (v4 §4 item 6) -------------------------------------------------
    if [[ $rc -ne 0 ]] && _ghidra_saw_oom "$err"; then
        if [[ ${OPT[force_full_decompile]:-0} -eq 1 ]]; then
            stage_set_status "$name" failed \
                "Ghidra ran out of memory; --force-full-decompile disabled the automatic light retry"
            return 0
        fi
        {
            printf '\n=== Ghidra ran out of memory — retrying with light decompilation ===\n'
            printf 'The full decompile exceeded the JVM heap for this binary. revctf is\n'
            printf 'retrying automatically with function listing only; radare2 above has\n'
            printf 'the disassembly.\n\n'
        } >> "$out"
        _ghidra_attempt "$name" "$script" "$out" "$err" 1
        rc=$?
        if [[ $rc -eq 0 ]]; then
            stage_write "$name" ok
            stage_set_status "$name" ok "full decompile hit an OOM; light retry succeeded"
            return 0
        fi
        stage_set_status "$name" failed "Ghidra ran out of memory and the light retry also failed"
        return 0
    fi

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        stage_set_status "$name" failed "timed out after ${ST_T_GHIDRA}s (partial output kept)"
        return 0
    fi
    if [[ $rc -ne 0 ]]; then
        stage_set_status "$name" failed \
            "analyzeHeadless exited $rc — $(grep -aiEm1 '(error|exception)' "$err" 2>/dev/null | head -c 160)"
        return 0
    fi
    stage_write "$name"
    return 0
}

# _ghidra_attempt <name> <script> <out> <err> <light:0|1>
_ghidra_attempt() {
    local name="$1" script="$2" out="$3" err="$4" light="$5"
    local proj rc=0

    # A fresh project root per attempt, inside the per-file work directory, so the
    # trap-based cleanup already removes it even if -deleteProject does not run.
    proj="$RUN_WORKDIR/ghidra-proj.$light"
    mkdir -p "$proj" || { printf 'could not create a project directory\n' >> "$err"; return 1; }

    # MAXMEM is tier-driven from M5; until then --maxmem-ghidra or a conservative default.
    local maxmem="${OPT[maxmem_ghidra]:-1024M}"
    export MAXMEM="$maxmem"
    # v4 §4 item 4: a second, percentage-based bound alongside MAXMEM, so the two agree
    # rather than fight.
    export _JAVA_OPTIONS="-XX:MaxRAMPercentage=25"

    local -a cmd=(
        "$PF_GHIDRA_HEADLESS" "$proj" revctf
        -import "$RUN_TARGET"
        -scriptPath "$REVCTF_SCRIPTS"
        -postScript "$(basename "$script")" "$light"
        -deleteProject
    )

    st_run_bounded "$ST_T_GHIDRA" "$out.g" "$err.g" -- "${cmd[@]}" || rc=$?

    # analyzeHeadless is extremely chatty on stdout. Only the post-script's own output is
    # worth putting in the report; the rest goes to stderr capture for diagnostics.
    {
        sed -n '/^=== REVCTF-GHIDRA-BEGIN/,/^=== REVCTF-GHIDRA-END/p' "$out.g" 2>/dev/null \
            | grep -v '^=== REVCTF-GHIDRA-' \
            | st_strip_ansi
    } >> "$out"
    cat "$err.g" >> "$err" 2>/dev/null
    # Ghidra writes INFO lines to stdout too; keep them out of the report but available.
    cat "$out.g" >> "$err" 2>/dev/null
    rm -f "$out.g" "$err.g"

    stage_record_exec "$name" "${cmd[*]}" "$rc"
    unset MAXMEM _JAVA_OPTIONS
    return "$rc"
}

# Ghidra reports heap exhaustion in several shapes depending on where it happened.
_ghidra_saw_oom() {
    grep -qaiE 'java\.lang\.OutOfMemoryError|GC overhead limit|unable to create.*native thread|Java heap space' "$1" 2>/dev/null
}
