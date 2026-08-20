#!/usr/bin/env bash
# lib/watchdog.sh — global RSS monitor; kills the job tree at 90% of detected RAM.
#
# Implemented in: M5.
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.
#
# WHY THIS EXISTS ALONGSIDE THE PER-STAGE CEILING
# st_run_bounded bounds ONE tool at a time against its tier ceiling. That is not the same
# guarantee as bounding the run: a ceiling only covers stages v6 §5 assigns a number to,
# `ulimit -v` cannot bound a JVM at all (see tier_stage_is_jvm), and from M7 several jobs
# run concurrently. The watchdog is the backstop that covers all of it — it measures what
# the whole revctf process tree actually resides in, which no per-process limit can see.
#
# WHAT IT DOES ON A BREACH
# It kills the job tree — every descendant of revctf — and leaves revctf itself alive. That
# is deliberate. Killing the whole run would throw away a report the user has already waited
# for; leaving revctf alive lets the breach be recorded as a stage failure with a real
# diagnostic, the remaining stages skipped, and the partial report written. v6 §7.3's "only
# the watchdog and an explicit abort stop a run outright" is honoured — no further stage
# runs — without discarding the work.
#
# It NEVER prompts (v5 §3.1). By the time RSS is at 90% the host is already in trouble and
# a prompt would sit unanswered while the OOM killer made the decision instead.

# --------------------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------------------
declare -g WATCHDOG_PID=""
declare -g WATCHDOG_MARKER=""
declare -g WATCHDOG_LIMIT_MB=0

# Poll interval, seconds. 2s is a compromise measured against the thing it is racing: a
# tool that allocates fast enough to cross 90% in under two seconds would also cross the
# kernel's own OOM threshold before any userspace poller could react, so a shorter interval
# buys nothing real and costs a `ps` per tick for the whole run.
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-2}"

# --------------------------------------------------------------------------------------
# watchdog_start <total-ram-mb> <percent> — begin monitoring. Safe to call with junk.
# --------------------------------------------------------------------------------------
# Returns 0 and monitors nothing when it cannot get a usable threshold: an undetectable RAM
# figure must not be a reason to refuse to scan.
watchdog_start() {
    local ram_mb="${1:-0}" pct="${2:-90}"

    WATCHDOG_PID=""
    WATCHDOG_MARKER=""
    WATCHDOG_LIMIT_MB=0

    # QA-1 rule: coerce before anything reaches arithmetic context. Under `set -u` a
    # non-numeric word in `-gt` is read as a variable name and EXITS THE SHELL, which the
    # stage boundary cannot catch. Both of these come from outside this file.
    is_uint "$ram_mb" || return 0
    is_uint "$pct"    || pct=90
    [[ $ram_mb -gt 0 && $pct -gt 0 && $pct -le 100 ]] || return 0

    WATCHDOG_LIMIT_MB=$(( ram_mb * pct / 100 ))
    [[ $WATCHDOG_LIMIT_MB -gt 0 ]] || return 0

    WATCHDOG_MARKER="$(mktemp "${TMPDIR:-/tmp}/revctf-watchdog.XXXXXX")" || {
        WATCHDOG_LIMIT_MB=0; return 0; }

    # The monitored root is revctf's own PID. `$$` inside the backgrounded subshell would
    # be the parent shell's PID in bash anyway, but capturing it explicitly makes the intent
    # readable and survives being moved.
    local root=$$
    _watchdog_loop "$root" "$WATCHDOG_LIMIT_MB" "$WATCHDOG_MARKER" &
    WATCHDOG_PID=$!
    return 0
}

# watchdog_stop — end monitoring and remove the marker.
watchdog_stop() {
    if [[ -n $WATCHDOG_PID ]]; then
        kill -TERM "$WATCHDOG_PID" 2>/dev/null
        wait "$WATCHDOG_PID" 2>/dev/null
        WATCHDOG_PID=""
    fi
    [[ -n $WATCHDOG_MARKER && -f $WATCHDOG_MARKER ]] && rm -f "$WATCHDOG_MARKER"
    WATCHDOG_MARKER=""
    return 0
}

# watchdog_tripped — true when the watchdog has fired. Cheap enough to call per stage.
watchdog_tripped() {
    [[ -n $WATCHDOG_MARKER && -s $WATCHDOG_MARKER ]]
}

# watchdog_reason — the one-line explanation written at the moment of the breach.
watchdog_reason() {
    if watchdog_tripped; then
        head -1 "$WATCHDOG_MARKER" 2>/dev/null
    fi
    return 0
}

# --------------------------------------------------------------------------------------
# Internals
# --------------------------------------------------------------------------------------
# _watchdog_loop <root-pid> <limit-mb> <marker> — the background poller.
_watchdog_loop() {
    local root="$1" limit_mb="$2" marker="$3"
    local total_mb

    while kill -0 "$root" 2>/dev/null; do
        sleep "$WATCHDOG_INTERVAL"
        total_mb="$(_watchdog_tree_rss_mb "$root")"
        is_uint "$total_mb" || continue
        [[ $total_mb -ge $limit_mb ]] || continue

        printf 'the run reached %sMB resident, at or above the %sMB watchdog limit (%s%% of detected RAM); the running tools were killed\n' \
            "$total_mb" "$limit_mb" "${TIER_WATCHDOG_PCT:-90}" > "$marker"
        _watchdog_kill_descendants "$root"
        return 0
    done
    return 0
}

# _watchdog_tree_rss_mb <root-pid> — summed RSS of the process tree, in MB.
#
# One `ps` per tick rather than a walk of /proc: ps reads the same data in one pass, and
# procps is already a hard dependency (tier_detect_ram_mb uses `free`). RSS is summed
# without correcting for shared pages, which over-counts a little — that is the safe
# direction for a limit whose job is to fire before the kernel's OOM killer does.
_watchdog_tree_rss_mb() {
    local root="$1"
    ps -eo pid=,ppid=,rss= 2>/dev/null | awk -v root="$root" '
        { pid[NR]=$1; ppid[NR]=$2; rss[NR]=$3; n=NR }
        END {
            intree[root]=1
            # Repeat until no new descendant is found. ps output is not topologically
            # ordered, so a single pass would miss a child listed before its parent.
            do {
                added=0
                for (i=1; i<=n; i++)
                    if (!intree[pid[i]] && intree[ppid[i]]) { intree[pid[i]]=1; added=1 }
            } while (added)
            total=0
            for (i=1; i<=n; i++) if (intree[pid[i]]) total += rss[i]
            printf "%d", total/1024
        }'
    return 0
}

# _watchdog_kill_descendants <root-pid> — kill the job tree, sparing the root and itself.
#
# The root is spared so revctf survives to record the breach and write the partial report.
# SIGKILL rather than SIGTERM: a process that is already at the memory ceiling may not get
# scheduled to run a handler, and this path exists precisely because the host is out of room
# to be polite in.
#
# TWO THINGS HERE ARE LOAD-BEARING, both found by testing rather than reading:
#
# 1. The poller must exclude ITSELF. It is a descendant of revctf, so a naive tree walk puts
#    it in its own kill list — observed killing itself partway through, which left the
#    processes later in the list ALIVE. A watchdog that reports a kill it did not finish is
#    worse than no watchdog. `$BASHPID` is the subshell's real PID (`$$` would be the
#    parent's), and the `ps`/`awk` children of this function are excluded with it.
# 2. The list is collected FULLY before the first kill. Reading it from a process
#    substitution while killing meant the pipeline feeding it could die mid-read.
_watchdog_kill_descendants() {
    local root="$1" self="$BASHPID" pid
    local -a victims=()

    mapfile -t victims < <(ps -eo pid=,ppid= 2>/dev/null | awk -v root="$root" '
        { pid[NR]=$1; ppid[NR]=$2; n=NR }
        END {
            intree[root]=1
            do {
                added=0
                for (i=1; i<=n; i++)
                    if (!intree[pid[i]] && intree[ppid[i]]) { intree[pid[i]]=1; added=1 }
            } while (added)
            for (i=1; i<=n; i++) if (intree[pid[i]] && pid[i] != root) print pid[i]
        }')

    for pid in ${victims[@]+"${victims[@]}"}; do
        [[ -z $pid || $pid == "$root" || $pid == "$self" ]] && continue
        # Skip our own descendants (the ps/awk above), so the poller cannot cut its own
        # legs off before the loop finishes.
        [[ $(_watchdog_ppid_of "$pid") == "$self" ]] && continue
        kill -KILL "$pid" 2>/dev/null
    done
    return 0
}

# _watchdog_ppid_of <pid> — parent PID, or empty. Read from /proc directly: this runs
# inside the kill loop, where forking another `ps` per victim would be absurd.
_watchdog_ppid_of() {
    local stat
    [[ -r /proc/$1/stat ]] || return 0
    # Field 4 is ppid, but field 2 (comm) can contain spaces and parentheses, so the line
    # is cut at the LAST ')' before splitting.
    stat="$(< "/proc/$1/stat")"
    stat="${stat##*) }"
    printf '%s' "$(( $(printf '%s' "$stat" | awk '{print $2}') ))" 2>/dev/null
    return 0
}
