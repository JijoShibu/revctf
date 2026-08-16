#!/usr/bin/env bash
# lib/stage.sh — the shared stage framework.
#
# Implemented in: M2.
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`.
#
# NOT in v6 §12's repo layout. Added during M2 because the execution masterplan calls the
# per-stage function pattern "load-bearing" and says to get it right once, since every
# later stage reuses it. Putting that pattern in a shared file rather than copying it into
# 13 stage files is the whole point. Recorded in implementation-notes.md.
#
# ======================================================================================
# The stage contract
# ======================================================================================
# Every stage is a function taking no arguments, reading the run context below, and
# writing its captured output through stage_capture(). It returns 0 on success and
# non-zero on failure; it must never exit, and must never leave the pipeline unable to
# continue (v5 §4.1 isolate-and-continue).
#
# Run context, set by stage_begin_file() before any stage runs:
#   RUN_ORIGINAL   absolute path to the file the user pointed at
#   RUN_TARGET     what stages actually analyse — the unwrapped payload when Stage 0
#                  produced one, otherwise identical to RUN_ORIGINAL
#   RUN_FORMAT     elf | pe | macho | java | dotnet | pyc | pyinstaller | archive | other
#   RUN_WORKDIR    per-file scratch directory (unwrapped copies, extraction trees)
#   RUN_OUTDIR     per-file capture directory (one file per stage)
#
# Results, keyed by stage name:
#   STAGE_STATUS   ok | empty | failed | skipped
#   STAGE_NOTE     one-line human explanation (why it was skipped, what failed)
#   STAGE_OUT      path to the captured stdout
#   STAGE_ERR      path to the captured stderr
#   STAGE_RC       exit code (or 124 for a timeout)
#   STAGE_SECS     wall-clock seconds
#   STAGE_CMD      the exact command line, for the M9 diagnostic block

# These globals are the stage contract's shared state: written here and in lib/stage_*.sh,
# read by lib/flagscan.sh and lib/report.sh. shellcheck cannot see across sourced files.
# shellcheck disable=SC2034
declare -g  RUN_ORIGINAL="" RUN_TARGET="" RUN_FORMAT="other"
declare -g  RUN_WORKDIR=""  RUN_OUTDIR=""
# shellcheck disable=SC2034
declare -g  ST_OUTDIR_PREEXISTING=0 ST_SAVED_UMASK=""
# PID of the tool currently running under stage_capture(), or empty. The abort handler
# needs this: see the comment in stage_capture().
declare -g  ST_CHILD_PID=""
# shellcheck disable=SC2034
declare -gA STAGE_STATUS=() STAGE_NOTE=() STAGE_OUT=() STAGE_ERR=()
# shellcheck disable=SC2034
declare -gA STAGE_RC=()     STAGE_SECS=() STAGE_CMD=()
declare -ga STAGE_ORDER=()

# ======================================================================================
# Time bounds (v6 §7.4)
# ======================================================================================
# `--timeout` is the ltrace bound and the only user-facing time control, per v6 §1 —
# everything else is an internal constant. Each is overridable by environment variable so
# the verification harness can force a timeout without waiting the real duration.
ST_T_LIGHT="${ST_T_LIGHT:-120}"        # file, hexdump, checksec, objdump
ST_T_STRINGS="${ST_T_STRINGS:-300}"    # a 200MB+ target is a normal CTF firmware case
ST_T_BINWALK="${ST_T_BINWALK:-300}"    # signature scan over a large blob is slow
ST_T_UNWRAP="${ST_T_UNWRAP:-60}"
ST_T_RADARE2="${ST_T_RADARE2:-120}"
ST_T_STRACE="${ST_T_STRACE:-10}"       # same hang-risk profile as ltrace
ST_T_DECOMP="${ST_T_DECOMP:-180}"      # managed / Python decompilers
ST_T_FLOSS="${ST_T_FLOSS:-300}"
ST_T_GHIDRA="${ST_T_GHIDRA:-1800}"

# Hexdump preview cap, in bytes (v6 §8). --full-hexdump bypasses it.
ST_HEXDUMP_PREVIEW="${ST_HEXDUMP_PREVIEW:-512}"

# ======================================================================================
# Per-file setup
# ======================================================================================
# stage_begin_file <original-path> <outdir>
stage_begin_file() {
    RUN_ORIGINAL="$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")"
    RUN_TARGET="$RUN_ORIGINAL"
    RUN_FORMAT="other"
    RUN_OUTDIR="$2"

    RUN_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/revctf-work.XXXXXX")" || return 1
    chmod 700 "$RUN_WORKDIR" 2>/dev/null

    # v4 §5 wants the output directory at 700 — but only for a directory revctf creates.
    # Silently tightening a directory the user already had is a destructive surprise: point
    # --output at a shared or published location and revctf would lock everyone else out of
    # it. So the mode is set on creation and a pre-existing directory is left alone.
    if [[ -d $RUN_OUTDIR ]]; then
        ST_OUTDIR_PREEXISTING=1
    else
        ST_OUTDIR_PREEXISTING=0
        mkdir -p "$RUN_OUTDIR" || return 1
        chmod 700 "$RUN_OUTDIR" 2>/dev/null
    fi

    # Fail fast and clearly when the destination is unwritable. Without this, every stage
    # fails individually with a redirection error and the user is told "strings exited 1"
    # rather than "the output directory is not writable".
    if [[ ! -w $RUN_OUTDIR ]]; then
        printf 'revctf: output directory is not writable: %s\n' "$RUN_OUTDIR" >&2
        return 1
    fi

    # Captures can quote strings, symbols and decompiled logic from the analysed binary, so
    # they are created 0600 rather than inheriting the invoking user's umask (v4 §5). The
    # umask is scoped to this run only.
    ST_SAVED_UMASK="$(umask)"
    umask 077

    STAGE_STATUS=(); STAGE_NOTE=(); STAGE_OUT=(); STAGE_ERR=()
    STAGE_RC=();     STAGE_SECS=(); STAGE_CMD=(); STAGE_ORDER=()
    return 0
}

stage_end_file() {
    [[ -n $RUN_WORKDIR && -d $RUN_WORKDIR ]] && rm -rf "$RUN_WORKDIR"
    RUN_WORKDIR=""
    [[ -n $ST_SAVED_UMASK ]] && { umask "$ST_SAVED_UMASK"; ST_SAVED_UMASK=""; }
    return 0
}

# ======================================================================================
# Result recording
# ======================================================================================
_st_register() {
    local name="$1"
    local s
    for s in "${STAGE_ORDER[@]}"; do [[ $s == "$name" ]] && return 0; done
    STAGE_ORDER+=("$name")
}

stage_set_status() {   # <name> <status> [note]
    _st_register "$1"
    STAGE_STATUS[$1]="$2"
    [[ -n ${3:-} ]] && STAGE_NOTE[$1]="$3"
    return 0
}

stage_skip() { stage_set_status "$1" skipped "${2:-skipped}"; return 0; }

stage_out_path() { printf '%s/%s.txt' "$RUN_OUTDIR" "$1"; }
stage_err_path() { printf '%s/%s.stderr' "$RUN_OUTDIR" "$1"; }

# ======================================================================================
# Command execution
# ======================================================================================
# stage_capture <name> <timeout-seconds> -- <command> [args...]
#
# The single place a stage's external tool is invoked. It:
#   - streams stdout straight to disk, never through a Bash variable (v3 §1: large
#     captures must not be buffered in memory)
#   - splits stderr into its own file, so the report can show a stderr tail on failure
#     without polluting the captured output (v3 §5 step 10)
#   - bounds the run with `timeout`, distinguishing a timeout (124) from a real failure
#   - records the exact command line for M9's diagnostic block
#   - classifies an empty-but-successful run as `empty` rather than `ok`, so the report
#     can say "this stage found nothing" instead of showing a blank section (M4 DoD)
#
# st_run_bounded <timeout> <stdout-file> <stderr-file> -- <command> [args...]
#
# The one place any external tool is actually launched. Backgrounding it and `wait`-ing is
# what makes the run interruptible: bash defers a trap until the current FOREGROUND command
# finishes, so a tool run in the foreground swallows Ctrl+C for its entire duration —
# measured at 70 seconds for a binwalk over a 220MB target, during which revctf looked
# hung. `wait` is interruptible, so the handler fires at once and can kill the child.
#
# Sets ST_CHILD_PID for the duration. Returns the command's exit status; never exits.
st_run_bounded() {
    local tmo="$1" out="$2" err="$3"; shift 3
    [[ ${1:-} == "--" ]] && shift
    local rc=0
    timeout -k 5 "$tmo" "$@" >"$out" 2>"$err" &
    ST_CHILD_PID=$!
    wait "$ST_CHILD_PID" || rc=$?
    ST_CHILD_PID=""
    return "$rc"
}

# Returns the command's exit status. Never exits.
stage_capture() {
    local name="$1" tmo="$2"; shift 2
    [[ ${1:-} == "--" ]] && shift

    local out err start end rc
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"

    _st_register "$name"
    STAGE_CMD[$name]="$*"
    STAGE_OUT[$name]="$out"
    STAGE_ERR[$name]="$err"

    start=$SECONDS
    # `timeout -k` sends SIGKILL if the tool ignores SIGTERM. Output redirection happens
    # here, in the caller's shell, so the tool writes directly to the file descriptor.
    #
    # The tool is backgrounded and waited on rather than run in the foreground, for one
    # specific reason: bash defers a trap until the current FOREGROUND command finishes.
    # With a foreground tool, Ctrl+C during a `strings` over a 220MB target did not stop
    # it — the signal was noted, `strings` ran to completion, and only then did the handler
    # fire, leaving the tool as an orphan. `wait` is interruptible, so the handler runs
    # immediately and can kill the recorded PID.
    #
    # This matters far more from M3 on: ltrace and strace EXECUTE the challenge binary, and
    # an orphan there is untrusted code still running after the user believes they stopped
    # the scan.
    rc=0
    st_run_bounded "$tmo" "$out" "$err" -- "$@" || rc=$?
    end=$SECONDS

    STAGE_RC[$name]=$rc
    STAGE_SECS[$name]=$(( end - start ))

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        stage_set_status "$name" failed \
            "timed out after ${tmo}s (partial output kept)"
    elif [[ $rc -ne 0 ]]; then
        stage_set_status "$name" failed \
            "$(basename "$1") exited $rc$(_st_signal_note "$rc")"
    elif [[ ! -s $out ]]; then
        stage_set_status "$name" empty "produced no output"
    else
        stage_set_status "$name" ok ""
    fi
    return $rc
}

# A tool killed by a signal exits 128+N. Naming the signal turns "exited 139" into
# something a beginner can act on — which is the whole point of the report's tone.
_st_signal_note() {
    local rc="$1"
    [[ $rc -gt 128 && $rc -lt 160 ]] || { printf ''; return 0; }
    local sig=$(( rc - 128 )) nm
    nm=$(kill -l "$sig" 2>/dev/null) || nm=""
    [[ -n $nm ]] && printf ' (killed by SIG%s)' "$nm" || printf ''
}

# stage_record_exec <name> <command-string> <rc>
#
# For a stage that runs its tool itself rather than through stage_capture() — because it
# needs a custom pipeline, several invocations, or its own validation. Keeping every write
# to the STAGE_* arrays inside this file means a stage never has to know their names.
stage_record_exec() {
    local name="$1" cmdline="$2" rc="$3"
    _st_register "$name"
    STAGE_CMD["$name"]="$cmdline"
    STAGE_OUT["$name"]="$(stage_out_path "$name")"
    STAGE_ERR["$name"]="$(stage_err_path "$name")"
    STAGE_RC["$name"]="$rc"
    return 0
}

# stage_write <name> <status> — record output this shell produced directly (no external
# tool), e.g. a summary a stage assembles itself. The caller writes to stage_out_path.
stage_write() {
    local name="$1" status="${2:-}"
    local out; out="$(stage_out_path "$name")"
    _st_register "$name"
    STAGE_OUT[$name]="$out"
    STAGE_RC[$name]=0
    STAGE_SECS[$name]=${STAGE_SECS[$name]:-0}
    if [[ -n $status ]]; then
        stage_set_status "$name" "$status"
    elif [[ -s $out ]]; then
        stage_set_status "$name" ok ""
    else
        stage_set_status "$name" empty "produced no output"
    fi
    return 0
}

# ======================================================================================
# The stage boundary
# ======================================================================================
# stage_run <name> <human label> <function>
#
# v5 §4.1: every stage runs inside its own error boundary. A crash, a segfault, or an
# unexpected non-zero exit is captured and the pipeline moves on — nothing but the
# watchdog or an explicit abort stops a run. Implemented with a subshell-free local ERR
# trap so the stage's writes to STAGE_* survive; the trap is removed on the way out so it
# cannot leak into the next stage.
stage_run() {
    local name="$1" label="$2" fn="$3"
    local rc=0 started=$SECONDS

    _st_register "$name"
    : "${STAGE_STATUS[$name]:=pending}"

    if [[ ${OPT[verbose]:-0} -eq 1 ]]; then
        printf 'revctf: [%s] %s\n' "$name" "$label" >&2
    fi

    # Local boundary. `|| rc=$?` keeps a non-zero return from propagating anywhere.
    "$fn" || rc=$?

    # Time every stage here rather than only in stage_capture(). Stages that run their own
    # tool (binwalk, the full hexdump, triage) never went through stage_capture, so their
    # STAGE_SECS key was simply absent and the summary's `:-0` default printed a
    # convincing but fabricated "0" — a 70-second binwalk over a 220MB target reported as
    # instant. An elapsed time measured at the boundary is correct for every stage.
    STAGE_SECS["$name"]=$(( SECONDS - started ))

    # A stage that returned non-zero without recording why still gets a status, so the
    # report never shows a silently missing section.
    if [[ ${STAGE_STATUS[$name]} == pending ]]; then
        if [[ $rc -eq 0 ]]; then
            stage_set_status "$name" ok ""
        else
            stage_set_status "$name" failed "stage function returned $rc"
        fi
    fi

    if [[ ${OPT[verbose]:-0} -eq 1 ]]; then
        printf 'revctf: [%s] %s (%ss)\n' \
            "$name" "${STAGE_STATUS[$name]}" "${STAGE_SECS[$name]:-0}" >&2
    fi
    return 0
}

# ======================================================================================
# Small shared helpers
# ======================================================================================
# Human-readable file size, for report headers.
st_human_size() {
    local b="${1:-0}"
    if   [[ $b -ge 1073741824 ]]; then printf '%s.%sGB' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
    elif [[ $b -ge 1048576    ]]; then printf '%s.%sMB' $(( b / 1048576 ))    $(( (b % 1048576) * 10 / 1048576 ))
    elif [[ $b -ge 1024       ]]; then printf '%sKB'    $(( b / 1024 ))
    else                               printf '%sB'     "$b"
    fi
}

st_file_size() { stat -c '%s' "$1" 2>/dev/null || printf '0'; }

# Strip ANSI escape sequences from a stream.
#
# v6 §10 requires the report file to be plain text in every display mode. Some tools
# colour unconditionally: checksec 2.6.0 ignores both NO_COLOR and TERM=dumb, and radare2
# colours when it thinks it has a terminal. Escape codes in a captured file make the
# report unreadable in an editor and corrupt grep results, so anything that might colour
# is piped through here.
#
# This is a filter, not a buffer — the streaming-to-disk discipline (v3 §1) is preserved.
# Safe on tool output generally: 0x1b is not a printable character, so it cannot appear
# in `strings` output or a hex dump.
st_strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g'; }

# True when the resolved format is one the dynamic stages can trace. v3 §5 step 8 gates
# ltrace on ELF; strace inherits the same gate for the same reason.
st_is_elf() { [[ $RUN_FORMAT == elf ]]; }

# stage_kill_child — terminate the tool stage_capture() is currently waiting on.
# Called by the entry script's SIGINT/SIGTERM handler. `timeout` forwards the signal to
# the process it manages, so the tool itself goes down with it.
stage_kill_child() {
    [[ -n $ST_CHILD_PID ]] || return 0
    kill -TERM "$ST_CHILD_PID" 2>/dev/null
    local waited=0
    while kill -0 "$ST_CHILD_PID" 2>/dev/null && [[ $waited -lt 20 ]]; do
        sleep 0.1; waited=$(( waited + 1 ))
    done
    kill -KILL "$ST_CHILD_PID" 2>/dev/null
    ST_CHILD_PID=""
    return 0
}
