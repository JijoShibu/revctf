#!/usr/bin/env bash
#
# cloud-setup.sh — environment setup for a Claude Code cloud session.
#
# Paste the contents of this file into the setup-script field of your cloud environment at
# claude.ai/code (Environments -> your environment -> Setup script). It is kept in the repo
# so it is version-controlled and reviewable rather than living only in a web form.
#
# ---------------------------------------------------------------------------------------
# THE CONSTRAINT THIS IS BUILT AROUND
# ---------------------------------------------------------------------------------------
# A cloud environment's setup script has roughly a FIVE-MINUTE budget before the session
# fails to start. revctf's toolchain does not fit in it if installed naively: Ghidra alone
# is a 406MB download plus an unzip, and there are ~12 apt packages and a Python venv on top.
#
# So this script does three things:
#   1. Runs the independent installs CONCURRENTLY (`&` ... `wait`) instead of serially.
#   2. Backgrounds the Ghidra download entirely, detached, so the session becomes usable
#      while it finishes. A marker file signals completion.
#   3. Never fails the session. Every step is `|| true`-guarded — a missing optional tool
#      degrades one stage, but a non-zero exit here blocks the session from starting at all.
#
# ---------------------------------------------------------------------------------------
# NETWORK
# ---------------------------------------------------------------------------------------
# Requires the `Trusted` network access level (the Default environment's setting). Verified
# reachable: archive.ubuntu.com, pypi.org, and GitHub's release-asset host. NOT reachable:
# deb.debian.org, kali.download, Maven Central, Docker Hub.
#
# Note: `github.com/.../releases/latest` returns HTTP 403, but a DIRECT release-asset URL
# works, because it redirects to release-assets.githubusercontent.com which is allowed.
# That is why the Ghidra URL below is pinned to an exact asset rather than "latest".
set -u

log() { printf '[revctf-setup] %s\n' "$*"; }

GHIDRA_VER="11.2.1"
GHIDRA_ASSET="ghidra_${GHIDRA_VER}_PUBLIC_20241105.zip"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VER}_build/${GHIDRA_ASSET}"
GHIDRA_DIR="/opt/ghidra_${GHIDRA_VER}_PUBLIC"
GHIDRA_MARKER="/opt/.ghidra-ready"

SUDO=""
[[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# =======================================================================================
# 1. apt — the core seven plus the v6 additions, in one transaction
# =======================================================================================
log "installing apt packages"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq >/dev/null 2>&1 || true
$SUDO apt-get install -y -qq --no-install-recommends \
    file binutils binwalk bsdextrautils ltrace strace radare2 checksec \
    upx-ucl p7zip-full squashfs-tools \
    openjdk-21-jre-headless \
    shellcheck time unzip curl python3-venv \
    >/dev/null 2>&1 || true

# Corpus generation needs these; harmless if the session never builds a corpus.
$SUDO apt-get install -y -qq --no-install-recommends \
    gcc gcc-mingw-w64-x86-64 default-jdk-headless zip \
    >/dev/null 2>&1 || true

# =======================================================================================
# 2. FLOSS — must be a venv
# =======================================================================================
# `pip install flare-floss` fails system-wide on modern Debian/Ubuntu: its `halo`
# dependency's setup.py breaks against current setuptools with
# `AttributeError: install_layout`. A venv sidesteps it. Run concurrently with step 3.
install_floss() {
    command -v floss >/dev/null 2>&1 && { log "floss already present"; return 0; }
    log "installing FLOSS into /opt/floss-venv"
    $SUDO python3 -m venv /opt/floss-venv >/dev/null 2>&1 || return 0
    $SUDO /opt/floss-venv/bin/pip install -q --upgrade pip >/dev/null 2>&1 || true
    $SUDO /opt/floss-venv/bin/pip install -q flare-floss >/dev/null 2>&1 || return 0
    $SUDO ln -sf /opt/floss-venv/bin/floss /usr/local/bin/floss || true
    log "FLOSS ready: $(floss --version 2>/dev/null || echo unknown)"
}

# =======================================================================================
# 3. Ghidra — detached, because 406MB will not fit the budget
# =======================================================================================
# This is the step that would blow the five-minute limit if run inline. It is launched with
# nohup and disowned, so setup returns immediately and the session starts. Anything that
# needs Ghidra waits on the marker file (see ghidra_wait below).
#
# Everything except stage_ghidra.sh works without it, so a session is productive long
# before this finishes.
install_ghidra_detached() {
    [[ -x "$GHIDRA_DIR/support/analyzeHeadless" ]] && {
        $SUDO touch "$GHIDRA_MARKER"; log "Ghidra already present"; return 0; }

    log "starting Ghidra ${GHIDRA_VER} download in the background (406MB)"
    $SUDO rm -f "$GHIDRA_MARKER"
    $SUDO nohup bash -c "
        curl -sL --retry 3 --retry-delay 5 '$GHIDRA_URL' -o /tmp/ghidra.zip &&
        unzip -q -o /tmp/ghidra.zip -d /opt &&
        rm -f /tmp/ghidra.zip &&
        touch '$GHIDRA_MARKER'
    " >/var/log/revctf-ghidra.log 2>&1 &
    disown 2>/dev/null || true
}

# Helper installed onto PATH: block until Ghidra is usable, or give up.
#   ghidra-wait [timeout-seconds]
install_ghidra_wait_helper() {
    $SUDO tee /usr/local/bin/ghidra-wait >/dev/null <<EOF || return 0
#!/usr/bin/env bash
# Block until the backgrounded Ghidra install finishes. Exits 0 when ready, 1 on timeout.
deadline=\$(( SECONDS + \${1:-600} ))
while [[ ! -f "$GHIDRA_MARKER" ]]; do
    [[ \$SECONDS -ge \$deadline ]] && {
        echo "ghidra-wait: still not ready; see /var/log/revctf-ghidra.log" >&2; exit 1; }
    sleep 5
done
export GHIDRA_HOME="$GHIDRA_DIR"
echo "$GHIDRA_DIR"
EOF
    $SUDO chmod +x /usr/local/bin/ghidra-wait || true
}

# =======================================================================================
# Run the independent pieces concurrently
# =======================================================================================
install_floss &
FLOSS_PID=$!
install_ghidra_detached
install_ghidra_wait_helper
wait "$FLOSS_PID" 2>/dev/null || true

# Ghidra's eventual location, for lib/preflight.sh's discovery and for the harness.
{
    echo "export GHIDRA_HOME=$GHIDRA_DIR"
    echo "export PF_OPT_ROOT_REAL=/opt"
} | $SUDO tee /etc/profile.d/revctf.sh >/dev/null 2>&1 || true

# =======================================================================================
# Report what landed
# =======================================================================================
log "toolchain status:"
for t in file strings binwalk hexdump ltrace strace radare2 rabin2 \
         checksec objdump readelf upx 7z unsquashfs floss shellcheck; do
    if command -v "$t" >/dev/null 2>&1; then
        printf '  %-12s ok\n' "$t"
    else
        printf '  %-12s MISSING\n' "$t"
    fi
done

if [[ -f $GHIDRA_MARKER ]]; then
    log "ghidra       ready at $GHIDRA_DIR"
else
    log "ghidra       downloading in the background — run 'ghidra-wait' before using it"
fi

log "done. Build the corpus with ./tools/build-test-corpus.sh, verify with ./tools/run-tests.sh"
exit 0
