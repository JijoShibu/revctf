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
# Phase-2 ceiling — measured, NOT derived from Ghidra's (M5, deviation D11)
# --------------------------------------------------------------------------------------
# v6 §5 sized Phase 2 from the tier's Ghidra MAXMEM, arguing it made Phase 2's worst case
# identical to Phase 3's. M3 measurement disproved the premise: FLOSS peaked at ~1.46GB on
# a 220MB target, above Tier A's 1024M and roughly 3x Tier C's.
#
# These numbers are DERIVED FROM MEASUREMENT, not from v6 §5. Measured on the target Kali
# VM (getrusage, exact peaks — full table in docs/implementation-notes.md "M5 — host
# measurements"). If you move one, re-measure and update that section in the same commit.
#
#   FLOSS, 264KB PE, --only static      100MB
#   FLOSS, 264KB PE, --only stack       864MB
#   FLOSS, 264KB PE, all modes          899MB
#   FLOSS, 210MB blob, all modes       1460MB   (revctf skips this: FLOSS_MAX_MB)
#
# THE MEASUREMENT THAT SHAPED THE TABLE: FLOSS's peak is driven by vivisect's emulation
# workspace, not by input size. A 264KB PE — 250x under the FLOSS_MAX_MB=64MB gate — still
# costs ~900MB the moment any emulation mode runs. So FLOSS_MAX_MB does NOT keep FLOSS
# "comfortably inside every tier" as its comment claimed; only a real enforced ceiling does.
#
# Sized against each tier's worst-case usable RAM, using v3 §8's overhead derivation
# (RAM - 800MB XFCE - 50MB bash - 300MB Docker), evaluated at the tier's MINIMUM RAM:
#
#   Tier A   min 3891MB -> 2741MB usable   ceiling 1536MB (56%)  covers every measured case
#   Tier B   min 2560MB -> 1410MB usable   ceiling 1024MB (73%)  covers PE emulation (~900MB)
#   Tier C       2048MB ->  898MB usable   ceiling  512MB (57%)  emulation cannot fit at all
#
# Tier C therefore runs FLOSS in static-only mode (see stage_floss.sh), the same degrade-
# rather-than-fail pattern the tier already applies to Ghidra. Without that, a Tier C host
# would OOM-kill the FLOSS stage on every single PE — a ceiling that guarantees a failure
# is worse than no ceiling.
TIER_A_PHASE2_MB="${TIER_A_PHASE2_MB:-1536}"
TIER_B_PHASE2_MB="${TIER_B_PHASE2_MB:-1024}"
TIER_C_PHASE2_MB="${TIER_C_PHASE2_MB:-512}"

# Below this ceiling, FLOSS's emulation modes cannot fit and the stage runs static-only.
# 900MB is the measured cost of emulation on a small PE; the check is `ceiling < this`.
TIER_FLOSS_EMULATION_MB="${TIER_FLOSS_EMULATION_MB:-900}"

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
# The validated REVCTF_CEIL_MB, or empty. Resolved ONCE in tier_resolve so the value is
# validated and announced in exactly one place; tier_ceiling_for_stage reads it and never
# touches the environment itself. Reading $REVCTF_CEIL_MB directly per call was how it could
# take effect without ever appearing in the report.
declare -g TIER_CEIL_OVERRIDE=""
# shellcheck disable=SC2034  # read by lib/stage_floss.sh, which sources this file
declare -g TIER_FLOSS_STATIC_ONLY=0
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

    # REVCTF_CEIL_MB gets the SAME treatment as REVCTF_RAM_MB, for the same reason.
    #
    # REVCTF_RAM_MB was deliberately built to label itself in every report so that a tier
    # chosen from a fake number could never be mistaken for a measurement. A ceiling override
    # is strictly more dangerous: a stray REVCTF_CEIL_MB=1 in the environment caps every
    # bounded stage at 1MB, SIGKILLs each of them, and the report would otherwise show a row
    # of failed stages with nothing anywhere saying the cause was an environment variable.
    # An override that does not announce itself is indistinguishable from a broken host.
    if [[ -n ${REVCTF_CEIL_MB:-} ]]; then
        if is_uint "$REVCTF_CEIL_MB"; then
            TIER_CEIL_OVERRIDE="$REVCTF_CEIL_MB"
            TIER_NOTES+=("Every stage memory ceiling was INJECTED via REVCTF_CEIL_MB (${REVCTF_CEIL_MB}MB), replacing this tier's values. This is a TEST HOOK — any stage killed in this run was stopped by it, not by your host.")
        else
            TIER_CEIL_OVERRIDE=""
            warn "REVCTF_CEIL_MB is not a whole number ('$REVCTF_CEIL_MB'); using the tier's ceilings"
            TIER_NOTES+=("REVCTF_CEIL_MB was set to '$REVCTF_CEIL_MB', which is not a whole number; it was ignored and the tier's own ceilings apply.")
        fi
    else
        TIER_CEIL_OVERRIDE=""
    fi

    # --- Phase-2 ceiling (deviation D11) -----------------------------------------------
    # No longer inherited from Ghidra's MAXMEM. v6 §5's derivation is struck: it assumed
    # Phase 2's worst case was bounded by Phase 3's, and the measured FLOSS peak (~1.46GB,
    # above Tier A's 1024M and ~3x Tier C's) disproved that. Phase 2 is now sized from its
    # own measurement — see the constants at the top of this file.
    case "$TIER" in
        A) TIER_PHASE2_CEIL_MB="$TIER_A_PHASE2_MB" ;;
        B) TIER_PHASE2_CEIL_MB="$TIER_B_PHASE2_MB" ;;
        *) TIER_PHASE2_CEIL_MB="$TIER_C_PHASE2_MB" ;;
    esac
    # The coercion below is the QA-1 rule (nothing non-numeric may reach arithmetic
    # context), but it must not double as a silent repair. A bare `|| =512` here meant an
    # unusable constant resolved to Tier C's ceiling on every tier — a Tier A host running
    # Phase 2 at a third of its budget, with nothing on screen to say so. That is the same
    # class of defect as the derivation D11 removed: a number that is wrong and quiet.
    if ! is_uint "$TIER_PHASE2_CEIL_MB"; then
        warn "Phase-2 ceiling for Tier $TIER is not a whole number ('$TIER_PHASE2_CEIL_MB'); falling back to 512MB"
        TIER_NOTES+=("Phase-2 ceiling constant for Tier $TIER is unusable ('$TIER_PHASE2_CEIL_MB'); using 512MB. This is a build error, not a tuning decision — see TIER_*_PHASE2_MB in lib/tier.sh.")
        TIER_PHASE2_CEIL_MB=512
    fi

    # --- FLOSS emulation affordability (M5, measured) ----------------------------------
    # Not a preference: FLOSS's emulation modes cost ~900MB on even a 264KB PE, because the
    # cost is vivisect's workspace rather than the input. Where the tier's Phase-2 ceiling
    # cannot cover that, running them means a guaranteed OOM kill, so the stage degrades to
    # static-only instead — the same choice Tier C already makes for Ghidra.
    # shellcheck disable=SC2034  # read by stage_floss() in lib/stage_floss.sh; shellcheck
    # cannot follow the entry script's `source` loop across files.
    TIER_FLOSS_STATIC_ONLY=0
    if [[ $TIER_PHASE2_CEIL_MB -lt $TIER_FLOSS_EMULATION_MB ]]; then
        # shellcheck disable=SC2034  # same cross-file consumer as above
        TIER_FLOSS_STATIC_ONLY=1
        TIER_NOTES+=("Tier $TIER: FLOSS runs static-only. Its stack/tight/decoded emulation needs ~900MB regardless of file size (measured on a 264KB PE), which does not fit this tier's ${TIER_PHASE2_CEIL_MB}MB Phase-2 ceiling. Static strings still run.")
    fi

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

    # --- Low RAM with no swap: a diagnostic, not an action -----------------------------
    # v4 §3 and v5 §3.1 specified auto-creating a 1-2GB swap file here. That was removed
    # (deviation D10): writing a swap file and touching /etc/fstab is a system
    # administration action, and revctf's job is to read a binary and write a report. The
    # failure it guarded against is real — Ghidra OOM-killed on a small host — but the
    # honest response is to name it and let the user decide, which is one sentence rather
    # than a subsystem, an opt-out flag and a privileged write.
    if [[ $TIER != A && $TIER_RAM_MB -gt 0 ]]; then
        local swap_kb=0
        # REVCTF_SWAP_MB exists for the same reason as REVCTF_RAM_MB, and with the same
        # limits: it makes the BRANCH testable on any machine. The diagnostic below only
        # fires on a host with no swap, so on a developer box that has some, the check
        # asserting it silently passed by never running — the branch was untested for the
        # whole of M5's groundwork. Injecting the figure fixes that; it proves nothing
        # about behaviour on a host that really has no swap.
        if [[ -n ${REVCTF_SWAP_MB:-} ]] && is_uint "${REVCTF_SWAP_MB:-}"; then
            swap_kb=$(( REVCTF_SWAP_MB * 1024 ))
        elif [[ -r /proc/meminfo ]]; then
            swap_kb="$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
        fi
        is_uint "$swap_kb" || swap_kb=0
        if [[ $swap_kb -eq 0 ]]; then
            TIER_NOTES+=("Tier $TIER (${TIER_RAM_MB}MB) with no active swap. Ghidra may be OOM-killed on this host. Either run with --skip-ghidra (radare2 substitutes), or add swap yourself — revctf will not modify your system.")
        fi
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

# --------------------------------------------------------------------------------------
# tier_ceiling_for_stage <stage-name> — the memory ceiling that stage is held to, in MB.
# --------------------------------------------------------------------------------------
# This is the function that turns the tier TABLE into tier ENFORCEMENT. Before M5 the
# numbers were resolved, printed by --dry-run, and then ignored — the `[PARTIAL: M5]`
# marker on --jobs-*/--maxmem-ghidra.
#
# Prints 0 for a stage with no ceiling, and 0 is meaningful: it means "not bounded", not
# "bounded at zero". Only the stages v6 §5 actually assigns a number to get one —
#
#   radare2                          the tier's radare2 ceiling
#   strace/floss/managed/pydecomp    the Phase-2 ceiling (§7.2 Phase 2)
#   ghidra                           the tier's Ghidra MAXMEM (§7.2 Phase 3)
#
# The remaining Phase-1 stages (file, strings, binwalk, hexdump, checksec, objdump, ltrace,
# triage) are deliberately left unbounded. v6 §5 gives Phase 1 a concurrency but no
# per-job ceiling, and inventing one here would be the same unmeasured-constant mistake
# D11 exists to correct — the whole Phase-1 group was measured at ~103MB peak on a 220MB
# target, so there is nothing to bound. The global RSS watchdog is their backstop.
#
# ltrace joins strace here as of 2026-08-21. They are the two stages that EXECUTE the
# target, so they are the two where a hostile binary can allocate without bound — and
# strace carried the Phase-2 ceiling while ltrace, doing the identical thing, carried none.
# That is the same asymmetry deviation D9 corrected for --sandbox (v5 §3 scoped the sandbox
# to ltrace only, predating strace), just pointing the other way. Bounding one executing
# stage and not the other is not a defensible position in either direction.
tier_ceiling_for_stage() {
    local mb
    case "${1:-}" in
        radare2)                                printf -v mb '%s' "$TIER_R2_CEIL_MB" ;;
        ltrace|strace|floss|managed|pydecomp)   printf -v mb '%s' "$TIER_PHASE2_CEIL_MB" ;;
        ghidra)                                 mb="$(tier_mb_of "$TIER_MAXMEM_GHIDRA")" ;;
        *)                                      mb=0 ;;
    esac

    # REVCTF_CEIL_MB — a test hook, and a deliberately narrow one. It OVERRIDES the value of
    # a ceiling that already exists; it never INVENTS one, so a stage the tier leaves
    # unbounded stays unbounded and the shape of the table cannot be altered by an
    # environment variable.
    #
    # It exists because enforcement can only be tested by breaching it, and breaching a
    # 512MB ceiling honestly means allocating 512MB. tools/run-tests.sh uses this to drive
    # every bounded stage into its ceiling in seconds, which is what lets the m5enforce
    # section DERIVE its stage list from this function instead of hardcoding two names —
    # the hardcoding is why dyn_run's bypass survived M5 unnoticed.
    #
    # TIER_CEIL_OVERRIDE, not $REVCTF_CEIL_MB: tier_resolve has already validated it and
    # added the "INJECTED via REVCTF_CEIL_MB" note, so the value cannot take effect without
    # the report saying that it did. Reading the environment here instead was the whole
    # defect — a silent cap with nothing on screen to explain the failures it causes.
    if [[ -n $TIER_CEIL_OVERRIDE && $mb -gt 0 ]]; then
        mb="$TIER_CEIL_OVERRIDE"
    fi

    printf '%s' "$mb"
    return 0
}

# tier_mb_of <value> — normalise a MAXMEM-style value ("1024M", "2G", "768") to whole MB.
#
# `--maxmem-ghidra` accepts a G suffix (validate_opts allows `^[0-9]+[MmGg]?$`), so a bare
# `${v%[MmGg]}` would read "2G" as 2MB — a 1000x under-bound that would look like a working
# limit while killing every Ghidra run instantly. Prints 0 for anything unparseable, which
# the callers treat as "unbounded" rather than "bounded at zero".
tier_mb_of() {
    local v="${1:-}" n="${1:-}"
    n="${n%[MmGg]}"
    is_uint "$n" || { printf '0'; return 0; }
    case "$v" in
        *[Gg]) printf '%s' $(( n * 1024 )) ;;
        *)     printf '%s' "$n" ;;
    esac
    return 0
}

# tier_stage_is_jvm <stage-name> — true when the stage launches a JVM.
#
# This exists because of a measured fact, not a stylistic preference. `ulimit -v` bounds
# ADDRESS SPACE, and a JVM reserves vastly more address space than it ever resides in:
# measured on this host, a hello-world `java` needs between 2GB and 4GB of virtual size to
# initialise at all, and fails with "Could not reserve enough space for object heap" under
# anything smaller. Applying the tier's 1024M/768M/512M Ghidra ceiling as `ulimit -v` would
# therefore make Ghidra fail 100% of the time on every host WITHOUT systemd — silently
# converting a memory bound into a total loss of the decompile stage.
#
# So on the ulimit fallback path a JVM stage is bounded by MAXMEM and
# -XX:MaxRAMPercentage only, which are heap bounds the JVM enforces itself, and the report
# says the bound is weaker there. Under systemd-run the ceiling is a real RSS limit and
# applies to Ghidra exactly like anything else.
tier_stage_is_jvm() { [[ ${1:-} == ghidra || ${1:-} == managed ]]; }

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

    # How the ceilings above are actually held. This line is the difference between a
    # number that is printed and a number that is enforced, so it says which mechanism is
    # in force rather than leaving the reader to assume the better one.
    local mode="unknown"
    declare -F st_mem_mode >/dev/null 2>&1 && mode="$(st_mem_mode)"
    [[ $mode == unknown && ${PF_SYSTEMD_RUN_USABLE:-0} -eq 1 ]] && mode="systemd"
    [[ $mode == unknown ]] && mode="ulimit"
    case "$mode" in
        systemd) printf '  Enforced by   : systemd-run --scope -p MemoryMax (real RSS limit)\n' ;;
        ulimit)  printf '  Enforced by   : ulimit -v (bounds virtual size, not RSS — weaker)\n'
                 printf '                  Ghidra is exempt: a JVM needs 2-4GB of virtual size to\n'
                 printf '                  start at all, so ulimit -v at these ceilings would stop it\n'
                 printf '                  running. It is held by MAXMEM + MaxRAMPercentage instead.\n' ;;
        *)       printf '  Enforced by   : nothing (memory bounding disabled)\n' ;;
    esac
    printf '  Watchdog      : kills the job tree above %s%% of RAM (%sMB)\n' \
        "$TIER_WATCHDOG_PCT" "$(( TIER_RAM_MB * TIER_WATCHDOG_PCT / 100 ))"
    if [[ ${#TIER_NOTES[@]} -gt 0 ]]; then
        printf '\nNotes\n'
        for n in "${TIER_NOTES[@]}"; do printf '  - %s\n' "$n"; done
    fi
    return 0
}
