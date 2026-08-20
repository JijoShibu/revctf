#!/usr/bin/env bash
#
# install.sh — one-time setup for revctf.
#
# Runs during the confirmed network window (masterplan v3 §4 item 7). It is responsible
# for EVERY external dependency, because v6 deviation D7 makes a missing optional tool a
# hard error at scan time rather than a silent degradation. If you skip this script,
# revctf will tell you to come back and run it.
#
# Implemented in: M0 (skeleton) -> M1 (registry only; the installer itself stayed inert)
# -> completed pre-M5 on real Kali, per QA review #2 §7 item 1: "uncommenting is not
# enough; the pip line is known to fail". The Docker sandbox image build is still M6.
#
# This script installs system packages and writes to /opt and /usr/local/bin. It needs
# root. tools/bootstrap-kali.sh is the richer, opinionated stopgap this superseded — it
# still exists because it also pulls build-only dependencies (gcc, mingw, JDK) for the
# test corpus, which install.sh deliberately does not.
set -uo pipefail   # never `set -e` — see CLAUDE.md §2

REVCTF_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"

# --------------------------------------------------------------------------------------
# Who are we installing FOR?
# --------------------------------------------------------------------------------------
# This script is documented as `sudo ./install.sh`, and `$HOME` under sudo is not something
# to guess at: with `env_reset` sudo sets HOME from the TARGET user's passwd entry (root),
# while some configurations preserve the caller's. Debian and Kali differ from upstream
# here, and /etc/sudoers is not readable to check.
#
# Getting it wrong is silent and user-visible: `~/.revctf` would be created as /root/.revctf,
# so the config file revctf actually reads (`$HOME/.revctf/config` for the real user) would
# never exist, and the GHIDRA_HOME line would be appended to root's .bashrc where the user
# never sees it. Both would look like a clean install.
#
# SUDO_USER is set by sudo to the invoking user and is the unambiguous answer. Fall back to
# $HOME when the script is run directly as root or as an ordinary user.
INSTALL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
if [[ -n ${SUDO_USER:-} ]]; then
    INSTALL_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
fi
INSTALL_HOME="${INSTALL_HOME:-$HOME}"
REVCTF_HOME="${REVCTF_HOME:-$INSTALL_HOME/.revctf}"

# flare-floss cannot be pip-installed system-wide on modern Debian/Ubuntu — its `halo`
# dependency dies with `AttributeError: install_layout` (CLAUDE.md §3). A venv is the
# working route; uncompyle6 rides along in the same venv as the Python-decompile fallback.
FLOSS_VENV="${FLOSS_VENV:-/opt/floss-venv}"

# Ghidra is not in apt. Resolved from the GitHub releases API, with a fallback to a build
# already verified against this codebase — the release API returned 403 in one build
# sandbox while the release-asset host worked, so both paths are kept.
GHIDRA_DIR="${GHIDRA_DIR:-/opt}"
GHIDRA_FALLBACK="${GHIDRA_FALLBACK:-11.2.1_PUBLIC_20241105}"

# CORE — the seven from v3 §1 (Ghidra excluded; discovered separately, not an apt package).
# revctf refuses to run without these; a miss is a hard failure with an apt hint (M1 DoD).
APT_CORE=(file binutils binwalk bsdextrautils ltrace radare2)
# ALWAYS — added by v6 deviation D2, needed on every run regardless of target format.
# Per D7 these are install.sh's responsibility and a miss at scan time is a hard error.
APT_EXTRA=(checksec strace upx-ucl p7zip-full squashfs-tools)
# CONDITIONAL — Java/.NET decompilers. Stage 11 fails lazily (D7's second tier) if these
# are missing, so a failure here is soft: reported, not fatal to the whole install.
APT_OPTIONAL=(procyon-decompiler jd-cli mono-utils)

declare -a FAILED=()
say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m %s\n' "$*"; }
warn() { printf '    \033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# run_owner <dir> <cmd...> — escalate ONLY if <dir> is not already writable by us.
#
# The default targets (/opt, /usr/local/bin) need root, so the obvious implementation is to
# call run_root for all of them. But that makes the script impossible to exercise without
# root — and an installer nobody can run is precisely how this one stayed a stub through
# five milestones (QA review #2 §7 item 1). With this, pointing PREFIX and FLOSS_VENV at a
# writable directory gives a full end-to-end rehearsal as an ordinary user, and a per-user
# install works for free. Behaviour under `sudo ./install.sh` is unchanged.
run_owner() {
    local dir="$1"; shift
    # Test the nearest existing ancestor: the directory itself may not exist yet.
    local probe="$dir"
    while [[ -n $probe && ! -e $probe ]]; do probe="$(dirname -- "$probe")"; done
    if [[ -w $probe ]]; then "$@"; else run_root "$@"; fi
}

# link_into_prefix <target> <linkname> — symlink into $PREFIX, returning honestly.
#
# $PREFIX may not exist yet (a per-user prefix like ~/.local/bin often does not), and the
# earlier code ignored `ln`'s exit status, printing "ok ... installed and linked" after a
# failed symlink. Creating the directory first and propagating the status is the whole fix.
link_into_prefix() {
    local target="$1" linkname="$2"
    [[ -d $PREFIX ]] || run_owner "$PREFIX" mkdir -p "$PREFIX" 2>/dev/null || return 1
    run_owner "$PREFIX" ln -sf "$target" "$PREFIX/$linkname" 2>/dev/null || return 1
    [[ -e $PREFIX/$linkname ]]
}

# run_as_install_user — drop back to the invoking user for anything written into their home.
# Under `sudo ./install.sh` every command would otherwise run as root, leaving root-owned
# files in the user's home directory that they cannot later edit.
run_as_install_user() {
    if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then
        runuser -u "$SUDO_USER" -- "$@"
    else
        "$@"
    fi
}

step_apt() {
    say "APT packages"
    run_root apt-get update -qq || { warn "apt-get update failed; continuing with whatever is cached"; }

    if run_root apt-get install -y -qq "${APT_CORE[@]}"; then
        ok "core: ${APT_CORE[*]}"
    else
        FAILED+=("core apt packages")
    fi
    if run_root apt-get install -y -qq "${APT_EXTRA[@]}"; then
        ok "always-needed: ${APT_EXTRA[*]}"
    else
        FAILED+=("always-needed apt packages")
    fi

    local p
    for p in "${APT_OPTIONAL[@]}"; do
        if run_root apt-get install -y -qq "$p" >/dev/null 2>&1; then
            ok "optional: $p"
        else
            # Not appended to FAILED: D7 makes these lazy failures at the point a target
            # actually needs them, with the same "re-run install.sh" message. A CTF box
            # without .NET tooling should still be able to install and scan an ELF.
            warn "optional package unavailable: $p (Stage 11 will fail lazily if a target needs it)"
        fi
    done
}

step_floss() {
    say "FLOSS + uncompyle6 (in a venv — pip install --break-system-packages is known to fail)"
    if command -v floss >/dev/null 2>&1; then
        ok "floss already on PATH"
    else
        if ! run_owner "$FLOSS_VENV" python3 -m venv "$FLOSS_VENV"; then
            FAILED+=("floss venv")
        else
            run_owner "$FLOSS_VENV" "$FLOSS_VENV/bin/pip" install -q --upgrade pip || warn "pip upgrade failed; continuing"
            if run_owner "$FLOSS_VENV" "$FLOSS_VENV/bin/pip" install -q flare-floss; then
                # The `ln` return value used to be ignored, so a failed symlink still
                # printed "ok floss installed and linked" — caught by the rootless
                # rehearsal, where $PREFIX did not exist yet. Reporting success for work
                # that did not happen is the defect class this project keeps finding.
                if link_into_prefix "$FLOSS_VENV/bin/floss" floss; then
                    ok "floss installed and linked at $PREFIX/floss"
                else
                    FAILED+=("floss symlink into $PREFIX")
                fi
            else
                FAILED+=("flare-floss install")
            fi
        fi
    fi

    if command -v uncompyle6 >/dev/null 2>&1; then
        ok "uncompyle6 already on PATH"
    elif [[ -x $FLOSS_VENV/bin/pip ]]; then
        if run_owner "$FLOSS_VENV" "$FLOSS_VENV/bin/pip" install -q uncompyle6 2>/dev/null \
           && link_into_prefix "$FLOSS_VENV/bin/uncompyle6" uncompyle6; then
            ok "uncompyle6 installed and linked at $PREFIX/uncompyle6"
        else
            # Soft: scripts/pyc_disasm.py is the always-available fallback for stage 12.
            warn "uncompyle6 unavailable (scripts/pyc_disasm.py is the fallback)"
        fi
    fi
}

step_ghidra() {
    say "Ghidra"
    if [[ ${SKIP_GHIDRA:-0} -eq 1 ]]; then
        ok "skipped by request (SKIP_GHIDRA=1)"
        return 0
    fi
    if command -v analyzeHeadless >/dev/null 2>&1 || compgen -G "$GHIDRA_DIR/ghidra_*" >/dev/null 2>&1; then
        ok "already installed"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        FAILED+=("ghidra (curl missing)")
        return 1
    fi

    # INSTALL THE PINNED, VERIFIED BUILD BY DEFAULT — NOT "latest".
    #
    # The first version of this step asked the releases API for `latest` and used the pinned
    # build only as a fallback. On 2026-08-20 that installed Ghidra 12.1.3, and the result
    # was a silently broken decompile stage: 12.x ships PyGhidra with no Jython, PyGhidra is
    # not enabled under plain `analyzeHeadless`, and the post-script died with "Ghidra was
    # not started with PyGhidra" while analyzeHeadless still exited 0. The corpus crackme's
    # password — which 11.2.1 recovers — was simply not found, and nothing said why.
    #
    # An installer that silently upgrades the one dependency whose behaviour the whole
    # project is calibrated against is the version-decay trap this codebase has already been
    # bitten by twice (upx's PIE bug, radare2 finding `main` in stripped binaries — see
    # CLAUDE.md §3). So: pin by default, and make "newest" an explicit, informed choice.
    local url=""
    if [[ ${GHIDRA_LATEST:-0} -eq 1 ]]; then
        warn "GHIDRA_LATEST=1: installing the newest release. revctf is verified against ${GHIDRA_FALLBACK%%_*}; newer majors may change the post-script runtime."
        url="$(curl -fsSL https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest 2>/dev/null \
               | grep -oE 'https://[^"]+ghidra_[0-9.]+_PUBLIC_[0-9]+\.zip' | head -1)"
        [[ -z $url ]] && warn "release API gave nothing; using the pinned build instead"
    fi
    if [[ -z $url ]]; then
        url="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_FALLBACK%%_*}_build/ghidra_${GHIDRA_FALLBACK}.zip"
    fi

    local zip="/tmp/ghidra-install.$$.zip"
    printf '    downloading %s\n' "$url"
    if ! curl -fsSL -o "$zip" "$url"; then
        FAILED+=("ghidra download — install manually and set GHIDRA_HOME")
        return 1
    fi
    if ! run_owner "$GHIDRA_DIR" unzip -q -o "$zip" -d "$GHIDRA_DIR"; then
        FAILED+=("ghidra extract")
        rm -f "$zip"
        return 1
    fi
    rm -f "$zip"

    local home; home="$(compgen -G "$GHIDRA_DIR/ghidra_*" | head -1)"
    if [[ -z $home ]]; then
        FAILED+=("ghidra extract — no ghidra_* directory found under $GHIDRA_DIR")
        return 1
    fi
    if link_into_prefix "$home/support/analyzeHeadless" analyzeHeadless; then
        ok "installed at $home, linked at $PREFIX/analyzeHeadless"
    else
        FAILED+=("analyzeHeadless symlink into $PREFIX")
    fi

    # analyzeHeadless is found via PATH -> GHIDRA_HOME -> /opt/ghidra* (pf_detect_ghidra_
    # runtime, lib/preflight.sh). The symlink covers PATH; GHIDRA_HOME is a convenience for
    # anything that reads the variable directly.
    # INSTALL_HOME, not $HOME: under sudo this file belongs to the invoking user, and
    # appending to /root/.bashrc would be invisible to them. Written as that user too, so
    # the file does not end up root-owned in their home directory.
    local rc="$INSTALL_HOME/.bashrc"
    if [[ -f $rc ]] && ! grep -q 'GHIDRA_HOME' "$rc" 2>/dev/null; then
        if printf '\nexport GHIDRA_HOME=%s\n' "$home" \
             | run_as_install_user tee -a "$rc" >/dev/null 2>&1; then
            ok "GHIDRA_HOME appended to $rc (new shells only — export it now to use this one)"
        else
            warn "could not append GHIDRA_HOME to $rc; set it yourself: export GHIDRA_HOME=$home"
        fi
    fi
}

main() {
    say "revctf installer"
    [[ -x $REVCTF_ROOT/revctf ]] || die "revctf entry script missing or not executable"

    if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
        die "install.sh installs system packages; re-run as root or install sudo"
    fi

    # Created AS the invoking user, not as root. revctf reads $HOME/.revctf/config at scan
    # time as whoever runs the scan; a root-owned 0700 directory there would make the config
    # unreadable and unwritable to the person who installed it, while looking fine here.
    say "Creating $REVCTF_HOME (for $INSTALL_USER)"
    if run_as_install_user mkdir -p "$REVCTF_HOME" 2>/dev/null; then
        run_as_install_user chmod 700 "$REVCTF_HOME" 2>/dev/null
        ok "$REVCTF_HOME ready"
    else
        FAILED+=("could not create $REVCTF_HOME")
    fi

    step_apt
    step_floss
    step_ghidra

    say "Linking revctf into $PREFIX"
    if link_into_prefix "$REVCTF_ROOT/revctf" revctf; then
        ok "linked $PREFIX/revctf"
    else
        warn "could not link into $PREFIX — add $REVCTF_ROOT to your PATH instead"
    fi

    say "Summary"
    if [[ ${#FAILED[@]} -eq 0 ]]; then
        printf '    Everything succeeded. Try: revctf --help\n'
        return 0
    fi
    printf '    %d step(s) failed:\n' "${#FAILED[@]}"
    printf '      - %s\n' "${FAILED[@]}"
    printf '\n    revctf treats a missing tool as a hard error at scan time (v6 D7); fix\n'
    printf '    these and re-run install.sh. Optional decompilers fail lazily and can wait\n'
    printf '    until a target actually needs them.\n'
    return 1
}

main "$@"
