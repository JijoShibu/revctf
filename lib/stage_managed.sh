#!/usr/bin/env bash
# lib/stage_managed.sh — Stage 11: Java and .NET decompilation.
#
# Implemented in: M3 (new in v6, deviation D2).  Must not enable `set -e`.
#
# Entered only when Stage 0 routed here. For a managed assembly the native pipeline is
# close to useless — radare2 and Ghidra on a .jar produce confident noise — so this is the
# stage that actually answers the question for those targets.
#
# Several decompilers exist for each ecosystem and none is universally packaged, so each
# is tried in turn. Per deviation D7 these are PF_CONDITIONAL_TOOLS: absent means the
# stage fails with an install hint at the point of use, not a refusal to start the scan.
MANAGED_MAX_LINES="${MANAGED_MAX_LINES:-6000}"

stage_managed() {
    local name="managed" out err rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"
    : > "$err"

    case "$RUN_FORMAT" in
        java)   _managed_java   "$name" "$out" "$err" ;;
        dotnet) _managed_dotnet "$name" "$out" "$err" ;;
        *)      stage_skip "$name" "not a managed assembly (this one is $RUN_FORMAT)"; return 0 ;;
    esac
    rc=$?
    return "$rc"
}

_managed_java() {
    local name="$1" out="$2" err="$3" tool="" rc=0
    for cand in jd-cli procyon cfr; do
        command -v "$cand" >/dev/null 2>&1 && { tool="$cand"; break; }
    done
    if [[ -z $tool ]]; then
        stage_set_status "$name" failed \
            "no Java decompiler found — install one of jd-cli, procyon or cfr (or re-run install.sh)"
        return 0
    fi

    local -a cmd
    case "$tool" in
        jd-cli)   cmd=(jd-cli --outputConsole "$RUN_TARGET") ;;
        procyon)  cmd=(procyon "$RUN_TARGET") ;;
        cfr)      cmd=(cfr "$RUN_TARGET") ;;
    esac

    printf '=== Java decompilation (%s) ===\n\n' "$tool" > "$out"
    st_run_bounded "$ST_T_DECOMP" "$out.d" "$err" -- "${cmd[@]}" || rc=$?
    head -n "$MANAGED_MAX_LINES" "$out.d" 2>/dev/null | st_strip_ansi >> "$out"
    if [[ $(wc -l < "$out.d" 2>/dev/null || echo 0) -gt $MANAGED_MAX_LINES ]]; then
        printf '\n(decompilation capped at %s lines)\n' "$MANAGED_MAX_LINES" >> "$out"
    fi
    rm -f "$out.d"

    stage_record_exec "$name" "${cmd[*]}" "$rc"
    _managed_classify "$name" "$tool" "$rc"
    return 0
}

_managed_dotnet() {
    local name="$1" out="$2" err="$3" tool="" rc=0
    for cand in ilspycmd monodis; do
        command -v "$cand" >/dev/null 2>&1 && { tool="$cand"; break; }
    done
    if [[ -z $tool ]]; then
        stage_set_status "$name" failed \
            "no .NET decompiler found — install ilspycmd (dotnet tool install -g ilspycmd) or mono-utils"
        return 0
    fi

    local -a cmd
    case "$tool" in
        ilspycmd) cmd=(ilspycmd "$RUN_TARGET") ;;
        monodis)  cmd=(monodis "$RUN_TARGET") ;;
    esac

    printf '=== .NET decompilation (%s) ===\n\n' "$tool" > "$out"
    st_run_bounded "$ST_T_DECOMP" "$out.d" "$err" -- "${cmd[@]}" || rc=$?
    head -n "$MANAGED_MAX_LINES" "$out.d" 2>/dev/null | st_strip_ansi >> "$out"
    rm -f "$out.d"

    stage_record_exec "$name" "${cmd[*]}" "$rc"
    _managed_classify "$name" "$tool" "$rc"
    return 0
}

_managed_classify() {
    local name="$1" tool="$2" rc="$3"
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        stage_set_status "$name" failed "timed out after ${ST_T_DECOMP}s (partial output kept)"
    elif [[ $rc -ne 0 ]]; then
        stage_set_status "$name" failed "$tool exited $rc"
    else
        stage_write "$name" ok
        stage_set_status "$name" ok "decompiled with $tool"
    fi
    return 0
}
