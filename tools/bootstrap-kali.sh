#!/usr/bin/env bash
# tools/bootstrap-kali.sh — get a fresh Kali (or WSL Kali) ready to develop revctf.
#
# THIS IS A STOPGAP, NOT THE INSTALLER.
# `install.sh` is the real, permanent entry point — but at v0.1-mvp its dependency block
# is still commented out, so it installs nothing while README and preflight both tell you
# it is mandatory. Fixing that is the first task of the next milestone. Until then this
# script exists so you are not hand-typing apt lines to get productive.
#
# Differences from install.sh, deliberately:
#   - it also installs BUILD dependencies (gcc, mingw, JDK) that only the test corpus needs
#   - it clones the repo and runs the verification harness
#   - it is allowed to be opinionated about WSL, which install.sh should not be
#
#   ./tools/bootstrap-kali.sh              # full run
#   SKIP_GHIDRA=1 ./tools/bootstrap-kali.sh
#
# Safe to re-run: every step checks before acting.

set -uo pipefail   # never `set -e` — see docs/CLAUDE.md §2

REPO_URL="${REPO_URL:-https://github.com/JijoShibu/revctf.git}"
REPO_DIR="${REPO_DIR:-$HOME/revctf}"
GHIDRA_DIR="${GHIDRA_DIR:-/opt}"
GHIDRA_FALLBACK="${GHIDRA_FALLBACK:-11.2.1_PUBLIC_20241105}"
FLOSS_VENV="${FLOSS_VENV:-/opt/floss-venv}"

declare -a FAILED=()
say()  { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!!\033[0m %s\n' "$*" >&2; }
fail() { printf '    \033[31mXX\033[0m %s\n' "$*" >&2; FAILED+=("$1"); }

need_sudo() {
    if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
        printf 'This needs root or sudo.\n' >&2; exit 1
    fi
}
run_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

step_preflight() {
    say "Pre-flight — look before installing"
    # This script installs system packages. On a VM that is used for other work that is a
    # real risk: an apt upgrade can move a version something else depends on. So it reports
    # what is already here and what it would change, before changing anything.

    local free_mb
    free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n $free_mb ]] && is_uint_bk "$free_mb"; then
        # Ghidra ~400MB unpacked, JDK ~500MB, mingw + build tools ~700MB, corpus ~250MB,
        # plus apt cache. 4GB is comfortable; 2GB will fail partway through Ghidra.
        if [[ $free_mb -lt 2048 ]]; then
            fail "only ${free_mb}MB free on / — need ~4GB (Ghidra, JDK, mingw, corpus)"
        elif [[ $free_mb -lt 4096 ]]; then
            warn "${free_mb}MB free on / — tight. Ghidra and the JDK need most of it."
        else
            ok "${free_mb}MB free on /"
        fi
    else
        warn "could not read free disk space"
    fi

    local ram_mb cpus
    ram_mb="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
    cpus="$(nproc 2>/dev/null)"
    printf '    RAM %sMB, %s CPU(s)\n' "${ram_mb:-?}" "${cpus:-?}"
    if [[ -n $ram_mb ]] && is_uint_bk "$ram_mb"; then
        if   [[ $ram_mb -ge 3891 ]]; then ok "Tier A (>= 3891MB) — matches v3 §8's 4GB derivation target"
        elif [[ $ram_mb -ge 2560 ]]; then warn "Tier B. Raise the VM to 4096MB to develop against Tier A."
        else                              warn "Tier C. Ghidra will be skipped by default on this host."
        fi
    fi

    # What is already installed, and at what version. On a cluttered VM this is the line
    # that tells you whether apt is about to change something you rely on.
    say "Already present"
    local t v n=0
    for t in file binwalk ltrace strace radare2 checksec upx floss analyzeHeadless docker; do
        if command -v "$t" >/dev/null 2>&1; then
            v="$("$t" --version 2>/dev/null | head -1 | cut -c1-46)"
            printf '    %-16s %s\n' "$t" "${v:-installed}"
            n=$(( n + 1 ))
        fi
    done
    [[ $n -eq 0 ]] && printf '    (none of the toolchain is installed yet)\n'

    if [[ ${ASSUME_YES:-0} -eq 1 ]]; then return 0; fi
    printf '\n    \033[1mIf this VM is used for other work, snapshot it now.\033[0m\n'
    printf '    VirtualBox: Machine > Take Snapshot, while the VM is running or powered off.\n'
    printf '    This script runs apt-get install and writes to /opt and /usr/local/bin.\n'
    printf '    Continue? [y/N] '
    local a; read -r a
    [[ ${a,,} == y ]] || { printf '    Stopped. Nothing was changed.\n'; exit 0; }
    return 0
}

# Local numeric guard — this script does not source lib/, and a non-numeric word in an
# arithmetic test exits the shell outright under `set -u` (the QA-1 rule).
is_uint_bk() { [[ $1 =~ ^[0-9]+$ ]]; }

step_env_check() {
    say "Environment"
    if ! grep -qi microsoft /proc/version 2>/dev/null; then
        # A real VM (VirtualBox, VMware, bare metal) boots systemd itself, so the whole
        # WSL dance below does not apply. Confirm systemd anyway: M5's primary
        # memory-bounding path is systemd-run, and it has never executed in this project.
        if [[ -d /run/systemd/system ]]; then
            ok "not WSL, and systemd is booted — M5's systemd-run path is available"
        else
            warn "not WSL, but systemd is NOT booted (PID 1 = $(ps -p1 -o comm= 2>/dev/null))"
            printf '        M5 requires systemd-run --scope -p MemoryMax=. Investigate before M5.\n'
        fi
        return 0
    fi
    ok "running under WSL"

    # This decides whether M5 is reachable at all. WSL2 does not boot systemd by default,
    # and M5's Definition of Done requires the systemd-run --scope -p MemoryMax= path to
    # work. Without it revctf falls back to ulimit -v, which bounds virtual size rather
    # than RSS — exactly the state the cloud build sandbox was stuck in, where that path
    # never executed once in the whole project.
    if [[ -d /run/systemd/system ]]; then
        ok "systemd is booted"
    else
        warn "systemd is NOT booted — M5's primary memory-bounding path cannot work"
        printf '        Add this to /etc/wsl.conf:\n\n'
        printf '            [boot]\n            systemd=true\n\n'
        printf '        then run  wsl --shutdown  in PowerShell, wait ~8s, and reopen.\n'
        if [[ ! -f /etc/wsl.conf ]] || ! grep -q 'systemd=true' /etc/wsl.conf 2>/dev/null; then
            printf '        Write it now? [y/N] '
            local a; read -r a
            if [[ ${a,,} == y ]]; then
                run_root tee -a /etc/wsl.conf >/dev/null <<'EOF'

[boot]
systemd=true
EOF
                ok "written — run 'wsl --shutdown' from PowerShell, then re-run this script"
            fi
        fi
    fi

    # Tier work needs the repo on ext4. NTFS via /mnt cannot hold the 0600 capture and
    # 0700 directory modes v4 5 requires and QA-9/QA-10 fixed — the tests would pass
    # while the guarantee was void.
    case "$REPO_DIR" in
        /mnt/*) fail "REPO_DIR is under /mnt — NTFS cannot hold the 0600/0700 modes revctf requires. Use \$HOME." ;;
        *)      ok "repo target $REPO_DIR is on the Linux filesystem" ;;
    esac
}

step_apt() {
    say "APT packages"
    need_sudo
    run_root apt-get update -qq || { fail "apt-get update"; return 1; }

    # Core seven plus the v6 D2 additions — revctf refuses to run without these.
    local -a core=(file binutils binwalk bsdextrautils ltrace radare2
                   checksec strace upx-ucl p7zip-full squashfs-tools)
    # Only the test corpus needs these; install.sh should NOT pull them.
    local -a build=(git gcc build-essential gcc-mingw-w64 default-jdk zip unzip
                    python3 python3-venv python3-pip curl)
    # Format-conditional decompilers. D7 makes these lazy failures, so a miss is survivable.
    local -a optional=(procyon-decompiler cfr-decompiler mono-utils)

    run_root apt-get install -y -qq "${core[@]}"  || fail "core packages"
    run_root apt-get install -y -qq "${build[@]}" || fail "build packages"
    local p
    for p in "${optional[@]}"; do
        if run_root apt-get install -y -qq "$p" >/dev/null 2>&1; then
            ok "optional: $p"
        else
            warn "optional package unavailable: $p (lazy failure only)"
        fi
    done
    ok "apt done"
}

step_floss() {
    say "FLOSS (in a venv — this is not optional)"
    # docs/CLAUDE.md 3: flare-floss CANNOT be pip-installed system-wide on modern
    # Debian/Ubuntu. Its halo dependency dies with AttributeError: install_layout.
    # pip install --break-system-packages flare-floss — which install.sh still carries as
    # a commented line — fails. A venv is the working route.
    if command -v floss >/dev/null 2>&1; then ok "floss already on PATH"; return 0; fi
    need_sudo
    run_root python3 -m venv "$FLOSS_VENV" || { fail "floss venv"; return 1; }
    run_root "$FLOSS_VENV/bin/pip" install -q --upgrade pip || warn "pip upgrade failed"
    if run_root "$FLOSS_VENV/bin/pip" install -q flare-floss; then
        run_root ln -sf "$FLOSS_VENV/bin/floss" /usr/local/bin/floss
        ok "floss installed and linked"
    else
        fail "flare-floss install"
    fi
    if run_root "$FLOSS_VENV/bin/pip" install -q uncompyle6 2>/dev/null; then
        run_root ln -sf "$FLOSS_VENV/bin/uncompyle6" /usr/local/bin/uncompyle6
        ok "uncompyle6 installed"
    else
        warn "uncompyle6 unavailable (scripts/pyc_disasm.py is the always-available fallback)"
    fi
}

step_ghidra() {
    say "Ghidra"
    if [[ ${SKIP_GHIDRA:-0} -eq 1 ]]; then ok "skipped by request"; return 0; fi
    if command -v analyzeHeadless >/dev/null 2>&1 || compgen -G "$GHIDRA_DIR/ghidra_*" >/dev/null; then
        ok "already installed"; return 0
    fi
    need_sudo
    command -v curl >/dev/null 2>&1 || { fail "curl missing"; return 1; }

    # Resolve the newest release, falling back to a version verified against this codebase.
    # For the record: in the cloud sandbox the releases API returned 403 while the
    # release-asset host worked. On a normal machine the API is fine.
    local url=""
    url="$(curl -fsSL https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest 2>/dev/null \
           | grep -oE 'https://[^"]+ghidra_[0-9.]+_PUBLIC_[0-9]+\.zip' | head -1)"
    if [[ -z $url ]]; then
        url="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_FALLBACK%%_*}_build/ghidra_${GHIDRA_FALLBACK}.zip"
        warn "release API gave nothing; falling back to the pinned build"
    fi

    local zip="/tmp/ghidra.zip"
    printf '    downloading %s\n' "$url"
    if curl -fsSL -o "$zip" "$url"; then
        run_root unzip -q -o "$zip" -d "$GHIDRA_DIR" && rm -f "$zip"
        local home; home="$(compgen -G "$GHIDRA_DIR/ghidra_*" | head -1)"
        if [[ -n $home ]]; then
            run_root ln -sf "$home/support/analyzeHeadless" /usr/local/bin/analyzeHeadless
            ok "installed at $home"
            grep -q 'GHIDRA_HOME' "$HOME/.bashrc" 2>/dev/null \
                || printf '\nexport GHIDRA_HOME=%s\n' "$home" >> "$HOME/.bashrc"
        else
            fail "ghidra extract"
        fi
    else
        fail "ghidra download — install manually and set GHIDRA_HOME"
    fi
}

step_repo() {
    say "Repository"
    if [[ -d $REPO_DIR/.git ]]; then
        ok "already cloned at $REPO_DIR"
    elif git clone -q "$REPO_URL" "$REPO_DIR"; then
        ok "cloned to $REPO_DIR"
    else
        fail "clone"; return 1
    fi
    # Repo-local settings only. Authorship is DELIBERATELY not set here: this script runs
    # on whoever's machine clones revctf, and writing a name and email into their clone
    # would silently make their commits appear to come from someone else. Their own global
    # git config is the right answer and is already correct for them.
    git -C "$REPO_DIR" config core.autocrlf false
    git -C "$REPO_DIR" config commit.gpgsign false
    ok "git configured (LF, unsigned commits; authorship left to your global config)"
}

step_verify() {
    say "Corpus and verification"
    [[ -x $REPO_DIR/tools/build-test-corpus.sh ]] || { fail "repo incomplete"; return 1; }
    if ( cd "$REPO_DIR" && ./tools/build-test-corpus.sh ) >/dev/null 2>&1; then
        ok "test corpus built"
    else
        fail "corpus build (check gcc / mingw / JDK)"
    fi
    printf '    running the harness — this takes ~15 minutes\n'
    if ( cd "$REPO_DIR" && ./tools/run-tests.sh ); then
        ok "harness green"
    else
        fail "harness — see the output above"
    fi
}

main() {
    printf '\033[1mrevctf bootstrap\033[0m — stopgap until install.sh is completed\n'
    step_preflight
    step_env_check
    step_apt
    step_floss
    step_ghidra
    step_repo
    step_verify

    say "Summary"
    if [[ ${#FAILED[@]} -eq 0 ]]; then
        printf '    Everything succeeded.\n\n'
        printf '    Next:\n'
        printf '      cd %s\n' "$REPO_DIR"
        printf '      ./tools/tui-selftest.sh     # the six checks no CI can make\n'
        printf '      ./tools/measure-host.sh     # the numbers M5 is designed around\n'
        printf '      claude                      # start Claude Code HERE, not in PowerShell\n'
        return 0
    fi
    printf '    %d step(s) failed:\n' "${#FAILED[@]}"
    printf '      - %s\n' "${FAILED[@]}"
    printf '\n    revctf treats a missing tool as a hard error by design (v6 D7), so fix\n'
    printf '    these before scanning. Format-conditional decompilers fail lazily and can\n'
    printf '    wait until you meet a target that needs them.\n'
    return 1
}

main "$@"
