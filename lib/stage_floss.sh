#!/usr/bin/env bash
# lib/stage_floss.sh — Stage 10: obfuscated and stack strings.
#
# Implemented in: M3 (new in v6, deviation D2).  Must not enable `set -e`.
#
# FLOSS is format-aware here because it has to be. Verified against floss 3.1.1: stack
# strings, tight strings and decoded strings are **PE-only**. On an ELF it exits with
#   "FLOSS currently supports the following formats for string decoding and stackstrings: PE"
# and produces nothing at all.
#
# So: all modes on PE, `--only static` on ELF and everything else. The distinction goes in
# the report, because "FLOSS found no hidden strings" and "FLOSS cannot look for hidden
# strings in this format" are completely different statements and must not read alike.
# Largest target FLOSS will be run against, in MB.
#
# MEASURED, not guessed. FLOSS builds a vivisect workspace over the whole file: on the
# 220MB corpus blob it peaked at 1,495,336 KB — about 1.46GB — and took ~180s. Cutting
# FLOSS out of that same scan dropped the run's peak RSS to 140MB, so it is the single
# largest consumer in Phase 2 by an order of magnitude.
#
# This matters beyond one stage. v6 §5 assumed Phase 2 could inherit the tier's Ghidra
# ceiling (1024M on Tier A, 512M on Tier C) on the argument that it matched an already
# derived and tested profile. That assumption is now disproved: FLOSS alone exceeds Tier
# A's ceiling and is roughly 3x Tier C's. M5 must size Phase 2 from this measurement
# rather than inheriting Ghidra's.
#
# 64MB matches the radare2 deep-analysis limit. A target that large is firmware or a data
# blob, where FLOSS's stack-string emulation has nothing meaningful to find anyway.
#
# CORRECTION (M5, measured): this constant used to claim it "keeps FLOSS comfortably inside
# every tier". IT DOES NOT, and that claim was load-bearing — it was the stated reason the
# unresolved Phase-2 ceiling was safe to defer. FLOSS's peak is driven by vivisect's
# emulation workspace, NOT by input size:
#
#   264KB PE, --only static   100MB        264KB PE, --only stack    864MB
#   264KB PE, all modes       899MB        210MB blob, all modes    1460MB
#
# A 264KB PE is 250x under this gate and still costs ~900MB — over Tier C's and Tier B's
# old ceilings. Input size is therefore the wrong axis for a memory guard. The real bound
# is the enforced Phase-2 ceiling (lib/tier.sh), and on tiers too small for emulation the
# stage degrades to static-only rather than being OOM-killed. This gate remains, doing the
# job it can actually do: keeping a 220MB blob out of a tool that would spend three minutes
# finding nothing in it.
FLOSS_MAX_MB="${FLOSS_MAX_MB:-64}"

stage_floss() {
    local name="floss" out err rc=0
    out="$(stage_out_path "$name")"
    err="$(stage_err_path "$name")"

    if ! command -v floss >/dev/null 2>&1; then
        stage_skip "$name" "floss is not installed (re-run install.sh)"
        return 0
    fi
    case "$RUN_FORMAT" in
        java|pyc|pyinstaller|archive)
            stage_skip "$name" "not a native binary (this one is $RUN_FORMAT)"
            return 0 ;;
    esac

    local size_mb
    size_mb=$(( $(st_file_size "$RUN_TARGET") / 1048576 ))
    if [[ $size_mb -gt $FLOSS_MAX_MB ]]; then
        {
            printf '=== FLOSS ===\n'
            printf 'Skipped: this target is %sMB, over the %sMB limit.\n\n' "$size_mb" "$FLOSS_MAX_MB"
            printf 'FLOSS builds an analysis workspace over the whole file. Measured on a\n'
            printf '220MB target it peaked at about 1.46GB of RAM and took three minutes,\n'
            printf 'and a file this size is firmware or a data blob, where its stack-string\n'
            printf 'emulation has nothing meaningful to find.\n'
            printf 'The strings stage above covers this target; raise FLOSS_MAX_MB to\n'
            printf 'override.\n'
        } > "$out"
        stage_write "$name" ok
        stage_set_status "$name" skipped "target is ${size_mb}MB, over the ${FLOSS_MAX_MB}MB limit"
        return 0
    fi

    local -a modes; local scope_note tier_limited=0
    if [[ $RUN_FORMAT == pe || $RUN_FORMAT == dotnet ]]; then
        if [[ ${TIER_FLOSS_STATIC_ONLY:-0} -eq 1 ]]; then
            # Measured: emulation costs ~900MB even on a 264KB PE. On a tier whose Phase-2
            # ceiling cannot cover that, running it is a guaranteed OOM kill, so degrade
            # instead of failing — the same choice Tier C makes for Ghidra.
            modes=(--only static)
            scope_note="static strings only (emulation does not fit this RAM tier)"
            tier_limited=1
        else
            modes=(--only static stack tight decoded)
            scope_note="all modes (static, stack, tight, decoded)"
        fi
    else
        modes=(--only static)
        scope_note="static strings only"
    fi

    {
        printf '=== FLOSS (%s) ===\n' "$scope_note"
        if [[ $tier_limited -eq 1 ]]; then
            printf 'NOTE: this host is Tier %s. FLOSS stack/tight/decoded extraction needs\n' "${TIER:-C}"
            printf '      about 900MB of RAM regardless of file size, which does not fit\n'
            printf '      this tier'"'"'s %sMB Phase-2 ceiling, so only static extraction ran.\n' \
                "${TIER_PHASE2_CEIL_MB:-512}"
            printf '      An absent flag here does NOT mean there is no hidden string —\n'
            printf '      it means this tool was not given room to look for one.\n'
            printf '      More RAM, or --maxmem-ghidra-style tuning, would enable it.\n'
        elif [[ ${modes[*]} != *stack* ]]; then
            printf 'NOTE: FLOSS can only recover stack, tight and decoded strings from PE\n'
            printf '      binaries. This target is %s, so only static extraction ran.\n' "$RUN_FORMAT"
            printf '      An absent flag here does NOT mean there is no hidden string —\n'
            printf '      it means this tool could not look for one in this format.\n'
        fi
        printf '\n'
    } > "$out"

    st_run_bounded "$ST_T_FLOSS" "$out.f" "$err" \
        -- floss -q --color never "${modes[@]}" -- "$RUN_TARGET" || rc=$?
    cat "$out.f" >> "$out" 2>/dev/null; rm -f "$out.f"

    stage_record_exec "$name" "floss -q ${modes[*]} $RUN_TARGET" "$rc"
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        stage_set_status "$name" failed "$(st_explain_kill "$rc" "$ST_T_FLOSS")"
    elif [[ $rc -ne 0 ]]; then
        stage_set_status "$name" failed "floss exited $rc — $(tail -c 160 "$err" 2>/dev/null | tr '\n' ' ')"
    else
        stage_write "$name" ok
        stage_set_status "$name" ok "$scope_note"
    fi
    return 0
}
