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
#   - Since M6 the target runs inside a Docker container by default (deviation D13):
#     --network=none --read-only --cap-drop=ALL, as a non-root user, with the tier's
#     Phase-2 memory ceiling. lib/sandbox.sh owns that contract. --no-sandbox opts out,
#     and every report section says which of the two actually happened.
#
# v5 §3 scoped `--sandbox` to ltrace only. That predates the strace stage, which executes
# the target just as directly — leaving it outside the sandbox would make `--sandbox` a
# false assurance. Deviation D9 (v6 §11): the sandbox covers every executing stage.

# dyn_banner <tool> — the warning block that heads every executing stage's capture.
dyn_banner() {
    local tool="$1"
    printf '=== %s — THIS STAGE EXECUTES THE TARGET ===\n' "${tool^^}"
    if [[ ${DYN_SANDBOXED:-0} -eq 1 ]]; then
        printf 'Isolation : Docker container (%s) — no network, read-only filesystem,\n' "$SBX_IMAGE"
        printf '            all capabilities dropped, running as an unprivileged user.\n'
        printf '            The target was copied in read-only; nothing it does can reach\n'
        printf '            this machine or the network.\n'
        # THE CONTRACT IS PRINTED, NOT SUMMARISED. stage_record_exec's command line only
        # reaches the report for a stage that FAILED, so on every successful run the claim
        # above would be an assertion with no evidence under it — and the m6 checks would
        # have nothing to grep but revctf's own adjectives. These are the flags actually
        # passed, from the same sbx_wrap the run used.
        local -a _c=()
        sbx_wrap _c "$DYN_SBX_SCRATCH" "$DYN_TARGET" "revctf-$$-$tool" \
            "$(tier_ceiling_for_stage "$tool")"
        printf 'Contract  : %s\n' "${_c[*]}"
    else
        printf 'Isolation : NONE — the challenge binary ran directly on this machine,\n'
        printf '            with your network and your files reachable. You asked for this\n'
        printf '            with --no-sandbox; drop that flag to run it in a container\n'
        printf '            instead, or --skip-ltrace / --skip-strace to not run it at all.\n'
    fi
    if [[ ${DYN_SANDBOXED:-0} -eq 1 ]]; then
        # The orphan sweep signals a process GROUP, and under the sandbox there is none to
        # signal — saying "swept" here would describe a mechanism that did not run.
        printf 'Bounds    : killed after %ss; the container is then removed outright\n' "$2"
    else
        printf 'Bounds    : killed after %ss; orphaned processes swept afterwards\n' "$2"
    fi
    printf 'Arguments : none — the target is run with no argv and stdin closed\n'
    [[ ${DYN_COPIED:-0} -eq 1 ]] && \
        printf 'Note      : your file was not executable, so a runnable COPY was made and\n            traced. Your original file was not modified.\n'
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

    # ltrace on a STATICALLY LINKED binary is not a failure, it is a non-applicability.
    #
    # ltrace traces LIBRARY calls. A static binary has none, so ltrace exits 1 with
    # "Couldn't find .dynsym or .dynstr" -- which the stage then recorded as `failed`, and a
    # failed stage makes the whole run exit 2. On picoCTF's unpackme-upx that meant a scan
    # which unpacked the target, decompiled it and recovered the flag at high confidence
    # still exited 2, as though something had gone wrong. Nothing had.
    #
    # strace is unaffected and is the right tool here: syscalls exist either way, which is
    # exactly why v6 added it (deviation D2).
    #
    # The "(this one is ...)" wording is the shared marker for a format-based skip, so this
    # is also filtered out of WHAT TO TRY NEXT rather than listed as a gap.
    # shellcheck disable=SC2153  # RUN_TARGET is a global set by the entry script
    if [[ $tool == ltrace ]] && file -b -- "$RUN_TARGET" 2>/dev/null | grep -q 'statically linked'; then
        stage_skip "$name" "ltrace traces library calls (this one is a statically linked ELF, so it makes none — see strace instead)"
        return 1
    fi

    # --- Isolation (M6, deviation D13) --------------------------------------------
    #
    # The sandbox is ON by default. When it is unavailable the stage SKIPS; it never falls
    # back to the host. The reason names Docker as the cause AND --no-sandbox as the
    # deliberate override, because a skip the reader cannot act on is just a gap.
    DYN_SANDBOXED=0
    if [[ ${OPT[sandbox]:-1} -eq 1 ]]; then
        if ! sbx_available; then
            stage_skip "$name" \
                "the sandbox is unavailable, so the target was NOT executed: ${SBX_WHY}. Fix Docker, or pass --no-sandbox to accept running it unisolated on this machine"
            return 1
        fi
        DYN_SANDBOXED=1
    fi

    # A DOWNLOADED CHALLENGE IS MODE 644, AND THAT USED TO SKIP BOTH DYNAMIC STAGES.
    #
    # This is the single most common way revctf is used: download a binary, scan it. curl,
    # wget and every browser write it non-executable, so `ltrace` and `strace` both skipped
    # with "chmod +x it" on the very first run -- two of fourteen stages silently dropping
    # out of the default experience. Measured on a real picoCTF target; no corpus fixture
    # could show it, because build-test-corpus.sh chmods everything it creates.
    #
    # The fix is a copy, never a chmod of the user's file: "the user's original file is
    # never modified" (CLAUDE.md §2) is not negotiable for a convenience. The copy lives in
    # RUN_WORKDIR at 0700 and dies with the run.
    #
    # UNDER THE SANDBOX THE COPY IS UNCONDITIONAL, and for a different reason: the container
    # runs as `nobody`, a uid that does not exist on this host, so a 0700 file owned by the
    # user is unreadable inside it no matter what the original mode was. The sandbox copy is
    # 0555 and mounted `:ro`, so the target can be read and executed and not modified.
    # shellcheck disable=SC2153  # RUN_TARGET is a global set by the entry script
    DYN_TARGET="$RUN_TARGET"
    DYN_COPIED=0
    if [[ ${DYN_SANDBOXED} -eq 1 ]]; then
        DYN_SBX_SCRATCH="$(sbx_scratch "$RUN_WORKDIR")"
        if [[ -z $DYN_SBX_SCRATCH ]]; then
            stage_skip "$name" "the sandbox scratch directory could not be created under $RUN_WORKDIR"
            return 1
        fi
        DYN_TARGET="$RUN_WORKDIR/sbx-target"
        if ! cp -f -- "$RUN_TARGET" "$DYN_TARGET" 2>/dev/null; then
            stage_skip "$name" "a read-only copy of the target could not be made for the sandbox"
            return 1
        fi
        chmod 0555 -- "$DYN_TARGET" 2>/dev/null
        [[ -x $RUN_TARGET ]] || DYN_COPIED=1
    elif [[ ! -x $RUN_TARGET ]]; then
        DYN_TARGET="$RUN_WORKDIR/exec.$(basename -- "$RUN_TARGET")"
        if ! cp -f -- "$RUN_TARGET" "$DYN_TARGET" 2>/dev/null; then
            stage_skip "$name" "target is not executable and a runnable copy could not be made"
            return 1
        fi
        chmod 0700 -- "$DYN_TARGET" 2>/dev/null
        if [[ ! -x $DYN_TARGET ]]; then
            stage_skip "$name" "target is not executable and the copy could not be made executable (noexec filesystem?)"
            return 1
        fi
        DYN_COPIED=1
    fi

    # The paths the TRACER is given. Inside the container they are container paths; on the
    # host they are host paths. Keeping the two apart in named variables is what stops a
    # host path being handed to a container (which fails obscurely: the tracer reports
    # "no such file" about a path that plainly exists).
    if [[ ${DYN_SANDBOXED} -eq 1 ]]; then
        DYN_EXEC_ARG="/target"
        DYN_TRACE_ARG="/work/trace.$name"
        DYN_TRACE_HOST="$DYN_SBX_SCRATCH/trace.$name"
    else
        DYN_EXEC_ARG="$DYN_TARGET"
        DYN_TRACE_ARG="$(stage_out_path "$name").trace"
        DYN_TRACE_HOST="$DYN_TRACE_ARG"
    fi
    rm -f -- "$DYN_TRACE_HOST" 2>/dev/null
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

# The path the tracer actually runs, and whether it is a copy revctf made executable.
# shellcheck disable=SC2034  # read by lib/stage_ltrace.sh and lib/stage_strace.sh
declare -g DYN_TARGET=""
# shellcheck disable=SC2034
declare -g DYN_COPIED=0
# Whether this stage is running inside the container, and the paths that follow from it.
# DYN_EXEC_ARG / DYN_TRACE_ARG are what the TRACER is given (container paths under the
# sandbox, host paths without it); DYN_TRACE_HOST is where the trace lands on THIS machine,
# which is what dyn_run measures and dyn_compose reads.
# shellcheck disable=SC2034  # all four are read by the two stage files, separate from this one
declare -g DYN_SANDBOXED=0
# shellcheck disable=SC2034
declare -g DYN_EXEC_ARG=""
# shellcheck disable=SC2034
declare -g DYN_TRACE_ARG=""
declare -g DYN_TRACE_HOST=""
declare -g DYN_SBX_SCRATCH=""

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
    local rc=0 pgid="" cname=""
    local -a pre=()

    if [[ ${DYN_SANDBOXED:-0} -eq 1 ]]; then
        # A deterministic, run-scoped name. It is what sbx_teardown removes, and `docker run`
        # refuses a duplicate — which is the behaviour we want if two stages ever collide.
        cname="revctf-$$-$name"
        sbx_teardown "$cname"
        sbx_wrap pre "$DYN_SBX_SCRATCH" "$DYN_TARGET" "$cname" "$(tier_ceiling_for_stage "$name")"
    fi

    # shellcheck disable=SC2034  # read by st_run_bounded in lib/stage.sh, a separate file
    ST_OWN_SESSION=1
    st_run_bounded "$tmo" "$out" "$err" -- ${pre[@]+"${pre[@]}"} "$@" || rc=$?
    # shellcheck disable=SC2034  # same: cleared for the next stage, consumed cross-file
    ST_OWN_SESSION=0
    pgid="$ST_LAST_PGID"

    if [[ -n $cname ]]; then
        # UNCONDITIONAL, and that is the point. --rm covers a clean exit. It does not cover
        # `timeout` firing: that kills the docker CLIENT, and the container carries on
        # running the hostile target with nothing left watching it. There is no process group
        # to sweep either — ST_LAST_PGID is the client's, and the container is a child of
        # dockerd in another cgroup entirely. Removing it by name is the only teardown that
        # actually holds.
        sbx_teardown "$cname"
        DYN_SWEPT=0
    else
        DYN_SWEPT=$(dyn_sweep_orphans "$pgid")
    fi

    DYN_TRACE_BYTES="$(stat -c '%s' "$trace" 2>/dev/null || printf 0)"
    is_uint "$DYN_TRACE_BYTES" || DYN_TRACE_BYTES=0
    return "$rc"
}

# dyn_cmdline <tool> <timeout> <tracer-args> — the command line the report records.
#
# THE ISOLATION CONTRACT HAS TO BE VISIBLE IN THE REPORT, not merely applied. A user who is
# told "this ran in a container" and is shown nothing has been asked to take it on trust;
# the m6 harness section would be reduced to trusting it too. So the recorded line is the
# real one, docker flags and all, and both the reader and the check can see --network=none
# with their own eyes.
dyn_cmdline() {
    local tool="$1" tmo="$2" args="$3"
    if [[ ${DYN_SANDBOXED:-0} -eq 1 ]]; then
        local -a pre=()
        sbx_wrap pre "$DYN_SBX_SCRATCH" "$DYN_TARGET" "revctf-$$-$tool" \
            "$(tier_ceiling_for_stage "$tool")"
        printf 'setsid timeout -k 5 %s %s %s %s </dev/null' \
            "$tmo" "${pre[*]}" "$tool" "$args"
    else
        printf 'setsid timeout -k 5 %s %s %s </dev/null [NOT ISOLATED: --no-sandbox]' \
            "$tmo" "$tool" "$args"
    fi
    return 0
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
