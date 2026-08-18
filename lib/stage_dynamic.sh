#!/usr/bin/env bash
# lib/stage_dynamic.sh — shared machinery for the stages that EXECUTE the target.
#
# Implemented in: M3.
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`.
#
# ======================================================================================
# READ THIS BEFORE CHANGING ANYTHING HERE
# ======================================================================================
# ltrace and strace are the only stages that RUN the challenge binary. Everything else
# reads bytes. That difference is the whole reason this file exists:
#
#   - The target is hostile by assumption. It may fork, spawn, trap signals, allocate
#     without bound, or simply never exit.
#   - `timeout` alone is not enough. It signals the process it launched; a target that has
#     forked leaves children behind. v3 §5 step 8 therefore specifies `setsid` plus a
#     process-group sweep, and that sweep is implemented here rather than per stage.
#   - Until M6 lands the Docker sandbox, this runs on the HOST. Every report section
#     produced here says so, in as many words.
#
# v5 §3 scoped `--sandbox` to ltrace only. That predates the strace stage, which executes
# the target just as directly — leaving it outside the sandbox would make `--sandbox` a
# false assurance. Deviation D9 (v6 §11): the sandbox covers every executing stage.

# dyn_banner <tool> — the warning block that heads every executing stage's capture.
dyn_banner() {
    local tool="$1"
    printf '=== %s — THIS STAGE EXECUTES THE TARGET ===\n' "${tool^^}"
    if [[ ${OPT[sandbox]:-0} -eq 1 ]]; then
        printf 'Isolation : Docker container requested (--sandbox)\n'
    else
        printf 'Isolation : NONE — the challenge binary ran directly on this machine.\n'
        printf '            Pass --sandbox to run it in a network-isolated container\n'
        printf '            instead, or --skip-ltrace / --skip-strace to not run it.\n'
    fi
    printf 'Bounds    : killed after %ss; orphaned processes swept afterwards\n' "$2"
    printf 'Arguments : none — the target is run with no argv and stdin closed\n'
    printf '\n'
}

# dyn_guard <stage-name> <tool> — common preconditions for an executing stage.
# Returns 0 to proceed, 1 if the stage recorded a skip and the caller should return.
dyn_guard() {
    local name="$1" tool="$2"

    if ! command -v "$tool" >/dev/null 2>&1; then
        stage_skip "$name" "$tool is not installed"
        return 1
    fi

    # v3 §5 step 8 gates the dynamic stages on ELF. A PE or Mach-O will not execute here,
    # and a .jar or .pyc is not a native program at all.
    if ! st_is_elf; then
        stage_skip "$name" "only runs on ELF targets (this one is $RUN_FORMAT)"
        return 1
    fi

    # Refusing to execute something the kernel will refuse anyway, with a clearer message.
    if [[ ! -x $RUN_TARGET ]]; then
        stage_skip "$name" "target is not executable (chmod +x it to enable dynamic analysis)"
        return 1
    fi
    return 0
}

# dyn_sweep_orphans <pgid> — kill anything the target left behind.
#
# The sweep, not the timeout, is what makes this safe. `setsid` puts the target in its own
# process group; after the traced run ends, everything still alive in that group is a
# child the target spawned and did not reap. Without this, a forking challenge binary
# survives the scan.
dyn_sweep_orphans() {
    local pgid="$1" swept=0
    [[ -n $pgid && $pgid -gt 1 ]] || return 0

    if kill -0 -- "-$pgid" 2>/dev/null; then
        kill -TERM -- "-$pgid" 2>/dev/null
        local waited=0
        while kill -0 -- "-$pgid" 2>/dev/null && [[ $waited -lt 20 ]]; do
            sleep 0.1; waited=$(( waited + 1 ))
        done
        kill -KILL -- "-$pgid" 2>/dev/null
        swept=1
    fi
    printf '%s' "$swept"
    return 0
}

# dyn_run <stage-name> <timeout> <outfile> <errfile> -- <tracer> [args...] <target>
#
# Runs a tracer over the target inside its own session, then sweeps. Returns the tracer's
# exit status; sets DYN_SWEPT to 1 when orphans had to be killed.
declare -g DYN_SWEPT=0

dyn_run() {
    local name="$1" tmo="$2" out="$3" err="$4"; shift 4
    [[ ${1:-} == "--" ]] && shift

    DYN_SWEPT=0
    local rc=0 pgid=""

    # `setsid` gives the tracer and the target their own process group, so the sweep below
    # can target it without touching revctf itself. stdin is closed (</dev/null) so a
    # target that reads input cannot block forever waiting for a terminal that will never
    # answer — v3 §5 step 8 calls this out explicitly.
    setsid timeout -k 5 "$tmo" "$@" >"$out" 2>"$err" </dev/null &
    ST_CHILD_PID=$!
    # The setsid'd child is its own group leader, so its PID is the PGID.
    pgid=$ST_CHILD_PID
    wait "$ST_CHILD_PID" || rc=$?
    ST_CHILD_PID=""

    DYN_SWEPT=$(dyn_sweep_orphans "$pgid")
    return "$rc"
}

# dyn_finish <stage-name> <tool> <timeout> <rc> — shared status classification.
dyn_finish() {
    local name="$1" tool="$2" tmo="$3" rc="$4"
    local out; out="$(stage_out_path "$name")"

    if [[ ${DYN_SWEPT:-0} -eq 1 ]]; then
        printf '\n[orphan sweep] the target left processes running after the trace ended;\n' >> "$out"
        printf '               they were terminated.\n' >> "$out"
    fi

    case "$rc" in
        0)   stage_write "$name" ;;
        124|137)
            # A timeout here is information, not a failure: a challenge that loops forever
            # under tracing is telling you something. The partial trace is usually the
            # interesting part, so it is kept and the stage is not marked failed.
            printf '\n[timeout] %s was stopped after %ss. For a binary that waits for input\n' \
                "$tool" "$tmo" >> "$out"
            printf '          or loops, the trace above is still the useful part.\n' >> "$out"
            if [[ -s $out ]]; then
                stage_set_status "$name" ok "stopped after ${tmo}s; partial trace kept"
            else
                stage_set_status "$name" empty "stopped after ${tmo}s before producing output"
            fi
            ;;
        *)
            # A traced program exiting non-zero is completely normal — a crackme with no
            # password argument exits 1. Only the TRACER failing is a stage failure, and
            # that shows up as empty output plus a tracer diagnostic on stderr.
            if [[ -s $out ]]; then
                printf '\n[note] the traced program exited %s. That is normal for a challenge\n' "$rc" >> "$out"
                printf '       run with no arguments; the trace above is still valid.\n' >> "$out"
                stage_write "$name" ok
            else
                local tail_err=""
                tail_err=$(tail -c 200 "$(stage_err_path "$name")" 2>/dev/null | tr '\n' ' ')
                stage_set_status "$name" failed \
                    "$tool produced no trace (exit $rc)${tail_err:+: $tail_err}"
            fi
            ;;
    esac
    return 0
}
