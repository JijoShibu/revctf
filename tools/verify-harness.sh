#!/usr/bin/env bash
#
# verify-harness.sh — mutation testing for tools/run-tests.sh.
#
# WHY THIS EXISTS
# ---------------
# The verification harness is the only thing standing between this project and a
# milestone that is "done" because a flag parses. It has been wrong before: FIVE checks
# in M5 turned out to pass without ever executing the behaviour they named, and the
# `ghidra` section reported 3/0 while the stage produced an empty capture — `v0.3-m5`
# was tagged against that.
#
# A green harness is evidence only if a broken product turns it red. This script proves
# that mechanically: it breaks the product on purpose, in ways whose consequences are
# known, and asserts the named checks flip from PASS to FAIL. Anything that stays green
# under a mutation is a check that does not check.
#
# It is deliberately paranoid about restoring the tree — every mutated file is snapshotted
# before the edit, restored on any exit path including a signal, and compared byte for
# byte afterwards.
#
#   ./tools/verify-harness.sh                    # every mutation
#   ./tools/verify-harness.sh flag_tiers         # one
#   ./tools/verify-harness.sh --list             # what is available
#   VH_FAST=0 ./tools/verify-harness.sh          # include the 220MB checks (much slower)
#
# Per v5 §4.1 this file must not enable `set -e`: a mutation run that dies half way
# through would leave the working tree broken.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$ROOT/tools/run-tests.sh"
WORK="${TMPDIR:-/tmp}/revctf-verify-harness.$$"
BACKUP="$WORK/backup"

# The 220MB stress checks contribute nothing to any mutation here and cost ~12 minutes
# per harness invocation, and this script invokes the harness once per mutation plus
# twice more. Default to skipping them; VH_FAST=0 opts back in.
# Coerced deliberately: VH_FAST is user input, and CLAUDE.md §2 forbids letting an
# externally-supplied value reach an arithmetic test — under `set -u` a non-numeric word
# in `[[ $x -eq 1 ]]` is read as a variable name and exits the shell outright.
case "${VH_FAST:-1}" in 0) VH_FAST_ON=0 ;; *) VH_FAST_ON=1 ;; esac
export REVCTF_TEST_FAST="$VH_FAST_ON"

VPASS=0; VFAIL=0
declare -a VFAILURES=()

vok()   { printf '  \033[32mOK  \033[0m  %s\n' "$1"; VPASS=$((VPASS+1)); }
vno()   { printf '  \033[31mBAD \033[0m  %s\n         %s\n' "$1" "$2"
          VFAIL=$((VFAIL+1)); VFAILURES+=("$1"); }
vhead() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
vinfo() { printf '  ..    %s\n' "$1"; }

# ======================================================================================
# The mutation registry
# ======================================================================================
# Adding a mutation is two case branches. Keep it that way: the value of this script is
# that a new known-breakage is cheap to encode, so the next person who fixes a vacuous
# check can pin it here in the same commit.
#
# Each mutation declares:
#   M_DESC      one line, what is being broken
#   M_FILES     files it edits, repo-relative (snapshotted and restored)
#   M_SECTIONS  harness sections that must go RED
#   M_GREEN     harness sections that must STAY GREEN (may be empty)
#   M_EXPECT    the checks that must flip, one per element, as
#                   <pass-desc-ere>  =>  <fail-desc-ere>
#               The harness names a check differently when it passes and when it fails
#               (ok "the ghidra stage completes" / no "ghidra stage status"), so both
#               halves are needed. Where they are identical, write the regex once.
#
# Both halves matter. The pass side is asserted against the BASELINE run, which is what
# rules out the failure mode this script exists to catch: a check that is skipped, or
# absent, cannot be credited with detecting anything.

MUTATIONS=(ghidra_script flag_tiers tier_ceiling dyn_bypass kill_conflation)

mutation_meta() {
    M_DESC=""; M_FILES=(); M_SECTIONS=(); M_GREEN=(); M_EXPECT=()
    case "$1" in
    ghidra_script)
        M_DESC="the Ghidra post-script no longer parses (SyntaxError at load)"
        M_FILES=(scripts/jython_decompile.py scripts/pyghidra_decompile.py)
        M_SECTIONS=(ghidra)
        M_EXPECT=(
            "the ghidra stage completes \(status ok\)  =>  ghidra stage status"
            "the ghidra stage produced a non-empty capture  =>  ghidra capture"
            "the decompile recovers the crackme's password  =>  ghidra decompile content"
            "and it reaches the report under the ghidra stage  =>  ghidra -> report"
        )
        ;;
    flag_tiers)
        M_DESC="every flag regex tier is gutted (the scanner can match nothing)"
        M_FILES=(lib/flagscan.sh)
        M_SECTIONS=(m2 m3 m4)
        M_EXPECT=(
            "flag recovered from planted_flag"
            "flag recovered from b64_flag"
            "flag recovered from rot13_flag"
            "flag recovered from hex_flag"
            "base64 flag is credited to the decoding sweep"
            "hex flag is credited to the decoding sweep"
            "the .pyc flag is recovered"
            "high-confidence flags are listed first  =>  flag ordering"
            "the corpus flag reaches the report"
        )
        # NOT expected to flip: "unwrapping reveals a flag that was hidden while packed".
        # It greps the STRINGS CAPTURE after Stage 0 unwraps a UPX binary, so it is a check
        # about unwrapping and has nothing to do with the flag scanner. It was listed here
        # on a first pass and stayed green, correctly — the expectation was wrong, not the
        # check. Recorded rather than deleted: the next person to look at this list should
        # not have to re-derive why that check is absent from it.
        ;;
    tier_ceiling)
        M_DESC="tier_ceiling_for_stage() returns 0 for every stage (no ceiling reaches any tool)"
        M_FILES=(lib/tier.sh)
        M_SECTIONS=(m5enforce)
        # m5 checks tier RESOLUTION — the numbers being computed and printed. This
        # mutation leaves all of that intact and destroys only enforcement, so m5 staying
        # green while m5enforce goes red is not incidental: it is the reported-versus-
        # enforced distinction the two sections were split to express, demonstrated.
        M_GREEN=(m5)
        M_EXPECT=(
            "Tier A: radare2 is bounded at its tier ceiling"
            "Tier A: a Phase-2 stage is bounded at the Phase-2 ceiling"
            "Tier C: the same stage gets a DIFFERENT, smaller ceiling"
            "Tier C: Phase-2 ceiling drops with the tier"
        )
        ;;
    dyn_bypass)
        M_DESC="dyn_run launches its tracer directly again, bypassing st_run_bounded"
        M_FILES=(lib/stage_dynamic.sh)
        M_SECTIONS=(m5enforce)
        # This is the REAL regression, restored. lib/stage_dynamic.sh ran its own
        # `setsid timeout ... &` for the whole of M5, so st_mem_prefix never fired and the
        # ceiling tier_ceiling_for_stage returns for the executing stages was reported by
        # --verbose and enforced by nothing. It survived because m5enforce hardcoded radare2
        # and floss. m5enforce now DERIVES its stage list from the plan; this mutation is
        # what proves that derivation is not itself vacuous — if the harness stays green
        # here, the replacement check is exactly as worthless as the one it replaced.
        M_EXPECT=(
            "  ltrace is actually bounded  =>  ltrace reports a ceiling but is not bound by it"
            "  strace is actually bounded  =>  strace reports a ceiling but is not bound by it"
        )
        ;;
    kill_conflation)
        M_DESC="st_explain_kill() reports a SIGKILL as a timeout again"
        M_FILES=(lib/stage.sh)
        M_SECTIONS=(m5enforce)
        # The other half of the same defect. The grep ban in the qa section stops a NEW
        # `124|137)` branch from appearing, but it cannot see a wrong answer inside the one
        # function that is allowed to give one. Only behaviour can.
        M_EXPECT=(
            "a stage killed at its ceiling is reported as killed, not timed out"
            "and is NOT mislabelled with the time bound"
            "  floss is actually bounded  =>  floss reports a ceiling but is not bound by it"
        )
        ;;
    *)  return 1 ;;
    esac
    return 0
}

# mutation_apply <name> — edit the working tree. Runs after the snapshot, never before.
mutation_apply() {
    case "$1" in
    ghidra_script)
        # Appended, not substituted, so it breaks the file for any Ghidra runtime and
        # cannot be mistaken for a plausible edit. Both post-scripts are hit because
        # which one runs depends on the installed Ghidra's shipped feature directory.
        local f
        for f in scripts/jython_decompile.py scripts/pyghidra_decompile.py; do
            printf '\ndef ( mutation: deliberate SyntaxError\n' >> "$ROOT/$f"
        done
        ;;
    flag_tiers)
        # ALL THREE TIERS, and the first version of this mutation got that wrong.
        #
        # It gutted only _FLAG_BRACED, on the theory that the wrapper pattern is what finds
        # a flag. But _FLAG_GENERIC is `[A-Za-z0-9_]{2,}\{[^}]{1,200}\}`, which matches
        # `flag{...}` perfectly well — so the flag was still recovered, at low confidence
        # instead of high, and three checks stayed green. They were RIGHT to stay green: the
        # product still found the flag. The mutation was not the breakage it claimed to be.
        #
        # That distinction is worth more than the fix. "A check stayed green" means either
        # the check is vacuous or the mutation is weaker than advertised, and assuming the
        # first would have "fixed" three checks that were never broken.
        #
        # Anchored so no version can match: `$^` cannot be satisfied by any input.
        # `#` as the delimiter, not `|`: the alternation below contains `|`, which silently
        # turns "unknown option to `s'" into a mutation that edits nothing.
        sed -i -E "s#^(_FLAG_BRACED|_FLAG_HASHLIKE|_FLAG_GENERIC)=.*#\1='\$^MUTATION_NEVER_MATCHES'#" \
            "$ROOT/lib/flagscan.sh"
        ;;
    tier_ceiling)
        # Collapse the dispatch to the unbounded case. 0 is a meaningful value here — the
        # function documents it as "not bounded" — so this is the most plausible-looking
        # regression the function has, and the one a reviewer would least likely spot.
        perl -0pi -e 's/^tier_ceiling_for_stage\(\) \{\n.*?\n\}\n/tier_ceiling_for_stage() {\n    printf %s "0"\n    return 0\n}\n/ms' \
            "$ROOT/lib/tier.sh"
        ;;
    dyn_bypass)
        # A faithful revert of the bypass and nothing else: `-o` stays, so the trace is
        # still captured and only the BOUNDING is removed. A mutation that broke two things
        # at once could not tell us which check caught which.
        awk '
            /^    # shellcheck disable=SC2034  # read by st_run_bounded/ { skip=1 }
            skip && /^    pgid="\$ST_LAST_PGID"$/ {
                print "    setsid timeout -k 5 \"$tmo\" \"$@\" >\"$out\" 2>\"$err\" </dev/null &"
                print "    ST_CHILD_PID=$!"
                print "    pgid=$ST_CHILD_PID"
                print "    wait \"$ST_CHILD_PID\" || rc=$?"
                print "    ST_CHILD_PID=\"\""
                skip=0; next
            }
            !skip
        ' "$ROOT/lib/stage_dynamic.sh" > "$WORK/dyn.mut" \
          && mv -f "$WORK/dyn.mut" "$ROOT/lib/stage_dynamic.sh"
        ;;
    kill_conflation)
        # Fold 137 back into the 124 branch — exactly the shape the six converted stages
        # carried before st_explain_kill was extracted.
        # shellcheck disable=SC2016  # the $rc is target source text, not an expansion here
        sed -i 's/^    if \[\[ \$rc -eq 124 \]\]; then$/    if [[ $rc -eq 124 || $rc -eq 137 ]]; then/' \
            "$ROOT/lib/stage.sh"
        ;;
    *)  return 1 ;;
    esac
    return 0
}

# ======================================================================================
# Snapshot and restore
# ======================================================================================
# The single most dangerous thing this script does is edit source files. Everything below
# assumes the process can die at any moment.
declare -a SNAPPED=()

snapshot() {
    local f
    for f in "$@"; do
        if [[ ! -f $ROOT/$f ]]; then
            vno "snapshot" "$f does not exist — mutation registry is out of date"
            return 1
        fi
        mkdir -p "$BACKUP/$(dirname -- "$f")"
        cp -p -- "$ROOT/$f" "$BACKUP/$f" || return 1
        SNAPPED+=("$f")
    done
    return 0
}

# Restores every snapshotted file and PROVES it, rather than assuming cp worked. A silent
# restore failure would leave a mutation in the tree and the next commit would ship it.
restore_all() {
    local f rc=0
    for f in "${SNAPPED[@]}"; do
        [[ -f $BACKUP/$f ]] || continue
        cp -p -- "$BACKUP/$f" "$ROOT/$f" || rc=1
        cmp -s -- "$BACKUP/$f" "$ROOT/$f" || rc=1
    done
    return $rc
}

cleanup() {
    local rc=$?
    if [[ ${#SNAPPED[@]} -gt 0 ]]; then
        if restore_all; then
            printf '\n  tree restored (%d file(s))\n' "${#SNAPPED[@]}" >&2
        else
            printf '\n\033[31mRESTORE FAILED\033[0m — snapshots are in %s\n' "$BACKUP" >&2
            printf 'Run: git -C %s checkout -- %s\n' "$ROOT" "${SNAPPED[*]}" >&2
            exit 1
        fi
    fi
    rm -rf "$WORK"
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ======================================================================================
# Running and parsing the harness
# ======================================================================================
# Results are written as  <status><TAB><desc>  so a mutation's expectations can be
# matched against descriptions without re-reading the log's colour codes.
# run_harness <outfile> <section...>
run_harness() {
    local out="$1"; shift
    local log="$out.log"
    "$HARNESS" "$@" > "$log" 2>&1
    sed -e 's/\x1b\[[0-9;]*m//g' "$log" | sed -n \
        -e 's/^  PASS  /PASS\t/p' \
        -e 's/^  FAIL  /FAIL\t/p' \
        -e 's/^  SKIP  /SKIP\t/p' > "$out"
    return 0
}

count_of() { grep -c "^$1	" "$2" 2>/dev/null || true; }

# has_result <status> <ere> <resultfile>
has_result() {
    sed -n "s/^$1	//p" "$3" 2>/dev/null | grep -qE -- "$2"
}

# ======================================================================================
main() {
    if [[ ${1:-} == --list ]]; then
        local m
        for m in "${MUTATIONS[@]}"; do
            mutation_meta "$m"
            printf '  %-16s %s\n' "$m" "$M_DESC"
        done
        return 0
    fi

    local -a want=("$@")
    [[ ${#want[@]} -eq 0 ]] && want=("${MUTATIONS[@]}")

    local m
    for m in "${want[@]}"; do
        if ! mutation_meta "$m"; then
            printf 'unknown mutation: %s (try --list)\n' "$m" >&2
            return 1
        fi
    done

    mkdir -p "$BACKUP"
    printf '\033[1mrevctf harness mutation testing\033[0m\n'
    printf 'repo: %s\n' "$ROOT"
    printf 'mutations: %s\n' "${want[*]}"
    [[ $VH_FAST_ON == 1 ]] && \
        printf 'REVCTF_TEST_FAST=1 (220MB checks skipped; VH_FAST=0 to include them)\n'

    # --- the union of every section any selected mutation touches --------------------
    local -a union=()
    for m in "${want[@]}"; do
        mutation_meta "$m"
        union+=("${M_SECTIONS[@]}" "${M_GREEN[@]}")
    done
    mapfile -t union < <(printf '%s\n' "${union[@]}" | sort -u)

    # --- baseline --------------------------------------------------------------------
    # Everything downstream is measured against this. If the harness is not green here
    # there is nothing to mutate: a check that is already failing cannot demonstrate that
    # it detects anything.
    vhead "baseline — the harness must be green before anything is broken"
    vinfo "sections: ${union[*]}"
    local base="$WORK/baseline.res"
    run_harness "$base" "${union[@]}"
    local bp bf bs
    bp=$(count_of PASS "$base"); bf=$(count_of FAIL "$base"); bs=$(count_of SKIP "$base")
    if [[ ${bf:-1} -eq 0 ]]; then
        vok "baseline green: $bp passed, $bs skipped"
    else
        vno "baseline is not green" "$bf failing check(s) — see $base.log; fix those first"
        printf '\n'; sed -n 's/^FAIL\t/  - /p' "$base"
        return 1
    fi
    if [[ ${bs:-0} -gt 0 ]]; then
        vinfo "skipped in baseline (cannot be credited with detecting anything):"
        sed -n 's/^SKIP\t/         - /p' "$base"
    fi

    # --- one mutation at a time ------------------------------------------------------
    for m in "${want[@]}"; do
        mutation_meta "$m"
        vhead "mutation: $m"
        vinfo "$M_DESC"
        vinfo "files: ${M_FILES[*]}"

        SNAPPED=()
        if ! snapshot "${M_FILES[@]}"; then
            vno "$m" "could not snapshot its files; mutation not applied"
            continue
        fi
        if ! mutation_apply "$m"; then
            vno "$m" "mutation_apply failed"
            restore_all; SNAPPED=(); continue
        fi
        # A mutation that changes nothing would make every assertion below meaningless.
        local changed=0 f
        for f in "${M_FILES[@]}"; do
            cmp -s -- "$BACKUP/$f" "$ROOT/$f" || changed=1
        done
        if [[ $changed -eq 0 ]]; then
            vno "$m: mutation had no effect" "the edit matched nothing — the registry is stale"
            restore_all; SNAPPED=(); continue
        fi
        vok "$m: mutation applied and the files differ"

        local res="$WORK/$m.res"
        run_harness "$res" "${M_SECTIONS[@]}"
        local mf; mf=$(count_of FAIL "$res")
        if [[ ${mf:-0} -gt 0 ]]; then
            vok "$m: sections ${M_SECTIONS[*]} went RED ($mf failing)"
        else
            vno "$m: the harness stayed GREEN" \
                "a product this broken produced no failure in ${M_SECTIONS[*]}"
        fi

        # The mechanical part: named checks, both halves.
        local spec passre failre
        for spec in "${M_EXPECT[@]}"; do
            if [[ $spec == *"  =>  "* ]]; then
                passre="${spec%%"  =>  "*}"; failre="${spec##*"  =>  "}"
            else
                passre="$spec"; failre="$spec"
            fi
            if ! has_result PASS "$passre" "$base"; then
                if has_result SKIP "$passre" "$base"; then
                    vno "$m: /$passre/ was SKIPPED in the baseline" \
                        "a skipped check detects nothing — it must not be counted as coverage"
                else
                    vno "$m: /$passre/ is not in the baseline at all" \
                        "no such check ran; the expectation names a check that does not exist"
                fi
                continue
            fi
            if has_result FAIL "$failre" "$res"; then
                vok "$m: /$failre/ flipped PASS -> FAIL"
            else
                vno "$m: /$failre/ stayed green under the mutation" \
                    "this check does not detect the breakage it appears to cover — see $res.log"
            fi
        done

        # Sections that must be UNAFFECTED. Run separately so attribution is unambiguous.
        if [[ ${#M_GREEN[@]} -gt 0 ]]; then
            local gres="$WORK/$m.green.res"
            run_harness "$gres" "${M_GREEN[@]}"
            local gf; gf=$(count_of FAIL "$gres")
            if [[ ${gf:-1} -eq 0 ]]; then
                vok "$m: ${M_GREEN[*]} correctly unaffected"
            else
                vno "$m: ${M_GREEN[*]} went red too" \
                    "$gf failure(s); the sections are not testing what they claim to separate"
            fi
        fi

        if restore_all; then
            vok "$m: tree restored byte-identical"
        else
            vno "$m: RESTORE FAILED" "snapshots are in $BACKUP — do not commit"
            return 1
        fi
        SNAPPED=()
    done

    # --- and green again --------------------------------------------------------------
    # Restoring is asserted per mutation by cmp, but that only proves the bytes came back.
    # This proves the harness agrees, which is the claim that matters: nothing in the run
    # left a stray fixture, project or report directory behind that the next run trips on.
    vhead "restored — the harness must be green again"
    local final="$WORK/final.res"
    run_harness "$final" "${union[@]}"
    local ff; ff=$(count_of FAIL "$final")
    if [[ ${ff:-1} -eq 0 ]]; then
        vok "restored tree is green: $(count_of PASS "$final") passed"
    else
        vno "restored tree is NOT green" "$ff failing — see $final.log"
        sed -n 's/^FAIL\t/  - /p' "$final"
    fi

    printf '\n\033[1m%d ok, %d bad\033[0m\n' "$VPASS" "$VFAIL"
    if [[ $VFAIL -gt 0 ]]; then
        printf 'bad:\n'; printf '  - %s\n' "${VFAILURES[@]}"
        return 1
    fi
    printf 'Every mutation was detected by the check that names it.\n'
    return 0
}

main "$@"
