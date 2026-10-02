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
    if [[ $rc -ne 0 ]] && _ghidra_saw_oom "$RUN_OUTDIR/ghidra-attempt.0.stderr" "$RUN_OUTDIR/ghidra-attempt.0.stdout"; then
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
            stage_set_status "$name" partial "full decompile hit an OOM; light retry produced an inventory only"
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

    # _ghidra_attempt validates post-script completion as well as the launcher exit.
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
    local heap_mb guard
    heap_mb=$(tier_mb_of "$maxmem")
    [[ $heap_mb -gt 0 ]] || { printf 'REVCTF-ERROR: invalid heap allowance\n' >> "$err"; return 1; }
    guard="$RUN_OUTDIR/ghidra-memory.$light.txt"
    # _JAVA_OPTIONS is applied after the launcher's -Xmx by HotSpot. The guard below
    # verifies the actual runtime; unfamiliar launchers cannot silently bypass it.
    # Scope the override to this child, preserving the caller's environment.

    local -a cmd=(
        env "_JAVA_OPTIONS=${_JAVA_OPTIONS:+${_JAVA_OPTIONS} }-Xms16m -Xmx${heap_mb}m"
        "$PF_GHIDRA_HEADLESS" "$proj" revctf
        -import "$RUN_TARGET"
        -scriptPath "$REVCTF_SCRIPTS;$(cd -- "$(dirname -- "$script")" && pwd)"
        -preScript RevctfMemoryGuard.java "$guard" "$heap_mb"
        -postScript "$(basename "$script")" "$light"
        -deleteProject
    )

    local rawout="$RUN_OUTDIR/ghidra-attempt.$light.stdout" rawerr="$RUN_OUTDIR/ghidra-attempt.$light.stderr"
    st_run_bounded "$ST_T_GHIDRA" "$rawout" "$rawerr" -- "${cmd[@]}" || rc=$?
    # Preserve each attempt, including startup failures and memory verification.
    if [[ $rc -eq 0 ]] && ! grep -qx 'verified=1' "$guard" 2>/dev/null; then
        printf 'REVCTF-ERROR: actual Ghidra heap could not be verified within its allowance.\n' >> "$rawerr"
        rc=1
    fi
    {
        printf '\nGhidra attempt %s: requested heap %s MiB; process limit %s MiB; enforcement %s\n' "$light" "$heap_mb" "$ST_MEM_CEIL_MB" "$(st_mem_mode)"
        [[ -f $guard ]] && cat -- "$guard"
        [[ $(st_mem_mode) != systemd ]] && printf 'Whole-process memory enforcement is unavailable; only the Java heap and watchdog are bounded.\n'
    } >> "$out"

    # A successful launcher exit does not prove the post-script completed. Check this
    # attempt's files, not accumulated diagnostics from a failed first attempt.
    # Decompiled strings may themselves contain words such as SyntaxError; search the
    # launcher's diagnostics outside the result block for those broad error patterns.
    sed '/^=== REVCTF-GHIDRA-BEGIN ===$/,/^=== REVCTF-GHIDRA-END ===$/d' "$rawout" > "$out.log"
    if [[ $rc -eq 0 ]]; then
        if _ghidra_saw_script_error "$rawerr" || _ghidra_saw_script_error "$out.log" ||
                grep -qa '^REVCTF-ERROR:' "$rawout"; then
            printf 'REVCTF-ERROR: Ghidra post-script failed; partial output kept.\n' >> "$rawerr"
            rc=1
        elif ! awk '
            /^=== REVCTF-GHIDRA-BEGIN ===$/ { if (state != 0) bad=1; state=1 }
            /^=== REVCTF-GHIDRA-END ===$/ { if (state != 1) bad=1; state=2 }
            END { exit (bad || state != 2) }
        ' "$rawout"; then
            printf 'REVCTF-ERROR: Ghidra post-script completion markers missing; analysis incomplete.\n' >> "$rawerr"
            rc=1
        fi
    fi

    # analyzeHeadless is extremely chatty on stdout. Only the post-script's own output is
    # worth putting in the report; the rest goes to stderr capture for diagnostics.
    {
        sed -n '/^=== REVCTF-GHIDRA-BEGIN/,/^=== REVCTF-GHIDRA-END/p' "$rawout" 2>/dev/null \
            | grep -v '^=== REVCTF-GHIDRA-' \
            | st_strip_ansi
    } >> "$out"
    cat "$rawerr" >> "$err" 2>/dev/null
    # Ghidra writes INFO lines to stdout too; keep them out of the report but available.
    cat "$rawout" >> "$err" 2>/dev/null
    rm -f "$out.log"

    stage_record_exec "$name" "${cmd[*]}" "$rc"
    return "$rc"
}

# Ghidra reports heap exhaustion in several shapes depending on where it happened.
_ghidra_saw_oom() {
    # Ignore decompiled challenge text that merely mentions a Java error.
    sed '/^=== REVCTF-GHIDRA-BEGIN ===$/,/^=== REVCTF-GHIDRA-END ===$/d' "$@" 2>/dev/null |
        grep -iE 'java\.lang\.OutOfMemoryError|GC overhead limit|unable to create.*native thread|Java heap space' >/dev/null
}
