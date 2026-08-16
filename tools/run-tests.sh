#!/usr/bin/env bash
#
# run-tests.sh — verification harness for revctf's milestone gates.
#
# The execution masterplan names a verification step for every milestone and stresses
# actually running it before advancing. This script is that, made repeatable: each
# milestone adds a section, and every later run re-checks all the earlier ones, so a
# regression in M1 shows up while building M4.
#
#   ./tools/run-tests.sh            # everything
#   ./tools/run-tests.sh m0 m1      # selected sections
#
# Requires a built corpus: ./tools/build-test-corpus.sh
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RC="$ROOT/revctf"
CORPUS="$ROOT/test-corpus"
FIXTURES="${TMPDIR:-/tmp}/revctf-test-fixtures"

PASS=0; FAIL=0; SKIP=0
declare -a FAILURES=()

# Isolate every run from the developer's real ~/.revctf
export REVCTF_HOME="$FIXTURES/home"

# ======================================================================================
# Assertions
# ======================================================================================
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILURES+=("$1"); }
skip() { printf '  \033[33mSKIP\033[0m  %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }
section() { printf '\n\033[1m--- %s ---\033[0m\n' "$1"; }

# assert_exit <desc> <expected-exit> <cmd...>
assert_exit() {
    local desc="$1" want="$2"; shift 2
    local out got
    out=$("$@" 2>&1); got=$?
    if [[ $got -eq $want ]]; then
        ok "$desc"
    else
        no "$desc" "exit $got, wanted $want: ${out:0:160}"
    fi
}

# assert_match <desc> <extended-regex> <cmd...>
assert_match() {
    local desc="$1" re="$2"; shift 2
    local out
    out=$("$@" 2>&1)
    if grep -Eq -- "$re" <<< "$out"; then
        ok "$desc"
    else
        no "$desc" "output did not match /$re/: ${out:0:200}"
    fi
}

# assert_no_match <desc> <extended-regex> <cmd...>
assert_no_match() {
    local desc="$1" re="$2"; shift 2
    local out
    out=$("$@" 2>&1)
    if grep -Eq -- "$re" <<< "$out"; then
        no "$desc" "unexpectedly matched /$re/"
    else
        ok "$desc"
    fi
}

have_corpus() { [[ -f $CORPUS/crackme ]]; }

# ======================================================================================
# Fixtures
# ======================================================================================
# A fake Ghidra tree, so discovery and version selection are testable without a real
# 400MB install (and on a box where Ghidra genuinely is not available).
# mk_fake_ghidra <root> <version> [runtime-feature...]
# Runtime features are directory names under Ghidra/Features (PyGhidra, Jython). Passing
# none produces an install with neither, which exercises the version-comparison fallback.
mk_fake_ghidra() {
    local root="$1" version="$2"; shift 2
    mkdir -p "$root/support" "$root/Ghidra"
    printf '#!/bin/sh\necho "fake analyzeHeadless $*"\n' > "$root/support/analyzeHeadless"
    chmod +x "$root/support/analyzeHeadless"
    printf 'application.name=Ghidra\napplication.version=%s\n' "$version" \
        > "$root/Ghidra/application.properties"
    local feat
    for feat in "$@"; do mkdir -p "$root/Ghidra/Features/$feat"; done
}

# Build a PATH containing everything except the named commands, so a missing-tool
# scenario can be exercised without uninstalling anything.
mk_masked_path() {
    local mask=",$1," dir="$FIXTURES/maskedpath-$2" p f b
    rm -rf "$dir"; mkdir -p "$dir"
    for p in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
        [[ -d $p ]] || continue
        for f in "$p"/*; do
            b="${f##*/}"
            [[ $mask == *",$b,"* ]] && continue
            [[ -e "$dir/$b" ]] || ln -sf "$f" "$dir/$b" 2>/dev/null
        done
    done
    printf '%s' "$dir"
}

setup_fixtures() {
    rm -rf "$FIXTURES"; mkdir -p "$FIXTURES/home"
    # Runtime matrix. The version boundary in v3 §1 is wrong (verified against a real
    # install: 11.2.1 ships Jython and runs .py under Jython 2.7.3), so these fixtures
    # pin the corrected behaviour: probe the shipped feature dir first, version only as
    # a fallback with the boundary at 11.3.
    mk_fake_ghidra "$FIXTURES/ghidra_11.1.2_PUBLIC" 11.1.2 Jython            # 11.x + Jython
    mk_fake_ghidra "$FIXTURES/ghidra_10.3_PUBLIC"   10.3   Jython            # 10.x + Jython
    mk_fake_ghidra "$FIXTURES/ghidra_11.3_PUBLIC"   11.3   PyGhidra          # 11.3+ PyGhidra
    mk_fake_ghidra "$FIXTURES/ghidra_both_PUBLIC"   11.2.1 Jython PyGhidra   # both installed
    mk_fake_ghidra "$FIXTURES/ghidra_bare11_PUBLIC" 11.1.2                   # neither -> version
    mk_fake_ghidra "$FIXTURES/ghidra_bare113_PUBLIC" 11.3                    # neither -> version
    # A separate root holding two generations, for the install-root scan and newest-wins.
    mk_fake_ghidra "$FIXTURES/optroot/ghidra_10.4_PUBLIC"   10.4   Jython
    mk_fake_ghidra "$FIXTURES/optroot/ghidra_11.2.1_PUBLIC" 11.2.1 Jython
    # Point discovery away from the real /opt so a Ghidra installed on the build box
    # cannot make the "Ghidra absent" tests silently pass.
    export PF_OPT_ROOT="$FIXTURES/empty-opt"
    mkdir -p "$FIXTURES/empty-opt"
}

# ======================================================================================
# Sections
# ======================================================================================
test_lint() {
    section "lint (shellcheck -S style)"
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip "shellcheck" "not installed"; return
    fi
    local out
    out=$(cd "$ROOT" && shellcheck -S style revctf install.sh lib/*.sh tools/*.sh \
              .claude/cloud-setup.sh 2>&1)
    if [[ -z $out ]]; then
        ok "0 findings across all shell files"
    else
        no "shellcheck findings" "$(head -6 <<< "$out")"
    fi
}

test_m0() {
    section "M0 — CLI surface, dispatch, config"

    assert_exit "revctf -h prints usage"          0 "$RC" -h
    assert_exit "revctf --version"                0 "$RC" --version
    assert_exit "no args prints usage"            0 "$RC"
    assert_match "usage lists every flag group"   'AGENCY & INTERACTIVITY' "$RC" -h

    assert_exit "unknown subcommand rejected"     1 "$RC" frobnicate
    assert_exit "unknown option rejected"         1 "$RC" scan "$ROOT/README.md" --nope
    assert_exit "missing target rejected"         1 "$RC" scan
    assert_exit "nonexistent target rejected"     1 "$RC" scan /no/such/file
    assert_exit "two targets rejected"            1 "$RC" scan "$ROOT/README.md" "$ROOT/install.sh"
    assert_exit "flag without its value"          1 "$RC" scan "$ROOT/README.md" --output
    assert_exit "non-numeric --timeout"           1 "$RC" scan "$ROOT/README.md" --timeout abc
    assert_exit "zero --timeout"                  1 "$RC" scan "$ROOT/README.md" --timeout 0
    assert_exit "non-numeric --jobs-light"        1 "$RC" scan "$ROOT/README.md" --jobs-light x
    assert_exit "malformed --maxmem-ghidra"       1 "$RC" scan "$ROOT/README.md" --maxmem-ghidra 99Q
    assert_exit "invalid --flag-format ERE"       1 "$RC" scan "$ROOT/README.md" --flag-format 'a[b'
    assert_exit "unreadable --ghidra-script"      1 "$RC" scan "$ROOT/README.md" --ghidra-script /no/such.py
    assert_exit "--light + --force conflict"      1 "$RC" scan "$ROOT/README.md" --light-decompile --force-full-decompile
    assert_exit "--skip-ghidra + --force"         1 "$RC" scan "$ROOT/README.md" --skip-ghidra --force-full-decompile
    assert_exit "missing --config rejected"       1 "$RC" scan "$ROOT/README.md" --config /no/such/config

    # v5 §3.3 / §3.4: these warn, they must not be fatal.
    assert_match "-i + -y warns, --yes wins" 'mutually exclusive' \
        "$RC" scan "$ROOT/README.md" -i -y --skip-ghidra
    assert_match "--sandbox + --skip-ltrace notice" 'no-op with --skip-ltrace' \
        "$RC" scan "$ROOT/README.md" --sandbox --skip-ltrace --skip-ghidra

    # --- config file: allowlist + precedence ---
    local cfg="$REVCTF_HOME/config"
    mkdir -p "$REVCTF_HOME"
    cat > "$cfg" <<'EOF'
output_dir = /tmp/from-config
tui        = 0
bogus_key  = 1
a line with no equals sign
EOF
    assert_match "config: unknown key warned"    "ignoring unknown key 'bogus_key'" \
        "$RC" scan "$ROOT/README.md" --skip-ghidra
    assert_match "config: malformed line warned" 'ignoring malformed line' \
        "$RC" scan "$ROOT/README.md" --skip-ghidra
    assert_match "config: value applied"         'output *: /tmp/from-config' \
        "$RC" scan "$ROOT/README.md" --skip-ghidra --verbose
    assert_match "config: CLI flag overrides it" 'output *: /tmp/from-cli' \
        "$RC" scan "$ROOT/README.md" --skip-ghidra --verbose --output /tmp/from-cli
    rm -f "$cfg"
    assert_exit "absent default config is fine"  0 "$RC" scan "$ROOT/README.md" --skip-ghidra

    # --- display mode selection (v6 §10) ---
    assert_match "piped output -> line mode" 'display *: line' \
        "$RC" scan "$ROOT/README.md" --skip-ghidra --verbose
    if command -v script >/dev/null 2>&1; then
        assert_match "TTY -> tui mode" 'display *: tui' \
            script -qec "$RC scan $ROOT/README.md --skip-ghidra --verbose" /dev/null
        assert_match "TTY + --no-tui -> line mode" 'display *: line' \
            script -qec "$RC scan $ROOT/README.md --skip-ghidra --verbose --no-tui" /dev/null
    else
        skip "TTY display-mode tests" "no 'script' command"
    fi

    # --- symlink resolution (install.sh puts revctf on PATH as a symlink) ---
    local linkdir="$FIXTURES/linkbin"
    mkdir -p "$linkdir"; ln -sf "$RC" "$linkdir/revctf"
    assert_exit "runs correctly through a symlink" 0 "$linkdir/revctf" scan "$ROOT/README.md" --skip-ghidra
}

test_m1() {
    section "M1 — preflight & dependency detection"

    # --- Ghidra discovery: all three documented paths ---
    assert_match "Ghidra via GHIDRA_HOME" 'ghidra +: 11\.1\.2' \
        env GHIDRA_HOME="$FIXTURES/ghidra_11.1.2_PUBLIC" \
        "$RC" scan "$ROOT/README.md" --verbose
    assert_match "Ghidra via PATH" 'ghidra +: 11\.1\.2' \
        env PATH="$FIXTURES/ghidra_11.1.2_PUBLIC/support:$PATH" \
        "$RC" scan "$ROOT/README.md" --verbose

    # --- post-script runtime selection ---
    # Regression guard for a real bug: v3 §1's "11.x+ -> PyGhidra" boundary would hand a
    # Python-3 script to Jython 2.7 on Ghidra 11.0-11.2. Selection now probes the shipped
    # feature directory, with a corrected 11.3 version fallback.
    assert_match "11.x shipping Jython -> jython script" 'ghidra script +: jython' \
        env GHIDRA_HOME="$FIXTURES/ghidra_11.1.2_PUBLIC" \
        "$RC" scan "$ROOT/README.md" --verbose
    assert_match "10.x shipping Jython -> jython script" 'ghidra script +: jython' \
        env GHIDRA_HOME="$FIXTURES/ghidra_10.3_PUBLIC" \
        "$RC" scan "$ROOT/README.md" --verbose
    assert_match "11.3 shipping PyGhidra -> pyghidra script" 'ghidra script +: pyghidra' \
        env GHIDRA_HOME="$FIXTURES/ghidra_11.3_PUBLIC" \
        "$RC" scan "$ROOT/README.md" --verbose
    assert_match "both runtimes -> pyghidra" 'ghidra script +: pyghidra' \
        env GHIDRA_HOME="$FIXTURES/ghidra_both_PUBLIC" \
        "$RC" scan "$ROOT/README.md" --verbose
    assert_match "both runtimes -> notice explains the choice" 'ships both PyGhidra and Jython' \
        env GHIDRA_HOME="$FIXTURES/ghidra_both_PUBLIC" \
        "$RC" scan "$ROOT/README.md" --verbose
    assert_match "no feature dir, 11.1.2 -> version fallback picks jython" 'ghidra script +: jython' \
        env GHIDRA_HOME="$FIXTURES/ghidra_bare11_PUBLIC" \
        "$RC" scan "$ROOT/README.md" --verbose
    assert_match "no feature dir, 11.3 -> version fallback picks pyghidra" 'ghidra script +: pyghidra' \
        env GHIDRA_HOME="$FIXTURES/ghidra_bare113_PUBLIC" \
        "$RC" scan "$ROOT/README.md" --verbose

    # --- discovery under $PF_OPT_ROOT, newest generation winning ---
    assert_match "Ghidra found by scanning the install root" 'ghidra +: 11\.2\.1' \
        env -u GHIDRA_HOME PF_OPT_ROOT="$FIXTURES/optroot" \
        "$RC" scan "$ROOT/README.md" --verbose
    assert_match "newest of several installs is chosen" 'Multiple Ghidra installs' \
        env -u GHIDRA_HOME PF_OPT_ROOT="$FIXTURES/optroot" \
        "$RC" scan "$ROOT/README.md" --verbose

    # --- Ghidra genuinely absent ---
    local nog; nog=$(mk_masked_path "analyzeHeadless" nog)
    assert_match "missing Ghidra -> actionable error" 'Ghidra not found' \
        env -u GHIDRA_HOME PATH="$nog" "$RC" scan "$ROOT/README.md"
    assert_exit  "missing Ghidra -> exit 1" 1 \
        env -u GHIDRA_HOME PATH="$nog" "$RC" scan "$ROOT/README.md"
    assert_exit  "--skip-ghidra runs without it" 0 \
        env -u GHIDRA_HOME "$RC" scan "$ROOT/README.md" --skip-ghidra

    # --- missing tools: core vs install.sh-managed, with the right advice each time ---
    local nocore; nocore=$(mk_masked_path "radare2,rabin2" nocore)
    assert_match "missing core tool named" 'radare2 +— stage 8' \
        env PATH="$nocore" "$RC" scan "$ROOT/README.md" --skip-ghidra
    assert_match "missing core tool -> apt hint" 'install: apt install radare2' \
        env PATH="$nocore" "$RC" scan "$ROOT/README.md" --skip-ghidra
    assert_exit  "missing core tool -> exit 1" 1 \
        env PATH="$nocore" "$RC" scan "$ROOT/README.md" --skip-ghidra

    local nofloss; nofloss=$(mk_masked_path "floss" nofloss)
    assert_match "missing D7 tool -> points at install.sh" 're-run it \(while online\)' \
        env PATH="$nofloss" "$RC" scan "$ROOT/README.md" --skip-ghidra
    # FLOSS is pip-in-a-venv, not apt — the hint must not say "apt install".
    assert_no_match "FLOSS hint is not an apt line" 'install: apt install flare-floss' \
        env PATH="$nofloss" "$RC" scan "$ROOT/README.md" --skip-ghidra
    assert_match "FLOSS hint gives the venv recipe" 'venv .*flare-floss' \
        env PATH="$nofloss" "$RC" scan "$ROOT/README.md" --skip-ghidra

    # --- binwalk: numeric major comparison, never a "3." substring test (v3 §4.9) ---
    assert_match "binwalk version detected + branch chosen" \
        'binwalk +: [0-9]+\.[0-9.]+ \(major [0-9]+ -> (v3\+|legacy) parsing\)' \
        "$RC" scan "$ROOT/README.md" --skip-ghidra --verbose

    # --- disk space ---
    assert_match "disk space reported" 'free disk +: [0-9]+MB' \
        "$RC" scan "$ROOT/README.md" --skip-ghidra --verbose
    assert_exit  "insufficient disk -> exit 1" 1 \
        env PF_MIN_DISK_MB=99999999 "$RC" scan "$ROOT/README.md" --skip-ghidra

    # --- systemd-run probe reports one of the two documented modes (v4 §4.3) ---
    assert_match "memory-bounding mode reported" \
        'memory bounding +: (systemd-run \(RSS\)|ulimit -v \(VSZ, best-effort\))' \
        "$RC" scan "$ROOT/README.md" --skip-ghidra --verbose
}

test_corpus() {
    section "test corpus integrity"
    if ! have_corpus; then
        skip "corpus checks" "run ./tools/build-test-corpus.sh first"; return
    fi

    local n
    n=$(strings -a "$CORPUS/planted_flag" | grep -c 'flag{pl41nt3xt')
    if [[ $n -ge 1 ]]; then
        ok "planted_flag exposes its flag to strings"
    else
        no "planted_flag" "flag not visible to strings"
    fi

    n=$(strings -a "$CORPUS/packed_upx" | grep -c 'flag{cr4ckm3')
    if [[ $n -eq 0 ]]; then
        ok "packed_upx hides its flag while packed"
    else
        no "packed_upx" "flag visible without unpacking"
    fi

    if command -v upx >/dev/null 2>&1; then
        cp "$CORPUS/packed_upx" "$FIXTURES/rt" 2>/dev/null
        if upx -d -q "$FIXTURES/rt" >/dev/null 2>&1 &&
           strings -a "$FIXTURES/rt" | grep -q 'flag{cr4ckm3'; then
            ok "packed_upx round-trips through upx -d"
        else
            no "packed_upx" "unpack did not recover the flag"
        fi
        cp "$CORPUS/packed_upx_broken" "$FIXTURES/rtb" 2>/dev/null
        if upx -d -q "$FIXTURES/rtb" >/dev/null 2>&1; then
            no "packed_upx_broken" "expected unpack to fail"
        else
            ok "packed_upx_broken fails to unpack (deliberate)"
        fi
    else
        skip "upx round-trip" "upx not installed"
    fi

    n=$(strings -a "$CORPUS/stack_string" | grep -c 'flag{st4ck')
    if [[ $n -eq 0 ]]; then
        ok "stack_string is invisible to strings"
    else
        no "stack_string" "flag was contiguous in the binary"
    fi

    for f in b64_flag rot13_flag hex_flag; do
        n=$(strings -a "$CORPUS/$f" | grep -c 'flag{')
        if [[ $n -eq 0 ]]; then
            ok "$f contains no plaintext flag"
        else
            no "$f" "a plaintext flag leaked into the binary"
        fi
    done

    n=$(strings -a "$CORPUS/hex_noise_noflag" | grep -c 'flag{')
    if [[ $n -eq 0 ]]; then
        ok "hex_noise_noflag is a clean negative control"
    else
        no "hex_noise_noflag" "control sample contains a flag"
    fi

    n=$(nm "$CORPUS/crackme" 2>/dev/null | grep -c domain_main_init)
    if [[ $n -ge 1 ]]; then
        ok "crackme carries the domain_main_init near-miss symbol"
    else
        no "crackme" "near-miss symbol missing; \\bmain\\b test is toothless"
    fi

    if nm "$CORPUS/crackme_stripped" 2>&1 | grep -q 'no symbols'; then
        ok "crackme_stripped has no symbol table"
    else
        no "crackme_stripped" "still has symbols; entry0 fallback untested"
    fi

    n=$(dd if="$CORPUS/large_blob.bin" bs=1 skip=190000000 count=24 status=none 2>/dev/null)
    if [[ $n == 'flag{str34m3d_fr0m_d33p}' ]]; then
        ok "large_blob.bin has its deep planted flag"
    else
        no "large_blob.bin" "planted flag not at offset 190000000"
    fi
}

test_m2() {
    section "M2 — triage/unwrap + light static stages"

    if ! have_corpus; then
        skip "M2 checks" "run ./tools/build-test-corpus.sh first"; return
    fi

    local o="$FIXTURES/m2"
    rm -rf "$o"; mkdir -p "$o"
    # M2 has no Ghidra stage yet, but preflight still demands one unless told otherwise.
    local -a RUN=("$RC" scan --skip-ghidra)

    # --- every stage produces output on a plain ELF ---
    local out; out=$("${RUN[@]}" "$CORPUS/crackme" --output "$o/crackme" 2>&1)
    local st
    for st in triage file strings binwalk hexdump checksec objdump; do
        if [[ -s "$o/crackme/$st.txt" ]]; then
            ok "stage $st produced output"
        else
            no "stage $st" "no capture at $o/crackme/$st.txt"
        fi
    done
    if grep -qE '^(triage|file|strings|binwalk|hexdump|checksec|objdump) +(ok|empty)' <<< "$out"; then
        ok "all light stages report a non-failed status"
    else
        no "stage statuses" "$(grep -E 'failed' <<< "$out" | head -2)"
    fi

    # --- captures must be plain text (v6 §10) ---
    if ! grep -rqP '\x1b\[' "$o/crackme/" 2>/dev/null; then
        ok "captures contain no ANSI escape sequences"
    else
        no "plain-text captures" "escape codes in $(grep -rlP '\x1b\[' "$o/crackme/" 2>/dev/null | head -1)"
    fi

    # --- format classification across the corpus ---
    local f fmt want pair
    for pair in "crackme:elf" "winsample.exe:pe" "challenge.jar:java" \
                "secret.pyc:pyc" "archive_challenge.zip:archive"; do
        f="${pair%%:*}"; want="${pair##*:}"
        [[ -f "$CORPUS/$f" ]] || { skip "classify $f" "not in corpus"; continue; }
        "${RUN[@]}" "$CORPUS/$f" --output "$o/$f" >/dev/null 2>&1
        fmt=$(sed -n 's/^Classified as: //p' "$o/$f/triage.txt" 2>/dev/null | head -1)
        if [[ $fmt == "$want" ]]; then
            ok "classified $f as $want"
        else
            no "classify $f" "got '$fmt', wanted '$want'"
        fi
    done

    # --- format-inappropriate stages skip rather than fail ---
    if grep -q 'not applicable to a java target' <<< "$(cat "$o/challenge.jar"/*.txt 2>/dev/null)$( "${RUN[@]}" "$CORPUS/challenge.jar" --output "$o/jar2" 2>&1)"; then
        ok "checksec/objdump skip a Java target rather than failing"
    else
        no "java skip" "expected a skip note for the java target"
    fi

    # --- unwrap: the packed sample ---
    "${RUN[@]}" "$CORPUS/packed_upx" --output "$o/packed" >/dev/null 2>&1
    if grep -q 'Unwrap *: OK' "$o/packed/triage.txt" 2>/dev/null; then
        ok "packed_upx is unpacked by Stage 0"
    else
        no "unwrap" "$(grep -m1 Unwrap "$o/packed/triage.txt" 2>/dev/null)"
    fi
    if grep -q 'flag{cr4ckm3' "$o/packed/strings.txt" 2>/dev/null; then
        ok "unwrapping reveals a flag that was hidden while packed"
    else
        no "unwrap payoff" "flag not visible in the strings capture after unwrap"
    fi

    # --- the original file is never modified (Stage 0 invariant) ---
    local before after
    before=$(md5sum < "$CORPUS/packed_upx")
    "${RUN[@]}" "$CORPUS/packed_upx" --output "$o/packed2" >/dev/null 2>&1
    after=$(md5sum < "$CORPUS/packed_upx")
    if [[ $before == "$after" ]]; then
        ok "the original target is left byte-identical"
    else
        no "original untouched" "checksum changed across a scan"
    fi

    # --- unwrap failure isolates: stage fails, pipeline continues ---
    out=$("${RUN[@]}" "$CORPUS/packed_upx_broken" --output "$o/broken" 2>&1)
    if grep -qE '^triage +failed' <<< "$out"; then
        ok "an unpackable packed target marks triage failed"
    else
        no "unwrap failure" "triage did not report failed"
    fi
    if grep -qE '^(strings|objdump) +ok' <<< "$out"; then
        ok "later stages still run after a triage failure (v5 §4.1)"
    else
        no "isolate-and-continue" "the pipeline stopped after the triage failure"
    fi
    if grep -q 'checksum error' "$o/broken/triage.txt" 2>/dev/null; then
        ok "the real upx diagnostic reaches the report"
    else
        no "diagnostic" "upx's error message was not preserved"
    fi

    # --- --no-unwrap ---
    "${RUN[@]}" "$CORPUS/packed_upx" --no-unwrap --output "$o/nounwrap" >/dev/null 2>&1
    if grep -q 'disabled (--no-unwrap)' "$o/nounwrap/triage.txt" 2>/dev/null; then
        ok "--no-unwrap disables Stage 0 unwrapping"
    else
        no "--no-unwrap" "unwrap was not disabled"
    fi

    # --- hexdump preview cap vs --full-hexdump ---
    local prev full
    prev=$(stat -c '%s' "$o/crackme/hexdump.txt" 2>/dev/null || echo 0)
    "${RUN[@]}" "$CORPUS/crackme" --full-hexdump --output "$o/fullhex" >/dev/null 2>&1
    full=$(stat -c '%s' "$o/fullhex/hexdump.txt" 2>/dev/null || echo 0)
    if [[ $full -gt $prev ]]; then
        ok "--full-hexdump produces a larger dump than the capped preview ($prev -> $full bytes)"
    else
        no "hexdump cap" "full dump ($full) was not larger than the preview ($prev)"
    fi

    # --- binwalk version branch actually ran and validated ---
    if [[ -s "$o/crackme/binwalk.txt" ]]; then
        ok "binwalk produced a validated capture"
    else
        no "binwalk" "no output captured"
    fi

    # --- streaming discipline: a 220MB target must not be buffered in memory ---
    if [[ -f $CORPUS/large_blob.bin ]] && command -v /usr/bin/time >/dev/null 2>&1; then
        local peak_kb
        peak_kb=$(/usr/bin/time -f '%M' "${RUN[@]}" "$CORPUS/large_blob.bin" \
                    --output "$o/large" 2>&1 >/dev/null | tail -1)
        if [[ $peak_kb =~ ^[0-9]+$ ]] && [[ $peak_kb -lt 262144 ]]; then
            ok "220MB target scanned with peak RSS ${peak_kb}KB (< 256MB — streaming holds)"
        else
            no "streaming" "peak RSS was ${peak_kb}KB, expected well under 256MB"
        fi
    else
        skip "streaming memory test" "large_blob.bin or /usr/bin/time missing"
    fi
}

# Regression guards for the QA review. Every check here corresponds to a defect that was
# reproduced against a real build — they exist so none of them can come back.
test_qa() {
    section "QA regressions"

    if ! have_corpus; then
        skip "QA regressions" "run ./tools/build-test-corpus.sh first"; return
    fi

    local o="$FIXTURES/qa"; rm -rf "$o"; mkdir -p "$o"
    local cfg="$o/cfg" out

    # --- QA-1 (critical): a config boolean written as a word aborted the shell under
    # `set -u`. `full_hexdump = on` did it from INSIDE a stage, where isolate-and-continue
    # cannot catch it, and stranded the work directory.
    printf 'tui = yes\n' > "$cfg"
    assert_exit "config boolean 'yes' is accepted, not fatal" 0 \
        "$RC" scan "$CORPUS/crackme" --skip-ghidra --config "$cfg" --output "$o/c1"
    printf 'full_hexdump = on\n' > "$cfg"
    assert_exit "config boolean 'on' does not kill a stage" 0 \
        "$RC" scan "$CORPUS/crackme" --skip-ghidra --config "$cfg" --output "$o/c2"
    printf 'tui = banana\n' > "$cfg"
    assert_match "an invalid boolean warns and falls back" 'expects a yes/no value' \
        "$RC" scan "$CORPUS/crackme" --skip-ghidra --config "$cfg" --output "$o/c3"
    printf 'timeout = soon\n' > "$cfg"
    assert_match "an invalid integer warns and falls back" 'expects a whole number' \
        "$RC" scan "$CORPUS/crackme" --skip-ghidra --config "$cfg" --output "$o/c4"

    # --- QA-2: no work directory may survive any exit path (there was no EXIT trap).
    rm -rf /tmp/revctf-work.* 2>/dev/null
    printf 'tui = banana\n' > "$cfg"
    "$RC" scan "$CORPUS/crackme" --skip-ghidra --config "$cfg" --output "$o/c5" >/dev/null 2>&1
    if [[ $(find /tmp -maxdepth 1 -name 'revctf-work.*' 2>/dev/null | wc -l) -eq 0 ]]; then
        ok "no work directory is stranded on exit"
    else
        no "work dir leak" "revctf-work.* survived the run"
        rm -rf /tmp/revctf-work.* 2>/dev/null
    fi

    # --- QA-3 (high): a container holding a UPX-packed member was itself declared packed,
    # which aborted extraction and reported a plain tar as an unreadable packed binary.
    tar cf "$o/container.tar" -C "$CORPUS" packed_upx planted_flag 2>/dev/null
    out=$("$RC" scan "$o/container.tar" --skip-ghidra --output "$o/tar" 2>&1)
    if grep -qE '^triage +ok' <<< "$out"; then
        ok "a tar containing a UPX member is not mistaken for a packed binary"
    else
        no "UPX over-detection" "$(grep -m1 '^triage' <<< "$out")"
    fi
    if grep -q 'Routing' "$o/tar/triage.txt" 2>/dev/null; then
        ok "the triage Routing section is still written for a container"
    else
        no "missing Routing section" "triage.txt has no Routing block"
    fi

    # --- QA-4 (medium): Mach-O universal binaries share magic 0xCAFEBABE with Java
    # .class, and were being routed to the Java decompiler.
    python3 -c "
import struct
d = struct.pack('>II', 0xCAFEBABE, 1) + struct.pack('>IIIII', 7, 3, 4096, 4096, 12) + b'\0'*4096
open('$o/fat.macho','wb').write(d)" 2>/dev/null
    assert_match "Mach-O universal is not misclassified as Java" 'format: macho' \
        "$RC" scan "$o/fat.macho" --skip-ghidra --output "$o/macho"

    # --- QA-5 (high): STAGE_SECS was only written by stage_capture, so every other stage
    # reported a fabricated 0 — a 71-second binwalk showed as instant.
    if [[ -f $CORPUS/large_blob.bin ]]; then
        out=$("$RC" scan "$CORPUS/large_blob.bin" --skip-ghidra --output "$o/secs" 2>&1)
        local bw
        bw=$(grep -E '^binwalk ' <<< "$out" | awk '{print $3}')
        if [[ ${bw:-0} -gt 0 ]]; then
            ok "stage timing is real, not fabricated (binwalk reported ${bw}s)"
        else
            no "fabricated timing" "binwalk on a 220MB target reported ${bw}s"
        fi
    else
        skip "timing check" "large_blob.bin missing"
    fi

    # --- QA-6 (medium): captures are 0600, per v4 §5. They were inheriting umask (0644).
    rm -rf "$o/perm"
    "$RC" scan "$CORPUS/crackme" --skip-ghidra --output "$o/perm" >/dev/null 2>&1
    if [[ $(stat -c '%a' "$o/perm/strings.txt" 2>/dev/null) == 600 ]]; then
        ok "capture files are 0600"
    else
        no "capture permissions" "got $(stat -c '%a' "$o/perm/strings.txt" 2>/dev/null), want 600"
    fi
    if [[ $(stat -c '%a' "$o/perm" 2>/dev/null) == 700 ]]; then
        ok "a created output directory is 0700"
    else
        no "output dir permissions" "got $(stat -c '%a' "$o/perm" 2>/dev/null), want 700"
    fi

    # --- QA-7 (medium): revctf silently chmodded a pre-existing --output directory to 700,
    # which would lock other users out of a shared or published location.
    rm -rf "$o/pre"; mkdir -p "$o/pre"; chmod 755 "$o/pre"
    "$RC" scan "$CORPUS/crackme" --skip-ghidra --output "$o/pre" >/dev/null 2>&1
    if [[ $(stat -c '%a' "$o/pre") == 755 ]]; then
        ok "a pre-existing output directory keeps its mode"
    else
        no "output dir mode changed" "revctf altered a directory it did not create"
    fi

    # --- QA-8 (high): FIFOs and character devices were accepted, then blocked or streamed
    # forever. /dev/zero wedged a scan for the full 300s strings timeout.
    local fifo="$o/fifo"; mkfifo "$fifo" 2>/dev/null
    assert_exit  "a FIFO target is rejected"             1 "$RC" scan "$fifo" --skip-ghidra
    assert_match "the FIFO rejection says what it is"    'named pipe' "$RC" scan "$fifo" --skip-ghidra
    assert_exit  "a character device is rejected"        1 "$RC" scan /dev/zero --skip-ghidra
    assert_match "the device rejection says what it is"  'character device' "$RC" scan /dev/zero --skip-ghidra

    # --- QA-9 (high): archive extraction was unbounded. A 1MB zip wrote 1GB into the work
    # directory with no check of expansion or free space.
    python3 -c "
import zipfile
z = zipfile.ZipFile('$o/bomb.zip','w',zipfile.ZIP_DEFLATED,compresslevel=9)
z.writestr('big', b'\0'*(3*1024*1024*1024))
z.close()" 2>/dev/null
    if [[ -f $o/bomb.zip ]]; then
        "$RC" scan "$o/bomb.zip" --skip-ghidra --output "$o/bomb" >/dev/null 2>&1
        if grep -q 'over the .*MB limit' "$o/bomb/triage.txt" 2>/dev/null; then
            ok "a decompression bomb is refused before extraction"
        else
            no "bomb guard" "3GB expansion was not refused"
        fi
    else
        skip "decompression bomb" "could not build the fixture"
    fi

    # --- QA-10 (medium): every scan exited 0, so nothing could tell a clean run from one
    # where every stage failed.
    assert_exit "a clean scan exits 0" 0 \
        "$RC" scan "$CORPUS/crackme" --skip-ghidra --output "$o/x1"
    assert_exit "a scan with a failed stage exits 2" 2 \
        "$RC" scan "$CORPUS/packed_upx_broken" --skip-ghidra --output "$o/x2"
    assert_exit "a usage error still exits 1" 1 "$RC" scan --nope

    # --- QA-11 (medium): `output_dir = ~/reports` created a literal "~" directory.
    printf 'output_dir = ~/revctf-qa-tilde\n' > "$cfg"
    assert_match "a tilde in the config output_dir is expanded" "captures: $HOME/revctf-qa-tilde" \
        "$RC" scan "$CORPUS/crackme" --skip-ghidra --config "$cfg"
    rm -rf "$HOME/revctf-qa-tilde" ./~ 2>/dev/null

    # --- QA-12 (high): an abort left the running tool as an orphan, because bash defers
    # a trap until the foreground command finishes — measured at ~77s of apparent hang.
    #
    # SIGTERM is used rather than SIGINT: POSIX requires a non-interactive shell to make a
    # background job ignore SIGINT, and bash then refuses to install the trap, so an
    # INT-based test can only ever fail here. That limit is real and documented in --help;
    # SIGTERM exercises the identical abort path and is the correct way to stop a
    # backgrounded revctf.
    if [[ -f $CORPUS/large_blob.bin ]]; then
        rm -rf /tmp/revctf-work.* 2>/dev/null
        # The signal deliberately lands during binwalk — the slowest stage on this target,
        # and the one that used to run its tool in the foreground and swallow the signal.
        "$RC" scan "$CORPUS/large_blob.bin" --skip-ghidra --output "$o/int" >/dev/null 2>&1 &
        local pid=$! started=$SECONDS
        sleep 6
        kill -TERM "$pid" 2>/dev/null
        sleep 2
        # `wait` must run in THIS shell: inside $( ) it is a subshell that cannot reap the
        # parent's child and returns -1 regardless of how the job exited.
        local irc=0
        wait "$pid" 2>/dev/null || irc=$?
        local elapsed=$(( SECONDS - started ))
        if [[ $irc -eq 143 ]]; then
            ok "SIGTERM exits 143 (128+15)"
        else
            no "abort exit code" "got $irc, want 143"
        fi
        if [[ $elapsed -lt 20 ]]; then
            ok "an abort is honoured promptly (${elapsed}s, was ~77s)"
        else
            no "abort latency" "took ${elapsed}s to stop; a stage is swallowing the signal"
        fi
        # shellcheck disable=SC2009
        if [[ $(ps -eo args 2>/dev/null | grep -c '^binwalk') -eq 0 ]]; then
            ok "an abort leaves no orphaned tool process"
        else
            no "orphan after abort" "a binwalk process survived"
            pkill -KILL -f '^binwalk' 2>/dev/null
        fi
        if [[ $(find /tmp -maxdepth 1 -name 'revctf-work.*' 2>/dev/null | wc -l) -eq 0 ]]; then
            ok "an abort leaves no work directory"
        else
            no "work dir after abort" "revctf-work.* survived"
            rm -rf /tmp/revctf-work.* 2>/dev/null
        fi

        # SIGHUP must be trapped too: an untrapped HUP from a dropped SSH session killed
        # the scan with no cleanup at all.
        rm -rf /tmp/revctf-work.* 2>/dev/null
        "$RC" scan "$CORPUS/large_blob.bin" --skip-ghidra --output "$o/hup" >/dev/null 2>&1 &
        local hpid=$!
        sleep 6
        kill -HUP "$hpid" 2>/dev/null
        sleep 2
        local hrc=0
        wait "$hpid" 2>/dev/null || hrc=$?
        if [[ $hrc -eq 129 ]]; then
            ok "SIGHUP is trapped and exits 129 (a dropped terminal cleans up)"
        else
            no "SIGHUP handling" "got $hrc, want 129"
        fi
        rm -rf /tmp/revctf-work.* 2>/dev/null
    else
        skip "abort tests" "large_blob.bin missing"
    fi

    # --- QA-13: hostile filenames must never reach a shell.
    local nasty="$o/a;touch $o/PWNED;b"
    cp "$CORPUS/crackme" "$nasty" 2>/dev/null
    "$RC" scan "$nasty" --skip-ghidra --output "$o/nasty" >/dev/null 2>&1
    if [[ ! -e "$o/PWNED" ]]; then
        ok "a filename containing shell metacharacters is not executed"
    else
        no "command injection" "a filename was interpreted by a shell"
    fi
}

# ======================================================================================
# Real-Ghidra checks. Skipped entirely when no install is present, so the harness stays
# useful on a box without one.
test_ghidra() {
    section "real Ghidra (skipped if absent)"

    local gh=""
    if [[ -n ${GHIDRA_HOME:-} && -x ${GHIDRA_HOME}/support/analyzeHeadless ]]; then
        gh="$GHIDRA_HOME/support/analyzeHeadless"
    else
        gh=$(find "${PF_OPT_ROOT_REAL:-/opt}" -maxdepth 3 -name analyzeHeadless -type f 2>/dev/null | sort -rV | head -1)
    fi
    if [[ -z $gh ]]; then
        skip "real Ghidra checks" "no Ghidra install found"; return
    fi

    local root; root="$(cd -- "$(dirname -- "$gh")/.." && pwd)"
    printf '  using: %s\n' "$root"

    # Detection must agree with what the install actually ships.
    local shipped=""
    [[ -d $root/Ghidra/Features/PyGhidra ]] && shipped="pyghidra"
    [[ -d $root/Ghidra/Features/Jython   ]] && shipped="jython"
    if [[ -n $shipped ]]; then
        assert_match "detected runtime matches the shipped feature dir" \
            "ghidra script +: $shipped" \
            env GHIDRA_HOME="$root" "$RC" scan "$ROOT/README.md" --verbose
    else
        skip "runtime agreement" "install ships neither feature dir"
    fi

    if ! have_corpus; then
        skip "headless analysis" "corpus not built"; return
    fi

    # The real thing: headless import + analysis, with the throwaway project deleted.
    local proj="$FIXTURES/ghidraproj" out
    rm -rf "$proj"; mkdir -p "$proj"
    out=$(timeout 900 "$gh" "$proj" HarnessProj \
            -import "$CORPUS/crackme" -deleteProject 2>&1)
    if grep -q 'Analysis succeeded' <<< "$out"; then
        ok "headless analysis succeeds on the corpus crackme"
    else
        no "headless analysis" "$(tail -3 <<< "$out")"
    fi
    if [[ -z $(find "$proj" -name '*.rep' -o -name '*.gpr' 2>/dev/null) ]]; then
        ok "-deleteProject leaves no project behind"
    else
        no "-deleteProject" "project artifacts survived in $proj"
    fi
}

# ======================================================================================
main() {
    local -a want=("$@")
    [[ ${#want[@]} -eq 0 ]] && want=(lint corpus m0 m1 m2 qa ghidra)

    printf '\033[1mrevctf verification harness\033[0m\n'
    printf 'repo: %s\n' "$ROOT"
    setup_fixtures

    local s
    for s in "${want[@]}"; do
        case "$s" in
            lint)   test_lint   ;;
            corpus) test_corpus ;;
            m0)     test_m0     ;;
            m1)     test_m1     ;;
            m2)     test_m2     ;;
            qa)     test_qa     ;;
            ghidra) test_ghidra ;;
            *)      printf 'unknown section: %s\n' "$s" >&2 ;;
        esac
    done

    printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
    if [[ $FAIL -gt 0 ]]; then
        printf 'failed:\n'; printf '  - %s\n' "${FAILURES[@]}"
        return 1
    fi
    return 0
}

main "$@"
