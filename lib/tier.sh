#!/usr/bin/env bash
# lib/tier.sh — RAM-tier resolution (v6 §5 / v4 §3) and --jobs-*/--maxmem-ghidra overrides.
#
# Implemented in: M5 (groundwork written pre-migration; the NUMBERS still need measuring).
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`.
#
# READ THIS BEFORE TRUSTING THE CONSTANTS BELOW
#
# The tier table is carried unchanged from v4 §3, and v4 §10 flags its boundaries as
# ESTIMATES that were never measured. That warning has already been vindicated once: v3's
# "Ghidra 11.x+ uses PyGhidra" boundary was an estimate too, and it was wrong by a whole
# major version, which cost a silent empty-output bug. Treat 3.8GB/2.5GB the same way —
# they are a starting point to be moved once M5 can measure on real hardware, not settled
# design.
#
# Every constant is named and grouped here so moving one is a one-line change with no
# hunting through the resolution logic.

# --------------------------------------------------------------------------------------
# The tier table (v6 §5, carried from v4 §3)
# --------------------------------------------------------------------------------------
# Boundaries in MB. 3.8GB = 3891MB, 2.5GB = 2560MB.
TIER_A_MIN_MB="${TIER_A_MIN_MB:-3891}"
TIER_B_MIN_MB="${TIER_B_MIN_MB:-2560}"

#            Tier   jobs_light  r2_ceiling_mb  jobs_ghidra  maxmem_ghidra  decompile
_TIER_ROW_A="4 640 2 1024M full"
_TIER_ROW_B="2 450 1 768M full"
_TIER_ROW_C="1 400 1 512M light"

# Every tier also carries this second, percentage-based JVM bound (v6 §5).
TIER_JVM_RAM_PCT="${TIER_JVM_RAM_PCT:-25}"

# The RSS fraction at which the M5 watchdog kills the job tree (v4 §3).
TIER_WATCHDOG_PCT="${TIER_WATCHDOG_PCT:-90}"

# --------------------------------------------------------------------------------------
# Resolved state
# --------------------------------------------------------------------------------------
declare -g TIER=""                 # A | B | C
declare -g TIER_RAM_MB=0
declare -g TIER_RAM_SOURCE=""      # free | /proc/meminfo | injected | unknown
declare -g TIER_JOBS_LIGHT=1
declare -g TIER_R2_CEIL_MB=400
declare -g TIER_JOBS_GHIDRA=1
declare -g TIER_MAXMEM_GHIDRA="512M"
declare -g TIER_DECOMPILE="light"
declare -g TIER_PHASE2_CEIL_MB=0
declare -ga TIER_NOTES=()

# --------------------------------------------------------------------------------------
# tier_detect_ram_mb — total physical RAM in MB, or 0 if it cannot be determined.
# --------------------------------------------------------------------------------------
# REVCTF_RAM_MB overrides detection outright. That exists for the verification harness:
# tier selection is the one piece of M5 whose *branches* can be tested anywhere, while its
# *behaviour* can only be tested on hardware that actually has that much RAM. Injecting the
# value lets the branch logic be pinned in CI on any box, without pretending the memory
# behaviour has been verified. The report always says when a value was injected — a tier
# chosen from a fake number must never look like a measurement.
# It sets TIER_RAM_MB and TIER_RAM_SOURCE directly rather than printing the figure.
# Command substitution runs in a subshell, so a `$(tier_detect_ram_mb)` call would have
# discarded the source assignment and the plan would report "(via )" — which is exactly
# the kind of quietly-missing provenance that makes an injected value look measured.
tier_detect_ram_mb() {
    local mb=""
    TIER_RAM_MB=0
    TIER_RAM_SOURCE="unknown"

    if [[ -n ${REVCTF_RAM_MB:-} ]]; then
        if is_uint "$REVCTF_RAM_MB"; then
            TIER_RAM_MB="$REVCTF_RAM_MB"
            TIER_RAM_SOURCE="injected"
            return 0
        fi
        warn "REVCTF_RAM_MB is not a whole number ('$REVCTF_RAM_MB'); detecting normally"
    fi

    # v6 §5 specifies `free -m`. /proc/meminfo is the fallback for a container or a
    # stripped image where procps is absent.
    if command -v free >/dev/null 2>&1; then
        mb="$(free -m 2>/dev/null | awk '/^Mem:/{print $2; exit}')"
        if [[ -n $mb ]] && is_uint "$mb"; then
            TIER_RAM_MB="$mb"; TIER_RAM_SOURCE="free -m"; return 0
        fi
    fi
    if [[ -r /proc/meminfo ]]; then
        mb="$(awk '/^MemTotal:/{printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null)"
        if [[ -n $mb ]] && is_uint "$mb"; then
            TIER_RAM_MB="$mb"; TIER_RAM_SOURCE="/proc/meminfo"; return 0
        fi
    fi
    return 0
}

# --------------------------------------------------------------------------------------
# tier_resolve — detect RAM, pick a tier, apply CLI/config overrides.
# --------------------------------------------------------------------------------------
# Never fails the run. An undetectable RAM figure falls back to Tier C, which is the
# conservative choice: the worst outcome of guessing low is a slower scan, while guessing
# high on a 2GB box is an OOM kill mid-Ghidra.
tier_resolve() {
    TIER_NOTES=()
    tier_detect_ram_mb

    # Coerce before anything reaches an arithmetic test. A non-numeric word in `-ge`
    # context exits the shell outright under `set -u` — this is the QA-1 rule and it
    # applies to a value read from `free` exactly as it applies to one read from a config
    # file.
    is_uint "$TIER_RAM_MB" || TIER_RAM_MB=0

    if [[ $TIER_RAM_MB -eq 0 ]]; then
        TIER="C"
        TIER_NOTES+=("RAM could not be detected; assuming the tightest tier (C). Override with --jobs-light/--jobs-ghidra/--maxmem-ghidra.")
    elif [[ $TIER_RAM_MB -ge $TIER_A_MIN_MB ]]; then
        TIER="A"
    elif [[ $TIER_RAM_MB -ge $TIER_B_MIN_MB ]]; then
        TIER="B"
    else
        TIER="C"
    fi

    local row
    case "$TIER" in
        A) row="$_TIER_ROW_A" ;;
        B) row="$_TIER_ROW_B" ;;
        *) row="$_TIER_ROW_C" ;;
    esac
    read -r TIER_JOBS_LIGHT TIER_R2_CEIL_MB TIER_JOBS_GHIDRA TIER_MAXMEM_GHIDRA \
            TIER_DECOMPILE <<< "$row"

    if [[ $TIER_RAM_SOURCE == injected ]]; then
        TIER_NOTES+=("RAM figure was INJECTED via REVCTF_RAM_MB (${TIER_RAM_MB}MB) — this tier was not measured.")
    fi

    # --- Phase-2 ceiling ---------------------------------------------------------------
    # v6 §5 derives Phase 2's per-job ceiling as the tier's Ghidra MAXMEM, on the argument
    # that it makes Phase 2's worst case identical to Phase 3's, which v3 §8 already sized.
    # M3 measurement DISPROVES the premise: FLOSS peaks at ~1.46GB on a 220MB target, which
    # exceeds Tier A's 1024M and is roughly 3x Tier C's. The derivation is implemented as
    # written — inventing a replacement number without measuring would repeat the mistake —
    # but the gap is stated here and in the plan output, and FLOSS_MAX_MB (64MB) keeps the
    # one known offender inside every tier meanwhile.
    TIER_PHASE2_CEIL_MB="${TIER_MAXMEM_GHIDRA%M}"
    is_uint "$TIER_PHASE2_CEIL_MB" || TIER_PHASE2_CEIL_MB=512
    TIER_NOTES+=("Phase-2 ceiling inherits Ghidra's ${TIER_MAXMEM_GHIDRA} per v6 §5. Measured FLOSS peak (~1.46GB) exceeds it; FLOSS_MAX_MB=${FLOSS_MAX_MB:-64}MB is the interim guard. Re-derive once measured on this host.")

    # --- Tier C decompilation ----------------------------------------------------------
    if [[ $TIER == C && ${OPT[force_full_decompile]:-0} -eq 0 ]]; then
        if [[ ${OPT[light_decompile]:-0} -eq 0 ]]; then
            OPT[light_decompile]=1
            TIER_NOTES+=("Tier C: --light-decompile enabled automatically (v6 §5). --force-full-decompile overrides.")
        fi
    elif [[ $TIER == C ]]; then
        # The table's "light" is the Tier C *default*; the override changes it, so the
        # reported value must change too. Printing "light" next to a note saying full
        # decompilation is running is the kind of small contradiction that costs an hour.
        TIER_DECOMPILE="full"
        TIER_NOTES+=("Tier C with --force-full-decompile: full Ghidra at -P 1 / MAXMEM=${TIER_MAXMEM_GHIDRA}. Accepted risk.")
    fi

    # --- Explicit overrides always win (v6 §5) -----------------------------------------
    tier_apply_override jobs_light   TIER_JOBS_LIGHT
    tier_apply_override jobs_ghidra  TIER_JOBS_GHIDRA
    if [[ -n ${OPT[maxmem_ghidra]:-} ]]; then
        TIER_MAXMEM_GHIDRA="${OPT[maxmem_ghidra]}"
        TIER_NOTES+=("Ghidra MAXMEM overridden to ${TIER_MAXMEM_GHIDRA} by --maxmem-ghidra.")
    fi
    return 0
}

# tier_apply_override <opt-key> <tier-var> — honour a non-empty numeric CLI/config value.
tier_apply_override() {
    local key="$1" var="$2" val="${OPT[$1]:-}"
    [[ -z $val ]] && return 0
    if ! is_uint "$val" || [[ $val -eq 0 ]]; then
        warn "--${key//_/-} expects a positive whole number (got '$val'); keeping the tier default"
        return 0
    fi
    printf -v "$var" '%s' "$val"
    TIER_NOTES+=("${key//_/-} overridden to $val.")
    return 0
}

# --------------------------------------------------------------------------------------
# tier_report — the resolved plan. Used by --dry-run and by --verbose.
# --------------------------------------------------------------------------------------
tier_report() {
    local n
    printf 'Hardware\n'
    if [[ $TIER_RAM_MB -gt 0 ]]; then
        printf '  RAM detected  : %sMB (via %s)\n' "$TIER_RAM_MB" "$TIER_RAM_SOURCE"
    else
        printf '  RAM detected  : could not be determined\n'
    fi
    printf '  CPUs          : %s\n' "$(nproc 2>/dev/null || printf 'unknown')"
    local swp
    swp="$(swapon --show=SIZE --noheadings 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    printf '  Swap          : %s\n' "${swp:-none active}"
    printf '  Tier          : %s  (A >= %sMB, B >= %sMB, C below)\n' \
        "$TIER" "$TIER_A_MIN_MB" "$TIER_B_MIN_MB"
    printf '\nResolved limits\n'
    printf '  Phase-1 jobs  : %s\n' "$TIER_JOBS_LIGHT"
    printf '  radare2 cap   : %sMB\n' "$TIER_R2_CEIL_MB"
    printf '  Phase-2/3 jobs: %s\n' "$TIER_JOBS_GHIDRA"
    printf '  Ghidra MAXMEM : %s  (plus -XX:MaxRAMPercentage=%s)\n' \
        "$TIER_MAXMEM_GHIDRA" "$TIER_JVM_RAM_PCT"
    printf '  Phase-2 cap   : %sMB\n' "$TIER_PHASE2_CEIL_MB"
    printf '  Decompilation : %s\n' "$TIER_DECOMPILE"
    printf '  Watchdog      : kills the job tree above %s%% of RAM\n' "$TIER_WATCHDOG_PCT"
    if [[ ${#TIER_NOTES[@]} -gt 0 ]]; then
        printf '\nNotes\n'
        for n in "${TIER_NOTES[@]}"; do printf '  - %s\n' "$n"; done
    fi
    return 0
}
