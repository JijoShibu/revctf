#!/usr/bin/env bash
# tools/measure-host.sh — capture the numbers M5 is designed around, on THIS machine.
#
# WHY
# Every performance and memory figure in the design so far was measured in a cloud
# sandbox: 2 CPUs, 8GB, no swap, systemd not booted. M5 turns measurements into design
# constants — tier boundaries, the Phase-2 ceiling, the watchdog threshold — so it must be
# built on numbers from the machine it will actually run on.
#
# One figure in particular is load-bearing: FLOSS peaked at ~1.46GB on a 220MB target,
# which exceeds Tier A's 1024M ceiling and is roughly 3x Tier C's. That measurement
# DISPROVES v6 §5's assumption that Phase 2 can inherit Ghidra's ceiling. Re-take it here
# before deciding what replaces it.
#
#   ./tools/measure-host.sh [output-file]
#
# Writes a plain-text report (default: host-measurements-<host>-<date>.txt) and prints it.
# Runs real scans, so it takes a few minutes and needs the test corpus built.

set -uo pipefail   # never `set -e` — see docs/CLAUDE.md §2

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RC="$ROOT/revctf"
CORPUS="$ROOT/test-corpus"
OUT="${1:-$ROOT/host-measurements-$(hostname -s 2>/dev/null || printf host)-$(date +%Y%m%d).txt}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

hdr() { printf '\n== %s ==\n' "$1"; }

# peak_rss <label> <command...> — run it, report wall time and peak RSS in MB.
#
# Two ways to get a TRUE peak (not a sampled approximation, which for a spiky consumer like
# FLOSS is worse than no number at all):
#
#   1. /usr/bin/time -v            — GNU time, the obvious one
#   2. python3 + getrusage()       — RUSAGE_CHILDREN.ru_maxrss, the same kernel counter
#                                    GNU time reads, via a dependency that is already
#                                    mandatory for revctf
#
# The python3 path exists because of a measured failure of this very script: `/usr/bin/time`
# is NOT part of a base Kali install (it is the separate `time` package; the shell's `time`
# keyword is not a substitute and reports no RSS). This script silently took the
# wall-clock-only branch, printed no peak figure, and the FLOSS measurement that M5's
# Phase-2 ceiling has to be derived from simply never appeared in the output — the report
# looked complete. A measurement tool that degrades quietly is the same defect class as a
# feature documented but absent, so it now falls back rather than skipping.
peak_rss() {
    local label="$1"; shift
    local tf="$WORK/time.$$" rss="" secs="" t0=$SECONDS

    if command -v /usr/bin/time >/dev/null 2>&1; then
        /usr/bin/time -v -o "$tf" "$@" >/dev/null 2>&1
        rss="$(awk -F': ' '/Maximum resident set size/{print int($2/1024)}' "$tf" 2>/dev/null)"
        secs="$(awk -F': ' '/Elapsed \(wall clock\)/{print $2}' "$tf" 2>/dev/null)"
        printf '  %-28s peak %sMB, wall %s  [GNU time]\n' "$label" "${rss:-?}" "${secs:-?}"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        # ru_maxrss is in KB on Linux and covers the whole waited-for child tree.
        rss="$(python3 -c '
import resource, subprocess, sys
before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
after = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
print(int(max(after, before) / 1024))
' "$@" 2>/dev/null)"
        printf '  %-28s peak %sMB, wall %ss  [getrusage]\n' \
            "$label" "${rss:-?}" "$(( SECONDS - t0 ))"
        return 0
    fi

    "$@" >/dev/null 2>&1
    printf '  %-28s wall %ss (no peak: install "time" or python3)\n' "$label" "$(( SECONDS - t0 ))"
    return 0
}

main() {
    {
    printf 'revctf host measurements\n'
    printf 'date        : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'host        : %s\n' "$(hostname 2>/dev/null || printf unknown)"
    printf 'kernel      : %s\n' "$(uname -sr 2>/dev/null)"
    local distro="unknown"
    # shellcheck source=/dev/null disable=SC1091
    [[ -r /etc/os-release ]] && { . /etc/os-release 2>/dev/null; distro="${PRETTY_NAME:-unknown}"; }
    printf 'distro      : %s\n' "$distro"
    printf 'revctf      : %s\n' "$(git -C "$ROOT" describe --tags --always 2>/dev/null || printf unknown)"

    hdr "Hardware — what tier resolution reads"
    printf '  RAM total   : %s MB\n' "$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
    printf '  RAM avail   : %s MB\n' "$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')"
    printf '  Swap        : %s MB\n' "$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')"
    printf '  CPUs        : %s\n' "$(nproc 2>/dev/null)"
    printf '  Governor    : %s\n' \
        "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || printf n/a)"
    printf '  Disk free   : %s\n' "$(df -h "$ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
    printf '  WSL         : %s\n' \
        "$(grep -qi microsoft /proc/version 2>/dev/null && printf yes || printf no)"

    hdr "Resource isolation — M5's primary mechanism"
    # This is the one that decides whether M5 can meet its Definition of Done at all.
    # In the build sandbox systemd was never booted, so systemd-run has NEVER executed
    # and every run silently used the ulimit -v fallback.
    if [[ -d /run/systemd/system ]]; then
        printf '  systemd booted        : yes\n'
    else
        printf '  systemd booted        : NO (PID 1 = %s)\n' "$(ps -p1 -o comm= 2>/dev/null)"
    fi
    printf '  systemd-run present   : %s\n' \
        "$(command -v systemd-run >/dev/null 2>&1 && printf yes || printf no)"
    if command -v systemd-run >/dev/null 2>&1; then
        if timeout 10 systemd-run --user --scope --quiet true >/dev/null 2>&1; then
            printf '  systemd-run --user    : WORKS (RSS bounding available)\n'
        elif timeout 10 systemd-run --scope --quiet true >/dev/null 2>&1; then
            printf '  systemd-run --system  : WORKS (RSS bounding available)\n'
        else
            printf '  systemd-run usable    : NO — falls back to ulimit -v (bounds VSZ, not RSS)\n'
            printf '                          On WSL, add [boot] systemd=true to /etc/wsl.conf\n'
            printf '                          then run wsl --shutdown from PowerShell.\n'
        fi
    fi
    printf '  cgroup v2             : %s\n' \
        "$([[ -f /sys/fs/cgroup/cgroup.controllers ]] && printf yes || printf no)"
    printf '  docker daemon         : %s\n' \
        "$(docker info >/dev/null 2>&1 && printf 'running (M6 unblocked)' || printf 'not running')"

    hdr "Toolchain versions"
    # `--version` is not universal, and assuming it produced a silently blank column here.
    # binwalk 2.4.3 treats it as a FILENAME ("Cannot open file --version") and radare2
    # prints its usage banner, so both showed up empty or wrong in the measurement this
    # milestone was supposed to be derived from. lib/preflight.sh already knew this — it
    # falls back `--version` -> `-h` -> the python module — and the knowledge simply never
    # reached this script. Same finding, two places; see QA review #2 §7 rule 4.
    local t v
    for t in file strings binwalk ltrace strace radare2 checksec objdump upx floss \
             analyzeHeadless python3 java; do
        if ! command -v "$t" >/dev/null 2>&1; then
            printf '  %-16s ABSENT\n' "$t"
            continue
        fi
        case "$t" in
            binwalk) v=$(binwalk -h 2>&1 | grep -iEm1 'binwalk +v?[0-9]') ;;
            radare2) v=$(radare2 -v 2>/dev/null | head -1) ;;
            java)    v=$(java -version 2>&1 | head -1) ;;   # java prints to stderr
            # analyzeHeadless prints its usage banner for --version. The real version lives
            # in the install's application.properties; follow the symlink install.sh makes.
            analyzeHeadless)
                     v=$(sed -n 's/^application\.version=/Ghidra /p' \
                           "$(dirname -- "$(dirname -- "$(readlink -f -- "$(command -v analyzeHeadless)")")")/Ghidra/application.properties" \
                           2>/dev/null | head -1) ;;
            *)       v=$("$t" --version 2>/dev/null | head -1) ;;
        esac
        # Anything that still came back empty or as an error is reported as unknown rather
        # than as a blank field that reads like a successful measurement.
        [[ -z $v || $v == *"Error"* ]] && v="(version not reported by this tool)"
        printf '  %-16s %s\n' "$t" "$(printf '%s' "$v" | cut -c1-60)"
    done

    if [[ ! -f $CORPUS/crackme ]]; then
        hdr "Timings"
        printf '  SKIPPED — run ./tools/build-test-corpus.sh first.\n'
        return 0
    fi

    hdr "Timings — small realistic target (crackme, all stages)"
    peak_rss "full scan" "$RC" scan "$CORPUS/crackme" --output "$WORK/o1"
    peak_rss "full scan, --skip-ghidra" "$RC" scan "$CORPUS/crackme" --skip-ghidra --output "$WORK/o2"

    if [[ -f $CORPUS/large_blob.bin ]]; then
        hdr "Timings — 220MB stress blob"
        printf '  Sandbox baseline for comparison: total ~78s, binwalk ~74s, strings ~2s.\n'
        peak_rss "full scan, --skip-ghidra" \
            "$RC" scan "$CORPUS/large_blob.bin" --skip-ghidra --output "$WORK/o3"
        printf '\n  Per-stage from that run:\n'
        sed -n '/^STAGE /,/^$/p' "$WORK/o3/report.txt" 2>/dev/null | sed 's/^/    /'

        hdr "FLOSS peak RSS — the number that decides the Phase-2 ceiling"
        printf '  Sandbox measured ~1.46GB, which exceeds Tier A 1024M and is ~3x Tier C.\n'
        printf '  FLOSS_MAX_MB (default 64) normally gates this; lifted here to measure.\n'
        if command -v floss >/dev/null 2>&1; then
            peak_rss "floss on the 220MB blob" \
                env FLOSS_MAX_MB=999999 "$RC" scan "$CORPUS/large_blob.bin" \
                --skip-ghidra --output "$WORK/o4"
        else
            printf '  floss is not installed — cannot measure.\n'
        fi
    else
        hdr "220MB stress blob"
        printf '  Absent. Rebuild the corpus without REVCTF_TEST_FAST to include it.\n'
    fi

    hdr "Tier that would be selected here"
    "$RC" scan "$CORPUS/crackme" --dry-run 2>/dev/null | sed -n '/^Hardware/,/^Stages that/p' \
        | sed 's/^/  /'

    hdr "What to do with these numbers"
    cat <<'TXT'
  1. Compare FLOSS peak against the tier Ghidra MAXMEM values (1024M/768M/512M).
     If it still exceeds them, v6 §5's Phase-2 derivation stays disproved and M5 must
     size Phase 2 independently — or keep FLOSS_MAX_MB as a permanent size gate.
  2. If systemd-run is unusable, fix that BEFORE writing M5. Its Definition of Done
     requires the systemd-run path to work, and it has never once executed in this
     project.
  3. Compare RAM/CPU against the tier boundaries (3.8GB / 2.5GB). v4 §10 flags them as
     unmeasured estimates; this is the run that either confirms or moves them.
  4. Paste this file into docs/implementation-notes.md under the M5 section.
TXT
    } | tee "$OUT"

    printf '\nWritten to %s\n' "$OUT"
}

main "$@"
