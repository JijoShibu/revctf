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

# dyn_run <stage-name> <timeout> <stdout-file> <errfile> <trace-file> -- <tracer> [args...]
#
# Runs a tracer over the target inside its own session, then sweeps. Returns the tracer's
# exit status; sets DYN_SWEPT to 1 when orphans had to be killed.
declare -g DYN_SWEPT=0

# How many bytes of TRACE the tracer actually produced.
#
# BOTH TRACERS WRITE THEIR TRACE TO STDERR unless given `-o`. dyn_run sends stderr to the
# stage error file, which the report only quotes when a stage FAILS — so for every
# successful run the trace was captured, written to a file nobody reads, and dropped. The
# ltrace and strace captures held the banner plus whatever the TARGET printed on its own
# stdout, and dyn_finish then appended "the trace above is still valid" to a capture with no
# trace in it. Two of fourteen stages produced nothing, for the whole life of the project.
#
# Nothing caught it because every ltrace/strace check in the harness matched the banner or a
# skip path. The stages now pass `-o <trace-file>` and dyn_run measures THAT file, which
# also separates the tracer's own diagnostics (stderr) from its output (the trace) — they
# were previously interleaved in one stream.
#
# dyn_finish used to answer that question with `[[ -s $out ]]`, but `$out` is the stage
# capture, which dyn_banner has already written a header into (and, for strace, an ldd
# section). It is therefore never empty, so the test was always true: the "no trace at all"
# and "the tracer itself failed" branches were both unreachable, and a stage that captured
# nothing was reported as "partial trace kept". Measuring the trace file directly is the
# only way to distinguish "the target ran and said nothing" from "the tracer never worked".
declare -g DYN_TRACE_BYTES=0

# THIS FUNCTION USED TO LAUNCH THE TRACER ITSELF, AND THAT WAS A REAL DEFECT.
#
# It ran `setsid timeout -k 5 "$tmo" "$@" ... &` directly, which made it the only place in
# the codebase where an external tool started outside st_run_bounded — the rule CLAUDE.md §2
# states without exception. The reason it was written that way is legitimate: these stages
# need their own session so dyn_sweep_orphans has a process group to sweep, and
# st_run_bounded did not offer that.
#
# The cost was invisible. st_mem_prefix never ran, so the Phase-2 memory ceiling that
# tier_ceiling_for_stage returns for these stages was resolved, printed by --verbose as
# "[strace] memory ceiling 512MB via systemd", and enforced by absolutely nothing. That is
# the precise "reported but not enforced" defect M5 existed to eliminate, surviving inside
# M5 itself, because m5enforce hardcoded radare2 and floss and never asked which stages
# actually have a ceiling.
#
# st_run_bounded now offers ST_OWN_SESSION for exactly this case, so there is one launcher
# again and these stages are bounded like every other.
dyn_run() {
    local name="$1" tmo="$2" out="$3" err="$4" trace="$5"; shift 5
    [[ ${1:-} == "--" ]] && shift

    DYN_SWEPT=0
    local rc=0 pgid=""

    # shellcheck disable=SC2034  # read by st_run_bounded in lib/stage.sh, a separate file
    ST_OWN_SESSION=1
    st_run_bounded "$tmo" "$out" "$err" -- "$@" || rc=$?
    # shellcheck disable=SC2034  # same: cleared for the next stage, consumed cross-file
    ST_OWN_SESSION=0
    pgid="$ST_LAST_PGID"
    DYN_TRACE_BYTES="$(stat -c '%s' "$trace" 2>/dev/null || printf 0)"
    is_uint "$DYN_TRACE_BYTES" || DYN_TRACE_BYTES=0

    DYN_SWEPT=$(dyn_sweep_orphans "$pgid")
    return "$rc"
}

# dyn_compose <capture> <trace-file> <target-stdout-file> <trace-label>
#
# Assembles the stage capture from the two streams the run produced, and LABELS them. They
# used to be one undifferentiated blob, which is how "the target printed a usage line" was
# able to pass for "a trace was captured" — the reader had no way to tell which was which,
# and neither did the harness.
#
# The target's own output is worth keeping (a crackme's prompt is a real clue), so it is
# kept, under its own heading, clearly not part of the trace.
dyn_compose() {
    local cap="$1" trace="$2" tgt="$3" label="$4"

    {
        printf '=== %s ===\n' "${label^}"
        if [[ -s $trace ]]; then
            st_strip_ansi < "$trace" 2>/dev/null
        else
            printf '(the tracer produced no %s — see the stage status for why)\n' "$label"
        fi
        printf '\n'
        if [[ -s $tgt ]]; then
            printf "=== The target's own output (not part of the trace) ===\n"
            st_strip_ansi < "$tgt" 2>/dev/null
            printf '\n'
        fi
    } >> "$cap"

    rm -f "$trace" "$tgt"
    return 0
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
        0)   # A clean exit with an empty trace is NOT a success. It is what a broken tracer
             # invocation looks like, and it is exactly what this stage did for its whole
             # life while ltrace's output went to a stderr file nobody read. Saying "ok" to
             # it is how that survived.
             if [[ ${DYN_TRACE_BYTES:-0} -gt 0 ]]; then
                 stage_write "$name" ok
             else
                 stage_write "$name" empty
                 stage_set_status "$name" empty \
                     "$tool exited cleanly but captured no trace"
             fi
             ;;
        124|137)
            # 124 and 137 ARE NOT THE SAME EVENT and must never be reported as one.
            # 124 is `timeout` firing. 137 is a SIGKILL, which since M5 is how a cgroup
            # memory ceiling announces itself — and these stages DO carry one, because they
            # execute the target. Reporting a stage killed at its 512MB ceiling after one
            # second as "stopped after 300s" sends the reader to the wrong constant, which
            # is the exact regression st_explain_kill() was extracted to prevent across six
            # other stages. This pair was missed in that sweep.
            local why; why="$(st_explain_kill "$rc" "$tmo")"
            printf '\n[stopped] %s: %s\n' "$tool" "$why" >> "$out"
            if [[ $rc -eq 124 ]]; then
                printf '          For a binary that waits for input or loops, the trace\n' >> "$out"
                printf '          above is still the useful part.\n' >> "$out"
            else
                printf '          A target that allocates without bound is itself a finding;\n' >> "$out"
                printf '          the trace above is what it managed before it was killed.\n' >> "$out"
            fi
            # `$out` ALWAYS holds dyn_banner's header (and, for strace, the ldd section), so
            # `[[ -s $out ]]` is true even when the tracer emitted not one line. Testing it
            # made the "empty" branch unreachable and reported a stage that captured nothing
            # as "partial trace kept". The trace is what has to be non-empty, so that is what
            # is measured.
            if [[ ${DYN_TRACE_BYTES:-0} -gt 0 ]]; then
                stage_set_status "$name" ok "$why"
            else
                stage_set_status "$name" empty "$why — no trace was captured"
            fi
            ;;
        *)
            # A traced program exiting non-zero is completely normal — a crackme with no
            # password argument exits 1. Only the TRACER failing is a stage failure, and
            # that shows up as empty output plus a tracer diagnostic on stderr.
            if [[ ${DYN_TRACE_BYTES:-0} -gt 0 ]]; then
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
