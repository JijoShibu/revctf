#!/usr/bin/env bash
#
# install.sh — one-time setup for revctf.
#
# Runs during the confirmed network window (masterplan v3 §4 item 7). It is responsible
# for EVERY external dependency, because v6 deviation D7 makes a missing optional tool a
# hard error at scan time rather than a silent degradation. If you skip this script,
# revctf will tell you to come back and run it.
#
# Implemented in: M0 (skeleton) -> completed in M1 (core tools) and M6 (Docker image).
set -uo pipefail

REVCTF_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"
REVCTF_HOME="${REVCTF_HOME:-$HOME/.revctf}"

# Package lists are declared here at M0 so the dependency surface is reviewable before
# the install logic that consumes them lands in M1. Each is referenced by main()'s
# commented M1 block; SC2034 is suppressed until that block goes live.

# Core seven — revctf refuses to run without these (v5/M1 preflight).
# shellcheck disable=SC2034
APT_CORE=(file binutils binwalk bsdextrautils ltrace radare2)
# Added in v6 (deviation D2). Hard dependencies at scan time, per D7.
# shellcheck disable=SC2034
APT_EXTRA=(checksec strace upx-ucl p7zip-full squashfs-tools)
# Not in Kali's default repos — installed separately in M1.
# shellcheck disable=SC2034
PIP_EXTRA=(flare-floss uncompyle6)

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

main() {
    say "revctf installer"
    [[ -x $REVCTF_ROOT/revctf ]] || die "revctf entry script missing or not executable"

    say "Creating $REVCTF_HOME"
    mkdir -p "$REVCTF_HOME" && chmod 700 "$REVCTF_HOME"

    # --- M1 ---------------------------------------------------------------------
    # say "Installing core tools"; apt-get install -y "${APT_CORE[@]}"
    # say "Installing v6 additional tools"; apt-get install -y "${APT_EXTRA[@]}"
    # say "Installing Python tooling"; pip install --break-system-packages "${PIP_EXTRA[@]}"
    # say "Installing Java/.NET decompilers"  # jd-cli / procyon / ilspycmd
    # say "Verifying Ghidra"                  # PATH -> GHIDRA_HOME -> /opt/ghidra*
    # --- M6 ---------------------------------------------------------------------
    # say "Building sandbox image"; docker build -t revctf-sandbox "$REVCTF_ROOT/docker"
    # -----------------------------------------------------------------------------
    warn "dependency installation is a stub (lands in M1); skipping"

    say "Linking revctf into $PREFIX"
    if [[ -w $PREFIX ]]; then
        if ln -sf "$REVCTF_ROOT/revctf" "$PREFIX/revctf"; then
            say "Linked $PREFIX/revctf"
        else
            warn "could not link into $PREFIX"
        fi
    else
        warn "$PREFIX is not writable — re-run with sudo, or add $REVCTF_ROOT to your PATH"
    fi

    say "Done. Try: revctf --help"
}

main "$@"
