#!/usr/bin/env bash
# lib/report.sh — assemble the plain-text report.
#
# Implemented in: M4.
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; a section that cannot be built says so
# and the rest of the report is still produced.
#
# DESIGN RULES
#
# * Plain text, always, in every display mode (v6 §10). No escapes, no colour. Tool output
#   is filtered through st_strip_ansi at the stage boundary, so captures are already clean.
# * Flags first (v6 §6.1). A beginner scrolling a 400-line report should not have to find
#   the answer; it is the first thing after the header.
# * Written to disk AND mirrored to stdout, from one code path: build the file, then cat
#   it. Two formatters would drift.
# * Never buffer a capture in a variable (v3 §1). Excerpts come from `head`, counts from
#   `wc -l`. A 220MB strings capture is a normal target.
# * A stage that found nothing says so; a stage that failed says so with the command, the
#   exit code and a stderr tail. A silently missing section is the failure mode this
#   report exists to prevent.

REPORT_EXCERPT_LINES="${REPORT_EXCERPT_LINES:-40}"
REPORT_STDERR_TAIL="${REPORT_STDERR_TAIL:-6}"
declare -g REPORT_PATH=""

# --------------------------------------------------------------------------------------
# Beginner blurbs
# --------------------------------------------------------------------------------------
# The execution masterplan's M4 gate calls these load-bearing: the target reader has just
# learned what a binary is. Each answers "why am I looking at this?" in one or two lines,
# without assuming the reader knows the tool.
_rp_blurb() {
    case "$1" in
    triage)   printf 'Works out what kind of file this actually is, and unpacks it if it is compressed, packed or inside an archive. Everything below analyses whatever this stage found.' ;;
    file)     printf 'One-line identification: architecture, whether it is stripped of names, and whether it is a Linux, Windows or Mac program.' ;;
    strings)  printf 'Every run of readable text inside the binary. Flags are often sitting here in plain sight, so this is the first place to look.' ;;
    binwalk)  printf 'Looks for whole files hidden inside this one — a zip, an image, a filesystem. CTF challenges hide payloads this way.' ;;
    hexdump)  printf 'The raw bytes. Useful for spotting a file header, padding, or an obviously encoded block that other tools missed.' ;;
    checksec) printf 'Which security protections the binary was built with, plus its imports and sections. Tells you which exploitation routes are open.' ;;
    objdump)  printf 'A second opinion from binutils on the headers and symbols, independent of the tools above. Disagreement between them is itself a clue.' ;;
    ltrace)   printf 'RUNS the program and records the library functions it calls — strcmp, printf, memcmp. A password check often reveals the expected value right here.' ;;
    radare2)  printf 'Disassembles the code: the list of functions, and the instructions of the main one. This is where the actual logic lives.' ;;
    strace)   printf 'RUNS the program and records the system calls it makes — files opened, network used. Shows what the program touches outside itself.' ;;
    floss)    printf 'Finds strings that ordinary tools miss because the program builds or decodes them at runtime. Obfuscated flags surface here.' ;;
    managed)  printf 'Java and .NET keep near-complete source inside the file. This recovers it, so you can read the challenge almost as it was written.' ;;
    pydecomp) printf 'Turns compiled Python back into readable Python, or failing that into bytecode you can still follow line by line.' ;;
    ghidra)   printf 'Full decompilation to C-like pseudocode. The slowest stage and usually the most valuable: this is where a hidden password or algorithm becomes readable.' ;;
    *)        printf 'Analysis output.' ;;
    esac
}

# Per-stage excerpt caps. strings and hexdump are unbounded in practice, so a fixed global
# cap would either bury the report or truncate a short, useful capture.
_rp_excerpt_cap() {
    case "$1" in
        strings|hexdump|binwalk) printf '25' ;;
        ghidra|managed|pydecomp|radare2) printf '60' ;;
        *) printf '%s' "$REPORT_EXCERPT_LINES" ;;
    esac
}

_rp_rule() { printf -- '----------------------------------------------------------------------\n'; }
_rp_bar()  { printf -- '======================================================================\n'; }

# --------------------------------------------------------------------------------------
# report_build — write the report, then mirror it to stdout.
# --------------------------------------------------------------------------------------
report_build() {
    local path="$RUN_OUTDIR/report.txt"
    # shellcheck disable=SC2034  # REPORT_PATH is consumed by the harness and by M7 batch mode
    REPORT_PATH="$path"

    # v4 §5: captures and the report are 0600. Scoped so the umask does not leak into the
    # rest of the run.
    local saved; saved="$(umask)"
    umask 077
    if ! : > "$path" 2>/dev/null; then
        umask "$saved"
        warn "could not write $path — printing the report to stdout only"
        path=""
    fi

    if [[ -n $path ]]; then
        _rp_emit > "$path"
        umask "$saved"
        cat -- "$path"
    else
        _rp_emit
    fi
    return 0
}

_rp_emit() {
    _rp_header
    _rp_flags
    _rp_table
    _rp_resources
    if [[ ${OPT[summary_only]:-0} -eq 0 ]]; then
        _rp_detail
    else
        printf '\n(--summary-only: per-stage detail omitted. Full captures are in %s)\n' \
            "$RUN_OUTDIR"
    fi
    _rp_failures
    _rp_next
    return 0
}

_rp_header() {
    _rp_bar
    printf ' revctf %s — analysis report\n' "$REVCTF_VERSION"
    # Attribution lives HERE and nowhere else in the report. The report's job is flags
    # first; a beginner must not scroll past a byline to reach the answer.
    printf ' created by %s — MIT licence\n' "${REVCTF_AUTHOR:-Jijo Shibu}"
    _rp_bar
    printf 'Target    : %s\n' "$RUN_ORIGINAL"
    printf 'Size      : %s\n' "$(st_human_size "$(st_file_size "$RUN_ORIGINAL")")"
    printf 'Format    : %s\n' "$RUN_FORMAT"
    if [[ $RUN_TARGET != "$RUN_ORIGINAL" ]]; then
        printf 'Analysed  : %s\n' "$RUN_TARGET"
        printf '            (the original was packed or a container; the payload above was\n'
        printf '             extracted to a copy — your file was not modified)\n'
    fi
    printf 'Captures  : %s\n' "$RUN_OUTDIR"
    printf 'Finished  : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    # One line, always. On an ordinary run this is the entire resource story; when anything
    # non-default is in force it points at the section that explains it.
    if [[ -n ${TIER:-} ]]; then
        printf 'Resources : Tier %s, %sMB RAM%s\n' "$TIER" "$TIER_RAM_MB" \
            "$( [[ ${#TIER_NOTES[@]} -gt 0 || ${TIER:-A} != A ]] \
                && printf ' — see RESOURCES AND LIMITS below' )"
    fi
    return 0
}

# _rp_resources — the tier, the ceilings that were in force, and the notes that explain
# anything unusual about them.
#
# THIS SECTION DID NOT EXIST, AND ITS ABSENCE MADE A SAFEGUARD LOOK STRONGER THAN IT WAS.
#
# tier_report() is called from exactly one place: dry_run_plan(). So the tier, the RAM
# figure and every entry in TIER_NOTES appeared in `--dry-run` output and NOWHERE in a real
# scan's report. That included the "RAM figure was INJECTED via REVCTF_RAM_MB" label, which
# exists specifically so a tier chosen from a fake number can never be mistaken for a
# measurement — a guarantee that held for the plan and not for the artefact anybody keeps.
# It also included the no-swap OOM warning and the reason FLOSS had been degraded.
#
# Every harness check for those notes asserted against `--dry-run`, so they all passed.
_rp_resources() {
    declare -F tier_report >/dev/null 2>&1 || return 0
    # SHOWN ONLY WHEN SOMETHING NON-DEFAULT IS IN FORCE. The safeguard being restored here
    # is "a fake number must never look measured", not "every report carries a resource
    # table". An ordinary Tier A scan with no overrides has nothing to explain, and the
    # report's design goal is flags first, plain English, no overwhelm — a table of ceilings
    # nobody came near works against that. The header carries a one-line summary regardless.
    #
    # A note is raised for every condition worth reporting: an injected RAM figure or
    # ceiling, degraded FLOSS, an explicit --jobs-*/--maxmem-ghidra override, the no-swap OOM
    # warning, automatic light-decompile. A tier below A is the one thing that changes every
    # ceiling without necessarily raising a note, so it is checked separately.
    [[ ${#TIER_NOTES[@]} -gt 0 || ${TIER:-A} != A ]] || return 0

    printf '\n'
    _rp_rule
    printf ' RESOURCES AND LIMITS\n'
    _rp_rule
    printf 'Something non-default applied to this run. These are the limits each stage was\n'
    printf 'actually held to; a stage reported as killed above was most likely stopped here.\n\n'
    # Filtered through st_strip_ansi for the same reason every capture is: v6 §10 requires
    # the report to be plain text in every display mode.
    tier_report | st_strip_ansi
    return 0
}

_rp_flags() {
    printf '\n'
    _rp_rule
    printf ' POSSIBLE FLAGS\n'
    _rp_rule
    # Called unconditionally: flagscan_report handles the disabled and empty cases itself.
    # Omitting the section when nothing was found leaves the reader staring at a report
    # with no flag section and no explanation of why.
    flagscan_report
    return 0
}

_rp_table() {
    local s status secs bytes note
    printf '\n'
    _rp_rule
    printf ' WHAT RAN\n'
    _rp_rule
    printf '%-10s  %-8s  %6s  %10s  %s\n' STAGE STATUS TIME OUTPUT NOTE
    for s in "${STAGE_ORDER[@]}"; do
        status="${STAGE_STATUS[$s]:-?}"
        secs="${STAGE_SECS[$s]:-0}"
        bytes="$(st_human_size "$(st_file_size "${STAGE_OUT[$s]:-/dev/null}")")"
        note="${STAGE_NOTE[$s]:-}"
        printf '%-10s  %-8s  %5ss  %10s  %s\n' "$s" "$status" "$secs" "$bytes" "$note"
    done
    printf '\n'
    printf 'ok = produced output   none = ran, found nothing   failed = see DIAGNOSTICS\n'
    printf 'skipped = not applicable to this file, or disabled by a flag\n'
    return 0
}

_rp_detail() {
    local s status out cap total
    printf '\n'
    _rp_rule
    printf ' STAGE DETAIL\n'
    _rp_rule
    for s in "${STAGE_ORDER[@]}"; do
        status="${STAGE_STATUS[$s]:-?}"
        out="${STAGE_OUT[$s]:-}"
        printf '\n### %s  [%s, %ss]\n' "$s" "$status" "${STAGE_SECS[$s]:-0}"
        printf '%s\n' "$(_rp_blurb "$s")"

        case "$status" in
            skipped)
                printf -- '-- skipped: %s\n' "${STAGE_NOTE[$s]:-not applicable}"
                continue ;;
            failed)
                printf -- '-- this stage failed; see DIAGNOSTICS below\n'
                continue ;;
            empty)
                printf -- '-- ran cleanly and found nothing. That is a result, not an error.\n'
                continue ;;
        esac

        if [[ -z $out || ! -s $out ]]; then
            printf -- '-- no capture file was produced\n'
            continue
        fi

        cap="$(_rp_excerpt_cap "$s")"
        total="$(wc -l < "$out" 2>/dev/null || printf '0')"
        total="${total//[^0-9]/}"; total="${total:-0}"
        printf -- '--\n'
        # `head` streams; the capture is never read into a variable (v3 §1).
        head -n "$cap" -- "$out" 2>/dev/null | sed 's/^/  /'
        if [[ $total -gt $cap ]]; then
            printf '  ... %d more lines\n' $(( total - cap ))
        fi
        printf -- '-- full output: %s (%s lines)\n' "$out" "$total"
    done
    return 0
}

_rp_failures() {
    local s any=0 err
    for s in "${STAGE_ORDER[@]}"; do
        [[ ${STAGE_STATUS[$s]:-} == failed ]] && { any=1; break; }
    done
    [[ $any -eq 0 ]] && return 0

    printf '\n'
    _rp_rule
    printf ' DIAGNOSTICS — stages that failed\n'
    _rp_rule
    printf 'One failed stage never stops a run (a failure is isolated and the rest\n'
    printf 'continue), so the report below is complete apart from these.\n'
    for s in "${STAGE_ORDER[@]}"; do
        [[ ${STAGE_STATUS[$s]:-} == failed ]] || continue
        printf '\n%s\n' "$s"
        printf '  reason  : %s\n' "${STAGE_NOTE[$s]:-no detail recorded}"
        printf '  command : %s\n' "${STAGE_CMD[$s]:-<not recorded>}"
        printf '  exit    : %s\n' "${STAGE_RC[$s]:-?}"
        err="$(stage_err_path "$s")"
        if [[ -s $err ]]; then
            printf '  stderr  :\n'
            tail -n "$REPORT_STDERR_TAIL" -- "$err" 2>/dev/null | sed 's/^/            /'
        fi
    done
    return 0
}

# What to try next — derived from what actually happened, not a static block. A generic
# checklist gets skipped; a line naming the stage that was skipped on THIS file does not.
_rp_next() {
    local s n=0
    printf '\n'
    _rp_rule
    printf ' WHAT TO TRY NEXT\n'
    _rp_rule

    if [[ ${#FLAG_HITS[@]} -gt 0 ]]; then
        printf '%d. Submit the high-confidence candidates above first. If one is rejected,\n' $(( ++n ))
        printf '   check it is complete — a flag cut off at a buffer boundary looks valid.\n'
    else
        printf '%d. Nothing matched a flag pattern. If this event uses its own wrapper,\n' $(( ++n ))
        printf '   re-run with --flag-format '\''NAME\\{.*\\}'\'' to teach revctf the shape.\n'
    fi

    # A STAGE THAT COULD NEVER APPLY IS NOT A GAP, AND LISTING IT AS ONE IS NOISE.
    #
    # This used to name every skipped stage. On a native ELF that means `managed` and
    # `pydecomp` -- a Java decompiler and a Python bytecode decompiler -- are both reported
    # as places "the flag might be hiding". Measured on a real picoCTF target: four such
    # lines, which pushed the one genuinely useful pointer (read ghidra and radare2
    # together, which is exactly where both flags were) down to item 6.
    #
    # A format-based skip is the pipeline working correctly. A skip the user can act on --
    # a missing tool, a flag they passed, a stage that failed -- is worth a line.
    local reason
    for s in "${STAGE_ORDER[@]}"; do
        reason="${STAGE_NOTE[$s]:-}"
        case "${STAGE_STATUS[$s]:-}" in
            skipped)
                # Inapplicable to this file type: not a gap, not actionable, not listed.
                # Every format-based skip reason carries "(this one is <format>)" -- it is
                # the shared marker for "the pipeline correctly routed around your file",
                # emitted by dyn_guard and by the managed/pydecomp/native guards alike.
                case "$reason" in
                    *"(this one is "*|*"not applicable"*) continue ;;
                esac
                printf '%d. Stage "%s" did not run (%s). If the flag is hiding there,\n' \
                    $(( ++n )) "$s" "$reason"
                printf '   that is the gap in this report.\n' ;;
            failed)
                printf '%d. Stage "%s" FAILED — see DIAGNOSTICS above. That is a real gap:\n' \
                    $(( ++n )) "$s"
                printf '   the analysis it would have contributed is simply missing.\n' ;;
        esac
    done

    if [[ ${OPT[summary_only]:-0} -eq 1 ]]; then
        printf '%d. This was --summary-only. Re-run without it, or read the capture files\n' $(( ++n ))
        printf '   in %s, for the full detail.\n' "$RUN_OUTDIR"
    fi

    printf '%d. Read the ghidra and radare2 sections together: pseudocode tells you what\n' $(( ++n ))
    printf '   the program decides, the disassembly tells you exactly how.\n'
    printf '\nCaptures kept in: %s\n' "$RUN_OUTDIR"
    return 0
}
