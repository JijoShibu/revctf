#!/usr/bin/env bash
# lib/preflight.sh — dependency discovery, version detection, disk-space check.
#
# Implemented in: M1.
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`.
#
# Responsibilities (execution masterplan M1):
#   1. Verify the seven core tools are on PATH; hard-fail with an actionable message.
#   2. Verify the always-needed v6 tools (deviation D7); hard-fail pointing at install.sh.
#   3. Discover Ghidra: GHIDRA_HOME -> PATH -> /opt/ghidra* (deviation D12; v3 §5 step 2
#      put PATH first, which install.sh's symlink made GHIDRA_HOME unusable).
#   4. Detect Ghidra's generation (selects the M3 post-script) and binwalk's major
#      version (selects M2's parsing branch).
#   5. Check free disk space.
#
# Format-conditional tools (Java/.NET/Python decompilers, archive extractors) are NOT
# checked here — see pf_require_tool() and the note in §"Conditional tools" below.

# ======================================================================================
# Exported state
# ======================================================================================
# shellcheck disable=SC2034  # consumed by lib/stage_*.sh, which source this file
declare -gA PF_TOOL=()          # logical name -> resolved absolute path
declare -gA PF_VERSION=()       # logical name -> detected version string
declare -g  PF_GHIDRA_HEADLESS=""
declare -g  PF_GHIDRA_MAJOR=""
declare -g  PF_GHIDRA_SCRIPT_KIND=""   # pyghidra | jython
declare -g  PF_BINWALK_MAJOR=""
declare -g  PF_DISK_FREE_MB=0
declare -g  PF_SYSTEMD_RUN_USABLE=0
declare -g  PF_NOTICES=""              # newline-joined notes for the report

PF_MIN_DISK_MB="${PF_MIN_DISK_MB:-1024}"

# Where to scan for an unpacked Ghidra. Overridable so the verification harness can point
# discovery at a fixture tree instead of the real /opt (and so an unusual install root can
# be searched without setting GHIDRA_HOME).
PF_OPT_ROOT="${PF_OPT_ROOT:-/opt}"

# ======================================================================================
# Tool registry
# ======================================================================================
# Format:  <logical>|<command>|<full install command>|<why it is needed>
#
# The third field is a complete command, not a package name: FLOSS is a pip package that
# needs a venv on modern Debian/Ubuntu (see implementation-notes.md), so a bare
# "apt install <pkg>" template would print advice that does not work.
#
# CORE — the seven from v3 §1. revctf cannot run without these; a miss is a hard failure
# with an apt hint, per execution masterplan M1's DoD.
PF_CORE_TOOLS=(
    "file|file|apt install file|classifies the target and gates the dynamic stages"
    "strings|strings|apt install binutils|stage 2"
    "binwalk|binwalk|apt install binwalk|stage 3"
    "hexdump|hexdump|apt install bsdextrautils|stage 4"
    "ltrace|ltrace|apt install ltrace|stage 7 (library-call trace)"
    "radare2|radare2|apt install radare2|stage 8 (disassembly)"
    # ghidra is discovered separately — it is not a simple PATH lookup.
)

# ALWAYS — added by v6 deviation D2, needed on every run regardless of target format.
# Per D7 these are install.sh's responsibility and a miss is a hard error.
PF_ALWAYS_TOOLS=(
    "rabin2|rabin2|apt install radare2|stage 5 (binary metadata)"
    "checksec|checksec|apt install checksec|stage 5 (exploit mitigations)"
    "objdump|objdump|apt install binutils|stage 6"
    "readelf|readelf|apt install binutils|stage 6"
    "strace|strace|apt install strace|stage 9 (syscall trace)"
    "floss|floss|python3 -m venv /opt/floss-venv && /opt/floss-venv/bin/pip install flare-floss && ln -s /opt/floss-venv/bin/floss /usr/local/bin/floss|stage 10 (obfuscated strings)"
    "upx|upx|apt install upx-ucl|stage 0 triage (packer detection and unpacking)"
)

# CONDITIONAL — only required once Stage 0 routes a target to them. Checked lazily by
# pf_require_tool() at the point of use, NOT at startup.
#
# Judgement call, recorded in implementation-notes.md: deviation D7 makes a missing
# optional tool a hard error, and that is applied literally to PF_ALWAYS_TOOLS. Applying
# it to these as well would abort a scan of a plain ELF crackme because a .NET decompiler
# is absent, which is not what D7's "predictable runtime" intent was for. So these fail
# hard at the moment a target actually needs them, with the same "re-run install.sh"
# message.
declare -gA PF_CONDITIONAL_TOOLS=(
    [jd-cli]="apt install jd-cli|Java decompilation (stage 11)"
    [procyon]="apt install procyon-decompiler|Java decompilation fallback (stage 11)"
    [ilspycmd]="dotnet tool install -g ilspycmd|.NET decompilation (stage 11)"
    [monodis]="apt install mono-utils|.NET disassembly fallback (stage 11)"
    [pycdc]="build from https://github.com/zrax/pycdc|Python bytecode decompilation (stage 12)"
    [uncompyle6]="pip install uncompyle6|Python bytecode decompilation fallback (stage 12)"
    [7z]="apt install p7zip-full|archive extraction (stage 0 triage)"
    [unsquashfs]="apt install squashfs-tools|firmware extraction (stage 0 triage)"
)

# ======================================================================================
# Helpers
# ======================================================================================
pf_note() { PF_NOTICES+="${PF_NOTICES:+$'\n'}$1"; }

# pf_require_tool <logical name>
# Lazy hard-check for a conditional tool, called by the stage that needs it.
# Returns 0 if present; on absence prints the install hint and returns 1 so the caller
# can mark its stage failed and continue (v5 §4.1) rather than killing the run.
pf_require_tool() {
    local name="$1" path install why
    path=$(command -v "$name" 2>/dev/null) || path=""
    if [[ -n $path ]]; then
        PF_TOOL[$name]="$path"
        return 0
    fi
    IFS='|' read -r install why <<< "${PF_CONDITIONAL_TOOLS[$name]:-unknown|unknown}"
    printf 'revctf: %s is required for %s but was not found.\n' "$name" "$why" >&2
    printf 'revctf:   install it with: %s\n' "$install" >&2
    printf 'revctf:   (or re-run install.sh, which handles all of these)\n' >&2
    return 1
}

# ======================================================================================
# 1 + 2. PATH checks
# ======================================================================================
# pf_check_group <group-label> <install-advice> <entry>...
# Returns 0 if every entry resolved, 1 otherwise (after reporting all misses at once —
# reporting them one per run would mean N frustrating re-runs).
pf_check_group() {
    local label="$1" advice="$2"; shift 2
    local entry logical cmd install why path missing=0
    local -a misses=()

    for entry in "$@"; do
        IFS='|' read -r logical cmd install why <<< "$entry"
        path=$(command -v "$cmd" 2>/dev/null) || path=""
        if [[ -n $path ]]; then
            PF_TOOL[$logical]="$path"
        else
            misses+=("  $cmd  — $why"$'\n'"      install: $install")
            missing=1
        fi
    done

    if [[ $missing -eq 1 ]]; then
        printf 'revctf: missing %s:\n' "$label" >&2
        printf '%s\n' "${misses[@]}" >&2
        printf 'revctf: %s\n' "$advice" >&2
        return 1
    fi
    return 0
}

pf_check_core() {
    pf_check_group "required tools" \
        "revctf cannot run without these. Install them, then try again." \
        "${PF_CORE_TOOLS[@]}"
}

pf_check_always() {
    pf_check_group "tools installed by install.sh" \
        "these are set up by install.sh — re-run it (while online) and try again." \
        "${PF_ALWAYS_TOOLS[@]}"
}

# ======================================================================================
# 3. Ghidra discovery — GHIDRA_HOME, then PATH, then /opt/ghidra* (D12; v3 §5 reordered)
# ======================================================================================
pf_find_ghidra() {
    local candidate

    # (a) $GHIDRA_HOME — an EXPLICIT choice, so it wins (deviation D12).
    #
    # v3 §5 step 2 ordered this PATH -> GHIDRA_HOME -> /opt/ghidra*, and that was defensible
    # while nothing put analyzeHeadless on PATH. install.sh now always symlinks it into
    # /usr/local/bin, which made GHIDRA_HOME permanently dead on every machine where the
    # installer had run: you could export it, revctf would silently ignore it, and nothing
    # said so. An environment variable the user sets deliberately must beat an incidental
    # PATH entry the installer created.
    #
    # This is not hypothetical. Ghidra 12.x breaks the post-script (CLAUDE.md §3), and
    # pointing GHIDRA_HOME at a known-good 11.2.x install is exactly how someone works
    # around that — which the old order made impossible.
    if [[ -n ${GHIDRA_HOME:-} ]]; then
        for candidate in "$GHIDRA_HOME/support/analyzeHeadless" "$GHIDRA_HOME/analyzeHeadless"; do
            if [[ -x $candidate ]]; then
                PF_GHIDRA_HEADLESS="$candidate"
                return 0
            fi
        done
        pf_note "GHIDRA_HOME is set to '$GHIDRA_HOME' but no analyzeHeadless was found under it; falling back to PATH."
    fi

    # (b) analyzeHeadless on PATH
    if candidate=$(command -v analyzeHeadless 2>/dev/null); then
        PF_GHIDRA_HEADLESS="$candidate"
        return 0
    fi

    # (c) /opt/ghidra* — newest first, so a machine with several installs picks the
    #     most recent rather than whichever sorts first alphabetically.
    local -a found=()
    while IFS= read -r candidate; do
        [[ -x $candidate ]] && found+=("$candidate")
    done < <(find "$PF_OPT_ROOT" -maxdepth 3 -name analyzeHeadless -type f 2>/dev/null | sort -rV)

    if [[ ${#found[@]} -gt 0 ]]; then
        PF_GHIDRA_HEADLESS="${found[0]}"
        [[ ${#found[@]} -gt 1 ]] && \
            pf_note "Multiple Ghidra installs found under $PF_OPT_ROOT; using ${found[0]}"
        return 0
    fi

    printf 'revctf: Ghidra not found.\n' >&2
    # shellcheck disable=SC2016  # $GHIDRA_HOME is literal text in a help message
    printf 'revctf:   searched: PATH, $GHIDRA_HOME, %s/ghidra*/support/analyzeHeadless\n' "$PF_OPT_ROOT" >&2
    printf 'revctf:   set GHIDRA_HOME=/path/to/ghidra, or use --skip-ghidra to run without it\n' >&2
    return 1
}

# ======================================================================================
# 4. Version detection
# ======================================================================================
# Which runtime executes a .py post-script?
#
# v3 §1 says "11.x+ -> PyGhidra, 10.x and earlier -> Jython". That boundary is WRONG, and
# it was verified wrong against a real install: Ghidra 11.2.1 still bundles Jython and
# runs .py post-scripts under Jython 2.7.3 (probe output:
# `python_version=2.7.3 ... [OpenJDK 64-Bit Server VM]`). PyGhidra only became the bundled
# default in 11.3, where Jython was removed. Selecting by version alone would hand a
# Python-3 script to a Python-2 interpreter on 11.0-11.2 and die on the first f-string.
#
# So the install is probed for the runtime it actually ships, and the version comparison
# is only a fallback for an unrecognisable layout.
pf_detect_ghidra_runtime() {
    local root="$1"
    local has_py=0 has_jy=0
    [[ -d $root/Ghidra/Features/PyGhidra ]] && has_py=1
    [[ -d $root/Ghidra/Features/Jython   ]] && has_jy=1

    if [[ $has_py -eq 1 && $has_jy -eq 0 ]]; then
        PF_GHIDRA_SCRIPT_KIND="pyghidra"; return 0
    fi
    if [[ $has_jy -eq 1 && $has_py -eq 0 ]]; then
        PF_GHIDRA_SCRIPT_KIND="jython";   return 0
    fi
    if [[ $has_py -eq 1 && $has_jy -eq 1 ]]; then
        # Both present means PyGhidra was added to a Jython-era install deliberately.
        PF_GHIDRA_SCRIPT_KIND="pyghidra"
        pf_note "This Ghidra ships both PyGhidra and Jython; using the PyGhidra post-script. Override with --ghidra-script."
        return 0
    fi
    return 1   # neither found — caller falls back to the version comparison
}

# The version itself still gets detected: it goes in the report header, and it is the
# fallback runtime signal when the feature probe above finds nothing recognisable.
pf_detect_ghidra_version() {
    [[ -n $PF_GHIDRA_HEADLESS ]] || return 1

    local root props ver="" real
    # RESOLVE SYMLINKS FIRST. install.sh puts `analyzeHeadless` on PATH as a symlink
    # (/usr/local/bin/analyzeHeadless -> /opt/ghidra_X/support/analyzeHeadless), and
    # `dirname/..` on the *link* yields /usr/local — where there is no
    # application.properties and no Ghidra/Features. Both probes then fail and the
    # fallback assumes Jython.
    #
    # That is not cosmetic. Measured on this host: Ghidra 12.1.3 ships PyGhidra and no
    # Jython at all, so the Jython post-script would be handed to an install that cannot
    # run it — and per CLAUDE.md §3 that failure surfaces only as an EMPTY GHIDRA STAGE
    # THAT EXITS 0. A silent wrong answer, produced by our own installer's symlink.
    real="$(readlink -f -- "$PF_GHIDRA_HEADLESS" 2>/dev/null)"
    [[ -n $real && -e $real ]] || real="$PF_GHIDRA_HEADLESS"
    root="$(cd -- "$(dirname -- "$real")/.." && pwd)" || return 1

    for props in "$root/Ghidra/application.properties" "$root/application.properties"; do
        if [[ -r $props ]]; then
            ver=$(sed -n 's/^application\.version=\([0-9][0-9.]*\).*/\1/p' "$props" | head -1)
            [[ -n $ver ]] && break
        fi
    done

    # Fall back to parsing the install directory name, e.g. /opt/ghidra_11.1.2_PUBLIC
    if [[ -z $ver ]]; then
        ver=$(basename "$root" | sed -n 's/.*[_-]\([0-9][0-9]*\.[0-9][^_-]*\).*/\1/p')
    fi

    [[ -n $ver ]] && PF_VERSION[ghidra]="$ver"
    PF_GHIDRA_MAJOR="${ver%%.*}"
    [[ $PF_GHIDRA_MAJOR =~ ^[0-9]+$ ]] || PF_GHIDRA_MAJOR="unknown"

    # Preferred signal: what the install actually ships.
    pf_detect_ghidra_runtime "$root" && return 0

    # Fallback: version comparison, with the CORRECTED 11.3 boundary (see the comment on
    # pf_detect_ghidra_runtime — 11.0-11.2 are Jython, not PyGhidra).
    if [[ -z $ver ]]; then
        PF_GHIDRA_SCRIPT_KIND="jython"
        pf_note "Could not determine the Ghidra version or runtime; assuming Jython. Use --ghidra-script to override."
        return 0
    fi

    local major="${ver%%.*}" minor
    minor="${ver#*.}"; minor="${minor%%.*}"
    [[ $minor =~ ^[0-9]+$ ]] || minor=0
    if [[ $major =~ ^[0-9]+$ ]] && { [[ $major -gt 11 ]] || { [[ $major -eq 11 ]] && [[ $minor -ge 3 ]]; }; }; then
        PF_GHIDRA_SCRIPT_KIND="pyghidra"
    else
        PF_GHIDRA_SCRIPT_KIND="jython"
    fi
    pf_note "Ghidra $ver has no recognisable PyGhidra/Jython feature directory; selected the $PF_GHIDRA_SCRIPT_KIND post-script by version."
    return 0
}

# binwalk: numeric major-version comparison, never a literal "3." substring match —
# v3 §4 item 9 called this out specifically so a future binwalk 4.x does not silently
# fall through to the legacy parsing branch.
#
# Detection is awkward because the two generations disagree about how to be asked:
#   v3+ (Rust rewrite) supports --version
#   v2.x (Python)      rejects --version and prints "Binwalk v2.3.3" in its help banner
pf_detect_binwalk_version() {
    local out ver=""

    out=$(binwalk --version 2>/dev/null | head -1)
    [[ $out =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && ver="${BASH_REMATCH[1]}"

    if [[ -z $ver ]]; then
        out=$(binwalk -h 2>&1 | grep -iEm1 'binwalk +v?[0-9]')
        [[ $out =~ [Vv]?([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && ver="${BASH_REMATCH[1]}"
    fi

    if [[ -z $ver ]]; then
        ver=$(python3 -c 'import binwalk; print(binwalk.__version__)' 2>/dev/null)
    fi

    if [[ -z $ver ]]; then
        PF_BINWALK_MAJOR=0
        pf_note "Could not determine the binwalk version; using legacy output parsing with raw-capture fallback."
        return 0
    fi

    PF_VERSION[binwalk]="$ver"
    PF_BINWALK_MAJOR="${ver%%.*}"
    [[ $PF_BINWALK_MAJOR =~ ^[0-9]+$ ]] || PF_BINWALK_MAJOR=0
    return 0
}

# Best-effort versions for the report header. Never fatal — a tool that will not report
# its version still works.
pf_detect_tool_versions() {
    local out
    out=$(radare2 -v 2>/dev/null | head -1);  [[ $out =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && PF_VERSION[radare2]="${BASH_REMATCH[1]}"
    out=$(ltrace -V 2>/dev/null | head -1);   [[ $out =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && PF_VERSION[ltrace]="${BASH_REMATCH[1]}"
    out=$(strace -V 2>/dev/null | head -1);   [[ $out =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && PF_VERSION[strace]="${BASH_REMATCH[1]}"
    out=$(upx --version 2>/dev/null | head -1); [[ $out =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && PF_VERSION[upx]="${BASH_REMATCH[1]}"
    out=$(floss --version 2>/dev/null | head -1); [[ $out =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && PF_VERSION[floss]="${BASH_REMATCH[1]}"
    out=$(file -v 2>/dev/null | head -1);     [[ $out =~ ([0-9]+\.[0-9]+) ]] && PF_VERSION[file]="${BASH_REMATCH[1]}"
    out=$(objdump --version 2>/dev/null | head -1); [[ $out =~ ([0-9]+\.[0-9]+) ]] && PF_VERSION[objdump]="${BASH_REMATCH[1]}"
    out=$(checksec --version 2>&1 | head -1); [[ $out =~ v([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && PF_VERSION[checksec]="${BASH_REMATCH[1]}"
    return 0
}

# ======================================================================================
# 5. Disk space
# ======================================================================================
# v4 §5 also wants checks immediately before --full-hexdump and before each Ghidra
# project; this is the startup one. Reports in MB against the target output directory's
# filesystem, since that is where output actually lands.
pf_check_disk() {
    local where="${1:-.}" avail_kb
    while [[ ! -d $where && $where != "/" && $where != "." ]]; do
        where="$(dirname "$where")"
    done

    avail_kb=$(df -Pk "$where" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z $avail_kb || ! $avail_kb =~ ^[0-9]+$ ]]; then
        pf_note "Could not determine free disk space for '$where'; continuing without the check."
        return 0
    fi

    PF_DISK_FREE_MB=$(( avail_kb / 1024 ))
    if [[ $PF_DISK_FREE_MB -lt $PF_MIN_DISK_MB ]]; then
        printf 'revctf: only %dMB free on the filesystem holding %s (need at least %dMB).\n' \
            "$PF_DISK_FREE_MB" "$where" "$PF_MIN_DISK_MB" >&2
        printf 'revctf:   Ghidra projects and full hexdumps can be large. Free some space and retry.\n' >&2
        return 1
    fi
    return 0
}

# ======================================================================================
# systemd-run usability (v4 §4 item 3)
# ======================================================================================
# Presence on PATH is not enough — systemd must be running, a user session must exist,
# and cgroup delegation must be permitted. Probe it for real with a trivial scope; if it
# fails, every stage falls back to `ulimit -v` and the report carries a notice that
# memory bounding is best-effort (VSZ, not RSS) on this host.
pf_check_systemd_run() {
    PF_SYSTEMD_RUN_USABLE=0
    command -v systemd-run >/dev/null 2>&1 || {
        pf_note "systemd-run not available; memory bounding falls back to 'ulimit -v' (bounds virtual size, not RSS)."
        return 0
    }
    if timeout 10 systemd-run --user --scope --quiet \
            -p MemoryMax=64M /bin/true >/dev/null 2>&1; then
        PF_SYSTEMD_RUN_USABLE=1
    elif timeout 10 systemd-run --scope --quiet \
            -p MemoryMax=64M /bin/true >/dev/null 2>&1; then
        PF_SYSTEMD_RUN_USABLE=1
    else
        pf_note "systemd-run is present but unusable here; memory bounding falls back to 'ulimit -v' (bounds virtual size, not RSS)."
    fi
    return 0
}

# ======================================================================================
# Entry point
# ======================================================================================
# preflight_run <output-dir-hint> <skip_ghidra:0|1>
# Returns 0 when the run may proceed, 1 on a hard failure.
preflight_run() {
    local out_hint="${1:-.}" skip_ghidra="${2:-0}"
    local rc=0

    pf_check_core   || rc=1
    pf_check_always || rc=1
    [[ $rc -eq 0 ]] || return 1

    if [[ $skip_ghidra -eq 1 ]]; then
        pf_note "Ghidra discovery skipped (--skip-ghidra); radare2 disassembly substitutes."
    else
        pf_find_ghidra || return 1
        pf_detect_ghidra_version
    fi

    pf_detect_binwalk_version
    pf_detect_tool_versions
    pf_check_systemd_run
    pf_check_disk "$out_hint" || return 1

    return 0
}

# preflight_summary — human-readable block for --verbose and the report header.
preflight_summary() {
    printf 'Environment\n'
    printf '  binwalk         : %s (major %s -> %s parsing)\n' \
        "${PF_VERSION[binwalk]:-unknown}" "$PF_BINWALK_MAJOR" \
        "$([[ ${PF_BINWALK_MAJOR:-0} -ge 3 ]] && printf 'v3+' || printf 'legacy')"
    if [[ -n $PF_GHIDRA_HEADLESS ]]; then
        printf '  ghidra          : %s (%s)\n' \
            "${PF_VERSION[ghidra]:-unknown}" "$PF_GHIDRA_HEADLESS"
        printf '  ghidra script   : %s\n' "$PF_GHIDRA_SCRIPT_KIND"
    else
        printf '  ghidra          : not in use\n'
    fi
    printf '  radare2         : %s\n' "${PF_VERSION[radare2]:-unknown}"
    printf '  ltrace / strace : %s / %s\n' \
        "${PF_VERSION[ltrace]:-unknown}" "${PF_VERSION[strace]:-unknown}"
    printf '  floss / upx     : %s / %s\n' \
        "${PF_VERSION[floss]:-unknown}" "${PF_VERSION[upx]:-unknown}"
    printf '  memory bounding : %s\n' \
        "$([[ $PF_SYSTEMD_RUN_USABLE -eq 1 ]] && printf 'systemd-run (RSS)' || printf 'ulimit -v (VSZ, best-effort)')"
    printf '  free disk       : %sMB\n' "$PF_DISK_FREE_MB"
    if [[ -n $PF_NOTICES ]]; then
        printf '  notices:\n'
        printf '%s\n' "$PF_NOTICES" | sed 's/^/    - /'
    fi
}
