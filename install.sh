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
# still exists because it also pulls corpus-build tools such as mingw.
set -uo pipefail   # never `set -e` — see docs/CONTRIBUTING.md §2

REVCTF_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"
# shellcheck source=dependencies/profile.sh
source "$REVCTF_ROOT/dependencies/profile.sh"

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
# dependency dies with `AttributeError: install_layout` (docs/CONTRIBUTING.md §3). A venv is the
# working route; uncompyle6 rides along in the same venv as the Python-decompile fallback.
FLOSS_VENV="${FLOSS_VENV:-/opt/revctf-tools-2.0.0}"
# Must match lib/sandbox.sh's default, or install.sh builds an image revctf never looks for.
SBX_IMAGE="${REVCTF_SBX_IMAGE:-revctf-sandbox:2.0.0}"
PYINSTX_URL="https://raw.githubusercontent.com/extremecoders-re/pyinstxtractor/$PYINSTX_COMMIT/pyinstxtractor.py"

# Ghidra is not in apt. Resolved from the GitHub releases API, with a fallback to a build
# already verified against this codebase — the release API returned 403 in one build
# sandbox while the release-asset host worked, so both paths are kept.
GHIDRA_DIR="${GHIDRA_DIR:-/opt}"

# BOOTSTRAP — what install.sh's OWN steps need before they can run.
#
# Not analysis tools: `curl` fetches Ghidra, `unzip` extracts it, `python3-venv` is what
# `python3 -m venv` needs on Debian/Kali (without it the FLOSS step dies with "ensurepip is
# not available"), `ca-certificates` is what makes the HTTPS fetches verify, and
# `g++ python3-dev` are what pip needs to BUILD flare-floss's `binary2strings` extension
# from source. install.sh checked for curl and failed the step; it never installed any of them.
#
# This gap survived a full end-to-end run because that run was on a machine that already
# had all of them — which is the reason the clean-install rehearsal exists. Installed first,
# so a failure here is reported before the steps that depend on it.
#
# The list grew twice, both times from a from-zero run, and both times the missing package
# killed a headline stage while every other step reported success:
#   2026-08-28  curl, ca-certificates, python3-venv
#   2026-09-01  unzip        — Ghidra downloaded (400MB) and then could not be extracted,
#                              so the ONE stage that recovers a stack-string flag was absent.
#               g++,         — flare-floss builds `binary2strings` from source whenever PyPI
#               python3-dev    has no wheel for the host's Python (Kali rolling is already on
#                              3.14). Without Python.h the wheel build fails and FLOSS is dead.
# Every entry here is a dependency of install.sh ITSELF. Anything a *stage* needs at scan
# time belongs in APT_CORE or APT_EXTRA, not in this list.
APT_BOOTSTRAP=(curl ca-certificates unzip python3-venv python3-dev g++)

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

# Download separately to preserve upstream's GPLv3 licence and attribution.
verify_download() {
    local file="$1" expected="$2" actual
    [[ $expected =~ ^[0-9a-f]{64}$ && -f $file && ! -L $file ]] || return 1
    actual=$(sha256sum -- "$file") || return 1
    [[ ${actual%% *} == "$expected" ]]
}

step_pyinstxtractor() {
    say "PyInstaller extractor (pinned upstream source)"
    local dest="$REVCTF_ROOT/scripts/pyinstxtractor.py" tmp
    if verify_download "$dest" "$PYINSTX_SHA256"; then
        ok "verified $dest"; return 0
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/revctf-extractor.XXXXXX") || return 1
    if curl -fsSL --retry 2 --connect-timeout 20 --max-time 120 \
            -o "$tmp/extractor.py" "$PYINSTX_URL" &&
            verify_download "$tmp/extractor.py" "$PYINSTX_SHA256" &&
            install -m 0755 "$tmp/extractor.py" "$dest"; then
        ok "installed verified extractor $PYINSTX_COMMIT"
    else
        FAILED+=("extractor download, checksum or installation failed")
    fi
    rm -rf -- "$tmp"
}

# --------------------------------------------------------------------------------------
# The sandbox image (M6)
# --------------------------------------------------------------------------------------
# Built here because this is the script's one network window: `docker build` pulls
# debian:stable-slim and apt-gets two tracers, and a scan is not the moment to discover
# that. If it does not get built, revctf does not silently run the target on the host —
# the two executing stages skip and say why (deviation D13). So a failure here degrades
# revctf, it does not break it.
#
# ABSENT DOCKER IS NOT AN INSTALL FAILURE (decided 2026-09-01, v1.0.1).
#
# It used to be: both "not installed" and "daemon unreachable" appended to FAILED, so the
# summary said `1 step(s) failed` and install.sh exited 1. The from-zero container run made
# the cost visible — with every other defect fixed, a fresh Kali box that had correctly
# installed all fourteen stages' tooling still reported failure and exited non-zero, purely
# because Kali does not ship Docker. That contradicted this very comment, and an installer
# that exits 1 on a good install teaches people to ignore its exit code.
#
# So the two ENVIRONMENT cases warn with the fix and do not fail. A `docker build` failure
# with a working daemon is different — that is revctf's own Dockerfile not building, which
# is a real defect — and it still lands in FAILED.
step_sandbox() {
    say "Sandbox image ($SBX_IMAGE) — isolation for the stages that execute the target"
    if ! command -v docker >/dev/null 2>&1; then
        warn "docker is not installed; ltrace and strace will skip unless you pass --no-sandbox"
        printf '        sudo apt-get install docker.io   # then re-run install.sh to enable them\n'
        return 0
    fi
    # NOT BEING IN THE `docker` GROUP LOOKS EXACTLY LIKE A DEAD DAEMON, and the fix is one
    # command the user will not guess. Group membership is per-process, so it does not take
    # effect in the shell that ran `usermod` either — which is the part that makes people
    # conclude the install failed.
    if ! docker info >/dev/null 2>&1; then
        if [[ -n ${DOCKER_HOST:-} ]]; then
            warn "the docker daemon is unreachable and DOCKER_HOST is set to '${DOCKER_HOST}' — if that socket is stale, unset it and re-run"
        elif ! id -nG "$INSTALL_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
            warn "$INSTALL_USER is not in the 'docker' group. Fix with:"
            printf '        sudo usermod -aG docker %s   # then: newgrp docker\n' "$INSTALL_USER"
        else
            warn "the docker daemon is not reachable (is it running? sudo systemctl start docker)"
        fi
        printf '        ltrace and strace will skip until this is fixed; --no-sandbox opts out\n'
        return 0
    fi
    local recipe existing
    recipe=$(sha256sum "$REVCTF_ROOT/docker/Dockerfile"); recipe=${recipe%% *}
    existing=$(docker image inspect --format '{{index .Config.Labels "revctf.recipe"}}' "$SBX_IMAGE" 2>/dev/null)
    if [[ $existing == "$recipe" ]]; then
        ok "$SBX_IMAGE already built"
        return 0
    fi
    if docker build -q --label "revctf.recipe=$recipe" -t "$SBX_IMAGE" "$REVCTF_ROOT/docker" >/dev/null 2>&1; then
        ok "built $SBX_IMAGE"
    else
        warn "docker build failed; re-run manually to see why: docker build -t $SBX_IMAGE $REVCTF_ROOT/docker"
        FAILED+=("sandbox image build")
    fi
    return 0
}

step_apt() {
    say "APT packages"
    run_root apt-get update -qq || { warn "apt-get update failed; continuing with whatever is cached"; }

    if run_root apt-get install -y -qq "${APT_BOOTSTRAP[@]}"; then
        ok "bootstrap: ${APT_BOOTSTRAP[*]}"
    else
        # Not fatal on its own: each dependent step still reports its own failure, and one
        # of the three may already be present. But it explains the others.
        FAILED+=("bootstrap apt packages (the FLOSS venv and the Ghidra download need these)")
    fi

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
    say "FLOSS and Python bytecode tools (isolated, pinned versions)"
    local python_version architecture
    if ! python_version=$(python3 -c 'import sys; print("%s.%s" % sys.version_info[:2])'); then
        FAILED+=("Python version could not be measured"); return 1
    fi
    architecture=$(uname -m)
    if [[ $python_version != 3.14 || $architecture != x86_64 ]]; then
        warn "The tested Python tools require Python 3.14 on Intel/AMD 64-bit Kali; found Python $python_version on $architecture."
        warn "Use the tested Kali environment or review and validate another dependency profile."
        FAILED+=("Python dependency profile does not match this environment"); return 1
    fi
    if ! run_owner "$FLOSS_VENV" python3 -m venv "$FLOSS_VENV" ||
       ! run_owner "$FLOSS_VENV" "$FLOSS_VENV/bin/python" -m pip install \
            --disable-pip-version-check --require-hashes --only-binary=:all: \
            -r "$REVCTF_ROOT/dependencies/python-build-3.14-amd64.txt" ||
       ! run_owner "$FLOSS_VENV" "$FLOSS_VENV/bin/python" -m pip install \
            --disable-pip-version-check --require-hashes --no-build-isolation \
            -r "$REVCTF_ROOT/dependencies/python-runtime-3.14-amd64.txt" ||
       ! run_owner "$FLOSS_VENV" "$FLOSS_VENV/bin/python" -m pip check; then
        FAILED+=("isolated Python tool installation"); return 1
    fi
    local tool
    for tool in floss uncompyle6; do
        if link_into_prefix "$FLOSS_VENV/bin/$tool" "$tool"; then
            ok "linked tested version of $tool"
        else
            FAILED+=("$tool command link into $PREFIX")
        fi
    done
    # shellcheck disable=SC2016  # $1 is the child shell's argument.
    if ! run_owner "$FLOSS_VENV" bash -c '"$1/bin/python" -m pip freeze > "$1/installed-versions.txt"' bash "$FLOSS_VENV"; then
        FAILED+=("Python installed-version record"); return 1
    fi
}

_install_ghidra_archive() (
    # A private directory on the destination filesystem lets the final move be atomic.
    local home="$1" tmp url
    run_owner "$GHIDRA_DIR" mkdir -p -- "$GHIDRA_DIR" || exit 1
    tmp=$(run_owner "$GHIDRA_DIR" mktemp -d "$GHIDRA_DIR/.revctf-ghidra.XXXXXX") || exit 1
    trap 'run_owner "$GHIDRA_DIR" rm -rf -- "$tmp"' EXIT
    url="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_RELEASE%%_*}_build/ghidra_${GHIDRA_RELEASE}.zip"
    run_owner "$GHIDRA_DIR" curl -fsSL --retry 3 --retry-all-errors \
        --connect-timeout 20 --max-time 600 -o "$tmp/ghidra.zip" "$url" || exit 1
    local actual
    actual=$(run_owner "$GHIDRA_DIR" sha256sum -- "$tmp/ghidra.zip") || exit 1
    [[ ${actual%% *} == "$GHIDRA_SHA256" ]] || { warn 'Ghidra checksum mismatch'; exit 1; }
    run_owner "$GHIDRA_DIR" unzip -q "$tmp/ghidra.zip" -d "$tmp/extracted" || exit 1
    local extracted="$tmp/extracted/ghidra_${GHIDRA_RELEASE%%_PUBLIC_*}_PUBLIC"
    run_owner "$GHIDRA_DIR" test -x "$extracted/support/analyzeHeadless" || exit 1
    [[ ! -e $home ]] || exit 1
    printf '%s\n' "$GHIDRA_SHA256" | run_owner "$GHIDRA_DIR" tee "$extracted/.revctf-archive.sha256" >/dev/null || exit 1
    run_owner "$GHIDRA_DIR" mv -T -- "$extracted" "$home"
)

step_ghidra() {
    say "Ghidra"
    if [[ ${SKIP_GHIDRA:-0} -eq 1 ]]; then
        ok "skipped by request (SKIP_GHIDRA=1)"
        return 0
    fi
    # Ghidra's Java scripts need a JDK. Optional decompilers must not be relied on
    # to pull Java in indirectly; a clean Kali image may have none of them.
    if ! run_root apt-get install -y -qq openjdk-21-jdk-headless; then
        FAILED+=("Ghidra Java 21 development kit — install openjdk-21-jdk-headless and re-run install.sh")
        return 1
    fi
    if [[ ${GHIDRA_LATEST:-0} != 0 ]]; then
        FAILED+=("GHIDRA_LATEST is unsupported: update the reviewed dependency profile instead")
        return 1
    fi
    local home="$GHIDRA_DIR/ghidra_${GHIDRA_RELEASE%%_PUBLIC_*}_PUBLIC"
    if [[ -e $home ]]; then
        if [[ ! -x $home/support/analyzeHeadless ]] ||
                ! grep -qx "$GHIDRA_SHA256" "$home/.revctf-archive.sha256" 2>/dev/null; then
            FAILED+=("unverified existing Ghidra at $home; preserve it and select a fresh GHIDRA_DIR")
            return 1
        fi
    elif ! _install_ghidra_archive "$home"; then
        FAILED+=("verified Ghidra installation failed; previous tools were preserved")
        return 1
    fi
    if ! link_into_prefix "$home/support/analyzeHeadless" analyzeHeadless; then
        FAILED+=("analyzeHeadless command link into $PREFIX"); return 1
    fi
    _sync_ghidra_home "$home" || { FAILED+=("GHIDRA_HOME configuration"); return 1; }
    ok "Ghidra ${GHIDRA_RELEASE%%_*} at $home"
}

# _ghidra_install_root — the Ghidra directory an existing install lives in, or empty.
# Resolves the symlink install.sh itself creates: /usr/local/bin/analyzeHeadless points at
# <root>/support/analyzeHeadless, so dirname twice on the RESOLVED path gives the root.
_ghidra_install_root() {
    local ah root=""
    if ah="$(command -v analyzeHeadless 2>/dev/null)"; then
        ah="$(readlink -f -- "$ah" 2>/dev/null)"
        [[ -n $ah ]] && root="$(dirname -- "$(dirname -- "$ah")")"
    fi
    [[ -d ${root:-} && -d ${root:-}/Ghidra ]] || root="$(compgen -G "$GHIDRA_DIR/ghidra_*" 2>/dev/null | sort -rV | head -1)"
    [[ -d ${root:-} ]] && printf '%s' "$root"
    return 0
}

# _sync_ghidra_home <root> — make the user's .bashrc export exactly this GHIDRA_HOME.
#
# REPLACES a stale line rather than skipping when one exists. The previous version appended
# only if no GHIDRA_HOME line was present, so the first value written was permanent — and
# since D12 now makes GHIDRA_HOME *win* over PATH, a stale line is no longer cosmetic: it
# would silently redirect every scan to whatever install it names.
_sync_ghidra_home() {
    local root="$1" rc="$INSTALL_HOME/.bashrc"
    [[ -n $root && -f $rc ]] || return 0
    # shlex quoting handles spaces, quotes and shell metacharacters in custom paths.
    run_as_install_user python3 - "$rc" "$root" <<'PY'
from pathlib import Path
import re
import shlex
import sys
path = Path(sys.argv[1])
line = 'export GHIDRA_HOME=' + shlex.quote(sys.argv[2])
text = path.read_text()
pattern = r'^[ \t]*export[ \t]+GHIDRA_HOME=.*$'
if re.search(pattern, text, flags=re.MULTILINE):
    text = re.sub(pattern, lambda match: line, text, flags=re.MULTILINE)
else:
    text += '\n' + line + '\n'
path.write_text(text)
PY
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
    step_sandbox
    step_pyinstxtractor

    say "Linking revctf into $PREFIX"
    if link_into_prefix "$REVCTF_ROOT/revctf" revctf; then
        ok "linked $PREFIX/revctf"
    else
        warn "could not link into $PREFIX — add $REVCTF_ROOT to your PATH instead"
        FAILED+=("revctf command link into $PREFIX")
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

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
