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
        stage_set_status "$name" failed "$(st_explain_kill "$rc" "$ST_T_GHIDRA")"
        return 0
    fi
    if [[ $rc -ne 0 ]]; then
        stage_set_status "$name" failed \
            "analyzeHeadless exited $rc — $(grep -aiEm1 '(error|exception)' "$err" 2>/dev/null | head -c 160)"
        return 0
    fi

    # analyzeHeadless EXITS 0 EVEN WHEN THE POST-SCRIPT FAILED TO LOAD OR THREW.
    # Observed on Ghidra 12.1.3: the PyGhidra script died with
    #   "Ghidra was not started with PyGhidra. Python is not available"
    # and the stage was recorded as `empty / 0B / exit 0` — a clean-looking negative on a
    # binary whose password Ghidra 11.2.1 recovers. CLAUDE.md §3 already warned that this
    # class of failure "shows up only as an empty Ghidra stage, exit 0"; nothing was
    # actually checking for it. An empty capture plus a script error in stderr is a
    # FAILURE, and saying so is the difference between "no flag here" and "this tool never
    # ran".
    if [[ ! -s $out ]] && _ghidra_saw_script_error "$err"; then
        # Quote whatever Ghidra actually said. The alternation has to match the same set as
        # _ghidra_saw_script_error, or the stage reports a failure with a blank reason —
        # which is barely better than the empty stage it replaced.
        stage_set_status "$name" failed \
            "the Ghidra post-script did not run — $(grep -aoiEm1 '(GhidraScriptLoadException|SCRIPT ERROR|SyntaxError|Unable to load script|not started with PyGhidra)[^\n]{0,120}' "$err" 2>/dev/null | head -c 160)"
        return 0
    fi

    stage_write "$name"
    return 0
}

# A post-script that failed to load, or threw, while analyzeHeadless still exited 0.
#
# The patterns are deliberately several, because the shape of this failure depends on HOW
# the script died and they look nothing alike. Two observed on this project:
#   Ghidra 12.1.3, PyGhidra not enabled -> "GhidraScriptLoadException: Ghidra was not
#                                           started with PyGhidra"
#   Jython, unparseable script          -> "SyntaxError: no viable alternative at input"
# Both produced an empty capture and exit 0. Anchor `SyntaxError`/`Traceback` to the
# interpreter rather than to a phrase, so a future interpreter's wording still matches.
_ghidra_saw_script_error() {
    grep -qaiE 'SCRIPT ERROR|GhidraScriptLoadException|Unable to load script|not started with PyGhidra|Python is not available|SyntaxError|Traceback \(most recent call last\)' \
        "$1" 2>/dev/null
}

# _ghidra_attempt <name> <script> <out> <err> <light:0|1>
_ghidra_attempt() {
    local name="$1" script="$2" out="$3" err="$4" light="$5"
    local proj rc=0

    # A fresh project root per attempt, inside the per-file work directory, so the
    # trap-based cleanup already removes it even if -deleteProject does not run.
    proj="$RUN_WORKDIR/ghidra-proj.$light"
    mkdir -p "$proj" || { printf 'could not create a project directory\n' >> "$err"; return 1; }

    # MAXMEM is tier-driven (M5). It was previously hardcoded to 1024M — Tier A's value —
    # so a Tier C host with 2GB of RAM ran Ghidra with double the ceiling its tier
    # specifies, which is exactly the OOM the tier table exists to prevent. tier_resolve
    # has already folded --maxmem-ghidra into TIER_MAXMEM_GHIDRA, so the override still
    # wins here without this file re-reading OPT.
    local maxmem="${TIER_MAXMEM_GHIDRA:-${OPT[maxmem_ghidra]:-1024M}}"
    export MAXMEM="$maxmem"
    # v4 §4 item 4: a second, percentage-based bound alongside MAXMEM, so the two agree
    # rather than fight. Tier-driven for the same reason as MAXMEM.
    export _JAVA_OPTIONS="-XX:MaxRAMPercentage=${TIER_JVM_RAM_PCT:-25}"

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
