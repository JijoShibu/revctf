#!/usr/bin/env bash
# lib/tui.sh — progress display: live stage table, line mode, or heartbeat.
#
# Implemented in: M4.
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`.
#
# TWO RULES GOVERN THIS FILE
#
# 1. ALL progress output goes to STDERR. The report is plain text on stdout in every
#    display mode (v6 §10), so `revctf scan x > report.txt` must yield a clean file while
#    progress still reaches the user's terminal. Nothing here may write to stdout.
# 2. It must degrade, never fail. This is the highest-defect-density component in the
#    tool — redraw, resize and signal handling in Bash — so every mode falls back to the
#    one below it, and the whole layer is bypassable with --no-tui.
#
# ======================================================================================
# THIS FILE IS FROZEN
# ======================================================================================
# Decided after QA review #2. It works, it is isolated behind --no-tui, and it is the
# highest-defect-density component in the tool — cursor arithmetic, SIGWINCH, width
# measurement and truncation, in Bash. It is also the only part of revctf that NO
# automated check can verify: `script(1)` proves the right escape sequences are emitted
# and nothing more, which is why tools/tui-selftest.sh exists and has to be run by a human.
#
# Against that cost, the in-place table adds polish to the fifteen seconds before the
# report — the part nobody keeps. The line and heartbeat modes already deliver the actual
# user value: which stage is running, and how long it has taken.
#
# THE RULES
#   * Bug fixes only. No new features, no new modes, no colour, no progress bars.
#   * The harness pins this file's line count. Growth fails the build, so adding to it is
#     a deliberate decision someone has to make on purpose rather than drift into.
#   * DELETION TRIGGER: if this file ever needs a second dedicated debugging session,
#     delete it and default to line mode. That removes ~190 lines and one whole class of
#     platform-specific risk (terminal emulators, TERM values, resize semantics, locales).
#     Deleting it costs: the in-place table, and nothing else. tui_stage_start /
#     tui_stage_end / tui_finish / tui_note keep their signatures in line mode, so the
#     entry script would not change at all — remove _tui_redraw, _tui_measure, _tui_glyph
#     and the WINCH trap, and force TUI_MODE=line in tui_init.
#
# Modes, chosen once at tui_init:
#   tui        stdout AND stderr are terminals, --no-tui not given: a table redrawn in place
#   line       a terminal, but --no-tui: one line per stage transition
#   heartbeat  stdout is redirected: a periodic progress line, no cursor control at all

declare -g  TUI_MODE="line"
declare -g  TUI_ROWS=0          # rows currently drawn, for the redraw cursor rewind
declare -g  TUI_ACTIVE=""       # stage currently running
declare -g  TUI_LABEL=""
declare -g  TUI_START=0
declare -g  TUI_LAST_BEAT=0
declare -g  TUI_TOTAL=0         # expected stage count, for "3/14"
declare -g  TUI_DONE=0
declare -g  TUI_WIDTH=80
declare -g  TUI_HEARTBEAT_SECS="${TUI_HEARTBEAT_SECS:-15}"

# Status glyphs are ASCII on purpose. A CTF box may be on a serial console or a container
# with a C locale, where box-drawing characters arrive as mojibake and make a working tool
# look broken.
_tui_glyph() {
    case "$1" in
        ok)      printf '[ok]     ' ;;
        empty)   printf '[none]   ' ;;
        failed)  printf '[FAILED] ' ;;
        skipped) printf '[skip]   ' ;;
        running) printf '[ .. ]   ' ;;
        *)       printf '[    ]   ' ;;
    esac
}

# tui_init <expected-stage-count>
tui_init() {
    TUI_TOTAL="${1:-0}"
    TUI_DONE=0
    TUI_ROWS=0
    TUI_START=$SECONDS
    TUI_LAST_BEAT=$SECONDS

    if [[ ${OPT[tui]:-0} -eq 1 && -t 1 && -t 2 ]]; then
        TUI_MODE="tui"
    elif [[ -t 2 ]]; then
        TUI_MODE="line"
    else
        TUI_MODE="heartbeat"
    fi

    _tui_measure
    # SIGWINCH is only trapped in the drawing mode. Re-measuring on resize keeps the
    # table from wrapping, which is what corrupts an in-place redraw: a wrapped row
    # occupies two terminal lines and the rewind then lands in the middle of the table.
    if [[ $TUI_MODE == tui ]]; then
        trap '_tui_measure' WINCH
        printf '\n' >&2
    fi
    return 0
}

_tui_measure() {
    local c
    c="$(tput cols 2>/dev/null)" || c=""
    [[ -z $c ]] && c="${COLUMNS:-80}"
    is_uint "$c" || c=80
    [[ $c -lt 40 ]] && c=40
    [[ $c -gt 200 ]] && c=200
    TUI_WIDTH="$c"
    return 0
}

# tui_stage_start <name> <label>
tui_stage_start() {
    TUI_ACTIVE="$1"; TUI_LABEL="$2"
    case "$TUI_MODE" in
        tui)  _tui_redraw ;;
        line) printf 'revctf: [%d/%d] %s — %s\n' \
                  $(( TUI_DONE + 1 )) "$TUI_TOTAL" "$1" "$2" >&2 ;;
        heartbeat) _tui_beat ;;
    esac
    return 0
}

# tui_stage_end <name>
tui_stage_end() {
    local name="$1" st="${STAGE_STATUS[$1]:-ok}" secs="${STAGE_SECS[$1]:-0}"
    TUI_DONE=$(( TUI_DONE + 1 ))
    TUI_ACTIVE=""
    case "$TUI_MODE" in
        tui)  _tui_redraw ;;
        line) printf 'revctf: [%d/%d] %s %s (%ss)%s\n' \
                  "$TUI_DONE" "$TUI_TOTAL" "$name" "$st" "$secs" \
                  "$([[ -n ${STAGE_NOTE[$name]:-} ]] && printf ' — %s' "${STAGE_NOTE[$name]}")" >&2 ;;
        heartbeat)
            # A failure is always announced immediately, whatever the heartbeat interval:
            # in a CI log a stage that failed 12 minutes ago must be findable at the point
            # it happened, not folded into the next periodic line.
            if [[ $st == failed ]]; then
                printf 'revctf: %s FAILED after %ss — %s\n' \
                    "$name" "$secs" "${STAGE_NOTE[$name]:-no detail}" >&2
            else
                _tui_beat
            fi ;;
    esac
    return 0
}

# _tui_beat [force] — periodic one-liner for redirected output.
_tui_beat() {
    local now=$SECONDS
    if [[ ${1:-} != force && $(( now - TUI_LAST_BEAT )) -lt $TUI_HEARTBEAT_SECS ]]; then
        return 0
    fi
    TUI_LAST_BEAT=$now
    printf 'revctf: %d/%d stages, %ss elapsed%s\n' \
        "$TUI_DONE" "$TUI_TOTAL" "$(( now - TUI_START ))" \
        "$([[ -n $TUI_ACTIVE ]] && printf ' — running %s' "$TUI_ACTIVE")" >&2
    return 0
}

# _tui_redraw — rewind over the rows drawn last time, then draw the current table.
#
# `\r\033[K` clears each line before rewriting it. Without the clear, a shorter row leaves
# the tail of the previous, longer one visible — the classic progress-display artefact.
_tui_redraw() {
    local s st secs note line w=$TUI_WIDTH

    if [[ $TUI_ROWS -gt 0 ]]; then
        printf '\033[%dA' "$TUI_ROWS" >&2
    fi

    local rows=0
    for s in "${STAGE_ORDER[@]}"; do
        st="${STAGE_STATUS[$s]:-pending}"
        [[ $s == "$TUI_ACTIVE" ]] && st="running"
        secs="${STAGE_SECS[$s]:-0}"
        note="${STAGE_NOTE[$s]:-}"
        [[ $st == running ]] && note="$TUI_LABEL"
        line="$(printf '  %s%-10s %4ss  %s' "$(_tui_glyph "$st")" "$s" "$secs" "$note")"
        # Truncate rather than let the terminal wrap; a wrapped row breaks the rewind.
        printf '\r\033[K%.*s\n' "$w" "$line" >&2
        rows=$(( rows + 1 ))
    done

    line="$(printf '  %d/%d stages, %ss elapsed' \
        "$TUI_DONE" "$TUI_TOTAL" "$(( SECONDS - TUI_START ))")"
    printf '\r\033[K%.*s\n' "$w" "$line" >&2
    rows=$(( rows + 1 ))

    TUI_ROWS=$rows
    return 0
}

# tui_finish — leave the terminal in a sane state before the report is printed.
tui_finish() {
    [[ $TUI_MODE == tui ]] && trap - WINCH
    case "$TUI_MODE" in
        tui)       _tui_redraw; printf '\n' >&2 ;;
        heartbeat) _tui_beat force ;;
    esac
    TUI_ROWS=0
    return 0
}

# tui_note <text> — an out-of-band message that must not corrupt the table.
# In tui mode the table is redrawn underneath it, so the message scrolls away cleanly.
tui_note() {
    case "$TUI_MODE" in
        tui) if [[ $TUI_ROWS -gt 0 ]]; then printf '\033[%dA\033[J' "$TUI_ROWS" >&2; TUI_ROWS=0; fi
             printf 'revctf: %s\n' "$*" >&2
             _tui_redraw ;;
        *)   printf 'revctf: %s\n' "$*" >&2 ;;
    esac
    return 0
}
