#!/usr/bin/env bash
# lib/flagscan.sh — tiered flag detection with an encoding sweep.
#
# Implemented in: M3.  Deviation D5 (v6 §6).
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`.
#
# ======================================================================================
# HARD CONSTRAINT — read before changing anything here
# ======================================================================================
# Use `grep -E` (POSIX ERE) and nothing else. Never `grep -P`, never a PCRE engine, never
# a Bash `=~` match against a user-supplied pattern.
#
# `--flag-format` takes a regex FROM THE USER, and the scan runs it across every stage
# capture — which for a large target is multiple megabytes of `strings` output. A
# backtracking engine turns a pattern like `(a+)+$` into a self-inflicted denial of
# service. GNU grep -E is DFA-based and has no catastrophic-backtracking failure mode, so
# choosing the right engine removes the whole class of problem rather than trying to
# validate patterns for safety, which is not reliably possible.
#
# The entry script already validates that `--flag-format` is a syntactically valid ERE. It
# deliberately does NOT try to judge whether a pattern is "safe" — that is the engine's job.
#
# tools/run-tests.sh asserts that no PCRE flag appears anywhere in lib/.
# ======================================================================================
#
# Output contract: FLAG_HITS holds one record per candidate, tab-separated:
#     <confidence>\t<stage>\t<encoding>\t<value>
# confidence: high | medium | low     encoding: plain | base64 | base32 | hex | rot13

declare -ga FLAG_HITS=()
declare -g  FLAG_HIGH=0 FLAG_MED=0 FLAG_LOW=0

# Longest candidate worth reporting. A "flag" longer than this is a false positive that
# would otherwise dominate the report.
FLAG_MAX_LEN="${FLAG_MAX_LEN:-200}"

# --- known formats (v6 §6.1) ----------------------------------------------------------
# Braced wrappers, highest confidence. Ordered generic → platform → competition.
_FLAG_BRACED='(flag|FLAG|ctf|CTF|HTB|THM|picoCTF|pico|DUCTF|uiuctf|corctf|SEE|csawctf|justCTF)\{[^}]{1,200}\}'
# Unwrapped hash/key-style tokens. Deliberately ranked BELOW braced matches: a normal
# binary yields dozens of these from build IDs, GUIDs and checksums. Kept because some
# challenges genuinely have no wrapper, dropped to medium so they cannot bury a real flag.
_FLAG_HASHLIKE='\b([0-9a-fA-F]{32}|[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\b'
# Generic fallback: anything{anything}. Low confidence by construction.
_FLAG_GENERIC='[A-Za-z0-9_]{2,}\{[^}]{1,200}\}'

_fs_add() {   # <confidence> <stage> <encoding> <value>
    local conf="$1" stage="$2" enc="$3" val="$4"
    [[ ${#val} -le $FLAG_MAX_LEN ]] || return 0
    FLAG_HITS+=("$conf	$stage	$enc	$val")
    case "$conf" in
        high)   FLAG_HIGH=$(( FLAG_HIGH + 1 )) ;;
        medium) FLAG_MED=$((  FLAG_MED  + 1 )) ;;
        low)    FLAG_LOW=$((  FLAG_LOW  + 1 )) ;;
    esac
}

# _fs_scan_stream <stage> <encoding> — read stdin, emit matches at each tier.
# _fs_scan_stream <stage> <encoding> — read stdin, emit matches at each tier.
#
# For a DECODED stream (anything but `plain`) only known formats count. Decoding produces
# a lot of text that coincidentally satisfies the generic `word{...}` shape: ROT13-ing a
# capture that already contains `flag{cr4ckm3_s0lv3d}` yields `synt{pe4pxz3_f0yi3q}`,
# which is not a finding — it is the same flag, mirrored. Requiring a known wrapper on
# decoded text keeps the sweep's real wins (base64-in-.rodata) without the mirror noise.
_fs_scan_stream() {
    local stage="$1" enc="$2" line
    local tmp; tmp="$RUN_WORKDIR/fs.$$"
    cat > "$tmp" 2>/dev/null || return 0

    # User pattern first: an explicit --flag-format is the most reliable signal there is.
    if [[ -n ${OPT[flag_format]:-} ]]; then
        while IFS= read -r line; do
            _fs_add high "$stage" "$enc" "$line"
        done < <(grep -aoE -- "${OPT[flag_format]}" "$tmp" 2>/dev/null | sort -u | head -50)
    fi

    while IFS= read -r line; do
        _fs_add high "$stage" "$enc" "$line"
    done < <(grep -aoE -- "$_FLAG_BRACED" "$tmp" 2>/dev/null | sort -u | head -50)

    if [[ $enc == plain ]]; then
        while IFS= read -r line; do
            _fs_add medium "$stage" "$enc" "$line"
        done < <(grep -aoE -- "$_FLAG_HASHLIKE" "$tmp" 2>/dev/null | sort -u | head -20)

        # Generic braced matches the known-format pass did not already claim.
        while IFS= read -r line; do
            grep -qaE -- "$_FLAG_BRACED" <<< "$line" && continue
            _fs_add low "$stage" "$enc" "$line"
        done < <(grep -aoE -- "$_FLAG_GENERIC" "$tmp" 2>/dev/null | sort -u | head -30)
    fi

    rm -f "$tmp"
    return 0
}

# --- encoding sweep (v6 §6.2) ---------------------------------------------------------
# Base64-in-.rodata is among the most common CTF hiding tricks and is completely invisible
# to a plain regex pass. Candidates are filtered on length and charset first so the sweep
# decodes plausible tokens rather than every line of a multi-megabyte capture.
_fs_sweep_encodings() {
    local stage="$1" src="$2"
    [[ -s $src ]] || return 0

    local dec="$RUN_WORKDIR/fs.dec.$$"

    # base64 — length a multiple of 4, base64 alphabet, long enough to hold a flag.
    : > "$dec"
    while IFS= read -r tok; do
        printf '%s' "$tok" | base64 -d 2>/dev/null | tr -d '\0' >> "$dec" 2>/dev/null
        printf '\n' >> "$dec"
    done < <(grep -aoE '\b[A-Za-z0-9+/]{16,}={0,2}\b' "$src" 2>/dev/null | sort -u | head -400)
    [[ -s $dec ]] && _fs_scan_stream "$stage" base64 < "$dec"

    # base32
    : > "$dec"
    while IFS= read -r tok; do
        printf '%s' "$tok" | base32 -d 2>/dev/null | tr -d '\0' >> "$dec" 2>/dev/null
        printf '\n' >> "$dec"
    done < <(grep -aoE '\b[A-Z2-7]{16,}={0,6}\b' "$src" 2>/dev/null | sort -u | head -200)
    [[ -s $dec ]] && _fs_scan_stream "$stage" base32 < "$dec"

    # hex — even length, hex alphabet, long enough to be a string rather than an address.
    #
    # Decoded with printf rather than `xxd`. xxd is NOT part of a base install (it ships
    # with vim-common, not coreutils), and when it is absent the sweep silently produces
    # nothing — the hex-encoded flag in the test corpus went undetected for exactly this
    # reason, and it looked identical to "no flag here". Rewriting each byte pair as \xNN
    # and letting printf %b expand it depends on nothing beyond the shell itself.
    : > "$dec"
    while IFS= read -r tok; do
        # SC2059: the constructed \xNN string IS the format string here, deliberately.
        # SC2001: ${var//from/to} cannot express "insert before every second character",
        # which is exactly what this substitution does.
        # shellcheck disable=SC2059,SC2001
        printf "$(sed 's/../\\x&/g' <<< "$tok")" 2>/dev/null | tr -d '\0' >> "$dec" 2>/dev/null
        printf '\n' >> "$dec"
    done < <(grep -aoE '\b([0-9a-fA-F]{2}){12,}\b' "$src" 2>/dev/null | sort -u | head -200)
    [[ -s $dec ]] && _fs_scan_stream "$stage" hex < "$dec"

    # ROT13 — cheap enough to apply to the whole capture rather than picking candidates.
    tr 'A-Za-z' 'N-ZA-Mn-za-m' < "$src" 2>/dev/null | head -c 4194304 > "$dec"
    [[ -s $dec ]] && _fs_scan_stream "$stage" rot13 < "$dec"

    rm -f "$dec"
    return 0
}

# ======================================================================================
# Entry point
# ======================================================================================
# flagscan_run — scan every stage capture from this file's run.
#
# Cross-stage by design (v6 §6.3): a flag recovered from Ghidra's pseudo-C or an ltrace
# argument is worth as much as one from `strings`, and knowing WHICH stage produced it is
# most of the value when deciding whether to trust it.
flagscan_run() {
    FLAG_HITS=(); FLAG_HIGH=0; FLAG_MED=0; FLAG_LOW=0

    if [[ ${OPT[flag_scan]:-1} -eq 0 ]]; then
        return 0
    fi

    local s cap
    for s in "${STAGE_ORDER[@]}"; do
        cap="${STAGE_OUT[$s]:-}"
        [[ -n $cap && -s $cap ]] || continue
        _fs_scan_stream "$s" plain < "$cap"
        _fs_sweep_encodings "$s" "$cap"
    done

    # Deduplicate on value, keeping the highest confidence seen for it. Without this the
    # same flag appears once per stage that saw it, and a real find is buried in repeats.
    if [[ ${#FLAG_HITS[@]} -gt 0 ]]; then
        local -a deduped=()
        local -A best=()
        local rec conf stage enc val rank prev
        for rec in "${FLAG_HITS[@]}"; do
            IFS=$'\t' read -r conf stage enc val <<< "$rec"
            case "$conf" in high) rank=3 ;; medium) rank=2 ;; *) rank=1 ;; esac
            prev="${best[$val]:-0	}"
            [[ ${prev%%	*} -ge $rank ]] && continue
            best[$val]="$rank	$rec"
        done
        FLAG_HIGH=0; FLAG_MED=0; FLAG_LOW=0
        for val in "${!best[@]}"; do
            rec="${best[$val]#*	}"
            deduped+=("$rec")
            case "${rec%%	*}" in
                high)   FLAG_HIGH=$(( FLAG_HIGH + 1 )) ;;
                medium) FLAG_MED=$((  FLAG_MED  + 1 )) ;;
                low)    FLAG_LOW=$((  FLAG_LOW  + 1 )) ;;
            esac
        done
        # Highest confidence FIRST. Sorting the words "high/medium/low" alphabetically
        # puts medium before low before high, which is exactly backwards, so sort on the
        # numeric rank and strip it again afterwards.
        mapfile -t FLAG_HITS < <(
            for rec in "${deduped[@]}"; do
                case "${rec%%	*}" in high) printf '1\t%s\n' "$rec" ;;
                                      medium) printf '2\t%s\n' "$rec" ;;
                                      *) printf '3\t%s\n' "$rec" ;; esac
            done | sort -t$'\t' -k1,1n -k5,5 | cut -f2-)
    fi
    return 0
}

# flagscan_report — the "Possible Flags Found" block. M4's report.sh calls this.
flagscan_report() {
    if [[ ${OPT[flag_scan]:-1} -eq 0 ]]; then
        printf 'Flag detection was disabled (--no-flag-scan).\n'
        return 0
    fi
    if [[ ${#FLAG_HITS[@]} -eq 0 ]]; then
        printf 'No flag candidates were found.\n\n'
        printf 'That is not the same as "there is no flag". Check any stage marked\n'
        printf 'skipped or failed above, and consider --flag-format if this event uses\n'
        printf 'a wrapper revctf does not know.\n'
        return 0
    fi

    printf '[FLAG] Possible flags found: %d high, %d medium, %d low confidence\n\n' \
        "$FLAG_HIGH" "$FLAG_MED" "$FLAG_LOW"

    # Medium is capped in the listing. It is the unwrapped hash-like tier, and a binary
    # full of build IDs and checksums produced 21 of them for a target with no flag at
    # all — enough to bury a real high-confidence hit under scrolling.
    local med_cap="${FLAG_MED_SHOW:-5}" med_shown=0
    local rec conf stage enc val shown_hdr=""
    for rec in "${FLAG_HITS[@]}"; do
        IFS=$'\t' read -r conf stage enc val <<< "$rec"
        if [[ $conf == medium ]]; then
            med_shown=$(( med_shown + 1 ))
            if [[ $med_shown -gt $med_cap ]]; then
                [[ $med_shown -eq $(( med_cap + 1 )) ]] && \
                    printf '  ... and %d more hash-like tokens (set FLAG_MED_SHOW to see them)\n' \
                        $(( FLAG_MED - med_cap ))
                continue
            fi
        fi
        if [[ $conf != "$shown_hdr" ]]; then
            printf '\n--- %s confidence ---\n' "$conf"
            shown_hdr="$conf"
        fi
        if [[ $enc == plain ]]; then
            printf '  %s\n      found by: %s\n' "$val" "$stage"
        else
            printf '  %s\n      found by: %s (recovered by %s decoding)\n' "$val" "$stage" "$enc"
        fi
    done

    if [[ $FLAG_MED -gt 0 ]]; then
        printf '\nNote: medium-confidence entries are unwrapped hash-like tokens. Binaries\n'
        printf 'are full of these (build IDs, GUIDs, checksums), so treat them as leads\n'
        printf 'rather than answers.\n'
    fi
    return 0
}
