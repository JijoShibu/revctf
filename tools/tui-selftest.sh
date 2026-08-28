#!/usr/bin/env bash
# tools/tui-selftest.sh — interactive checks the automated harness cannot make.
#
# WHY THIS EXISTS
# Everything through M4 was built in a cloud container with no controlling terminal.
# `script(1)` can fake a pty well enough to assert that escape sequences are emitted, but
# it cannot tell you whether the table LOOKS right: whether a resize corrupts the redraw,
# whether Ctrl+C leaves the cursor hidden, whether a narrow window wraps. Those need a
# human with a real terminal, which is exactly what the harness has never had.
#
# Run this once on a real Kali/WSL terminal before trusting the M4 display layer.
#
#   ./tools/tui-selftest.sh [target]
#
# It never modifies the repo and writes only under a temporary directory.

set -uo pipefail   # never `set -e` — see docs/CLAUDE.md §2

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RC="$ROOT/revctf"
TARGET="${1:-$ROOT/test-corpus/crackme}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }
askq() {
    local q="$1" a
    read -r -p "    $q [y/n/s] " a
    case "${a,,}" in
        y) printf '    PASS\n'; pass=$((pass+1)) ;;
        s) printf '    SKIPPED\n' ;;
        *) printf '    FAIL\n'; fail=$((fail+1)) ;;
    esac
}

if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'tui-selftest: this must be run from a real terminal, not a pipe or CI job.\n' >&2
    exit 1
fi
if [[ ! -f $TARGET ]]; then
    printf 'tui-selftest: no target at %s\n' "$TARGET" >&2
    printf 'Run ./tools/build-test-corpus.sh, or pass a binary as the first argument.\n' >&2
    exit 1
fi

bold "revctf TUI self-test — target: $TARGET"
cat <<'TXT'

Six checks. Each runs a scan, then asks one question. Answer y, n, or s to skip.
Nothing here is destructive; captures go to a temporary directory.
TXT

step 1 "Live table — watch the stage rows update in place"
printf '    Press Enter to start.\n'; read -r _
"$RC" scan "$TARGET" --skip-ghidra --summary-only --output "$WORK/t1" >/dev/null
askq "Did a single table update in place, rather than scrolling a new copy per stage?"

step 2 "Resize during a run — THE check the harness cannot make"
cat <<'TXT'
    A wrapped row occupies two terminal lines, so the cursor rewind then lands in
    the middle of the table and corrupts it. revctf traps SIGWINCH and re-measures.
    While this runs, drag the window narrower and wider a few times.
TXT
printf '    Press Enter to start.\n'; read -r _
"$RC" scan "$TARGET" --output "$WORK/t2" >/dev/null
askq "Did the table stay intact through the resizes (no duplicated or torn rows)?"

step 3 "Ctrl+C — abort latency and terminal state"
cat <<'TXT'
    Press Ctrl+C roughly two seconds in. Expect: a cleanup line within about a
    second, exit status 130, a usable prompt, and a visible cursor.
TXT
printf '    Press Enter to start.\n'; read -r _
"$RC" scan "$TARGET" --output "$WORK/t3" >/dev/null
rc=$?
printf '    exit status: %d (expected 130)\n' "$rc"
askq "Did it stop promptly and leave the terminal usable with a visible cursor?"

step 4 "Narrow terminal — truncation, not wrapping"
printf '    Resize the window to about 50 columns, then press Enter.\n'; read -r _
"$RC" scan "$TARGET" --skip-ghidra --summary-only --output "$WORK/t4" >/dev/null
askq "Were long notes cut off at the right edge rather than wrapping onto a second line?"

step 5 "Redirected stdout — the report must stay clean"
"$RC" scan "$TARGET" --skip-ghidra --summary-only --output "$WORK/t5" > "$WORK/r.txt"
printf '    Progress above went to stderr; the report went to the file.\n'
if grep -q "$(printf '\033')" "$WORK/r.txt"; then
    printf '    AUTOMATIC FAIL: an escape sequence reached the report file.\n'
    fail=$((fail+1))
else
    printf '    AUTOMATIC PASS: no escape sequences in the report file.\n'
    pass=$((pass+1))
fi
askq "Did progress still appear on screen while the report went to the file?"

step 6 "Readability — the point of the whole tool"
"$RC" scan "$TARGET" --skip-ghidra --output "$WORK/t6" | head -40
askq "Could someone new to reverse engineering tell what was found and what to do next?"

printf '\n'
bold "$pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
    printf 'Report failures with the terminal emulator, its size, and the TERM value.\n'
    exit 1
fi
exit 0
