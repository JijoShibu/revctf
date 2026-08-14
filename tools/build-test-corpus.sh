#!/usr/bin/env bash
#
# build-test-corpus.sh — regenerate the local test corpus.
#
# Execution masterplan M0 requires a test corpus that every downstream DoD gate is
# verified against, kept OUT of version control. This generator is committed instead of
# the binaries: it is reproducible, self-documenting, and avoids shipping executables in
# the repo.
#
#   ./tools/build-test-corpus.sh [outdir]     # default: ./test-corpus
#
# Groups:
#   A  the five binaries named in the execution masterplan
#   B  targets for the v6 triage/unwrap layer and stages 11-12 (deviations D2/D3)
#   C  flag-detection edge cases, incl. the encoding sweep (D5) and false positives
#   D  stress cases for streaming (M2) and the watchdog (M5)
#
# Requires: gcc, x86_64-w64-mingw32-gcc, javac/jar, zip, upx, python3.
set -uo pipefail

OUT="${1:-$(pwd)/test-corpus}"
SRC="$OUT/.src"
mkdir -p "$SRC" || exit 1

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[33m  skip:\033[0m %s\n' "$*"; }
made() { printf '  made  %-22s %s\n' "$1" "$(file -b "$OUT/$1" 2>/dev/null | cut -c1-58)"; }

need() { command -v "$1" >/dev/null 2>&1; }

# ======================================================================================
say "Group A — execution masterplan's five"
# ======================================================================================

# A1/A2: a crackme with real symbols, and a stripped twin. The stripped copy is what
# proves radare2's entry0 fallback works (M3 DoD).
cat > "$SRC/crackme.c" <<'EOF'
#include <stdio.h>
#include <string.h>

static int check_password(const char *input) {
    const char *secret = "sw0rdf1sh";
    return strcmp(input, secret) == 0;
}

/* Deliberate near-miss symbol: proves the \bmain\b word-boundary fix (v3 §4 item 10)
   is actually needed — a substring match would find this instead of main(). */
int domain_main_init(void) { return 0; }

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <password>\n", argv[0]); return 1; }
    if (check_password(argv[1])) { printf("Correct! flag{cr4ckm3_s0lv3d}\n"); return 0; }
    printf("Wrong password.\n");
    return 1;
}
EOF
gcc -O0 -no-pie -o "$OUT/crackme" "$SRC/crackme.c" 2>/dev/null && made crackme
cp "$OUT/crackme" "$OUT/crackme_stripped" 2>/dev/null && strip -s "$OUT/crackme_stripped" && made crackme_stripped

# A3: PE. Cross-compiled so `file` classification and non-ELF ltrace skipping are real.
cat > "$SRC/winsample.c" <<'EOF'
#include <stdio.h>
static const char *note = "flag{p3_f0rm4t_h4ndl3d}";
int main(void) { printf("windows sample %s\n", note); return 0; }
EOF
if need x86_64-w64-mingw32-gcc; then
    x86_64-w64-mingw32-gcc -o "$OUT/winsample.exe" "$SRC/winsample.c" 2>/dev/null && made winsample.exe
else
    skip "winsample.exe (no mingw)"
fi

# A4: plain planted flag in .rodata — the M3/M4 High-confidence detection test.
cat > "$SRC/planted.c" <<'EOF'
#include <stdio.h>
const char *banner  = "RevCTF sample challenge v1";
const char *hidden  = "flag{pl41nt3xt_1n_r0d4t4}";
int main(void) { printf("%s\n", banner); return 0; }
EOF
gcc -O0 -o "$OUT/planted_flag" "$SRC/planted.c" 2>/dev/null && made planted_flag

# A5: hangs forever. Proves ltrace's timeout + orphan process-group sweep (M3 DoD).
cat > "$SRC/hung.c" <<'EOF'
#include <unistd.h>
#include <stdio.h>
int main(void) {
    printf("hanging now\n"); fflush(stdout);
    for (;;) { sleep(3600); }
}
EOF
gcc -O0 -o "$OUT/hung" "$SRC/hung.c" 2>/dev/null && made hung

# ======================================================================================
say "Group B — triage/unwrap targets (v6 D2/D3)"
# ======================================================================================

# B1: UPX-packed. Without Stage 0 unwrap, every static stage reads packer stub garbage.
#
# Packed from `crackme`, which is built -no-pie deliberately: upx 4.2.2 packs a PIE ELF
# happily but `upx -d` then fails with "Exception: checksum error", so a PIE source would
# make this a broken-unpack fixture rather than a working-unpack one. See B1b below for
# the deliberate failure case.
if need upx; then
    if cp "$OUT/crackme" "$OUT/packed_upx" 2>/dev/null &&
       upx -q -9 "$OUT/packed_upx" >/dev/null 2>&1; then
        made packed_upx
    else
        skip "packed_upx (upx pack failed)"
    fi

    # B1b: packs, but will NOT unpack (PIE + upx 4.2.2 checksum bug). Exercises Stage 0's
    # unwrap-failure path: mark the stage failed, then continue analysis on the original
    # bytes rather than aborting the file.
    if cp "$OUT/planted_flag" "$OUT/packed_upx_broken" 2>/dev/null &&
       upx -q -9 "$OUT/packed_upx_broken" >/dev/null 2>&1; then
        made packed_upx_broken
    else
        skip "packed_upx_broken"
    fi
else
    skip "packed_upx (no upx)"
fi

# B2: Java jar with the flag in a string constant — stage 11 (managed decompile).
if need javac && need jar; then
    mkdir -p "$SRC/java"
    cat > "$SRC/java/Challenge.java" <<'EOF'
public class Challenge {
    private static final String SECRET = "flag{j4v4_d3c0mp1l3d}";
    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("open")) System.out.println(SECRET);
        else System.out.println("Try again.");
    }
}
EOF
    if (cd "$SRC/java" && javac Challenge.java >/dev/null 2>&1 &&
        jar cfe "$OUT/challenge.jar" Challenge Challenge.class >/dev/null 2>&1); then
        made challenge.jar
    else
        skip "challenge.jar (javac/jar failed)"
    fi
else
    skip "challenge.jar (no JDK)"
fi

# B3: compiled Python — stage 12 (Python decompile).
cat > "$SRC/secret.py" <<'EOF'
FLAG = "flag{pyc_d3c0mp1l3d}"
def check(guess):
    return guess == FLAG
if __name__ == "__main__":
    print("locked")
EOF
if python3 -c "
import py_compile
py_compile.compile('$SRC/secret.py', cfile='$OUT/secret.pyc', doraise=True)
" 2>/dev/null; then
    made secret.pyc
else
    skip "secret.pyc"
fi

# B4/B5: archive containers — Stage 0 must recurse and analyze what's inside.
if need zip; then
    if (cd "$OUT" && zip -q archive_challenge.zip planted_flag crackme 2>/dev/null); then
        made archive_challenge.zip
    else
        skip "archive_challenge.zip"
    fi
fi
tar czf "$OUT/archive_challenge.tar.gz" -C "$OUT" planted_flag crackme 2>/dev/null \
    && made archive_challenge.tar.gz

# ======================================================================================
say "Group C — flag-detection edge cases (v6 §6, D5)"
# ======================================================================================

# C1: base64'd flag. The single most common CTF hiding trick; invisible to a plain
# regex scan, must be caught by the encoding sweep.
B64=$(printf 'flag{b4s3_s1xty_f0ur}' | base64 -w0)
cat > "$SRC/b64flag.c" <<EOF
#include <stdio.h>
const char *blob = "$B64";
int main(void) { printf("encoded payload present\n"); return 0; }
EOF
gcc -O0 -o "$OUT/b64_flag" "$SRC/b64flag.c" 2>/dev/null && made b64_flag

# C2: ROT13'd flag.
ROT=$(printf 'flag{r0t4t3d_thirt33n}' | tr 'A-Za-z' 'N-ZA-Mn-za-m')
cat > "$SRC/rot13flag.c" <<EOF
#include <stdio.h>
const char *blob = "$ROT";
int main(void) { printf("rotated payload present\n"); return 0; }
EOF
gcc -O0 -o "$OUT/rot13_flag" "$SRC/rot13flag.c" 2>/dev/null && made rot13_flag

# C3: hex-encoded flag.
HEX=$(printf 'flag{h3x_3nc0d3d_str1ng}' | od -An -tx1 | tr -d ' \n')
cat > "$SRC/hexflag.c" <<EOF
#include <stdio.h>
const char *blob = "$HEX";
int main(void) { printf("hex payload present\n"); return 0; }
EOF
gcc -O0 -o "$OUT/hex_flag" "$SRC/hexflag.c" 2>/dev/null && made hex_flag

# C4: stack-constructed string. Never appears contiguously in the binary, so plain
# `strings` cannot find it — this is what justifies the FLOSS stage (D2).
cat > "$SRC/stackstr.c" <<'EOF'
#include <stdio.h>
#include <string.h>
int main(void) {
    volatile char b[32];
    int i = 0;
    b[i++]='f'; b[i++]='l'; b[i++]='a'; b[i++]='g'; b[i++]='{';
    b[i++]='s'; b[i++]='t'; b[i++]='4'; b[i++]='c'; b[i++]='k';
    b[i++]='_'; b[i++]='s'; b[i++]='t'; b[i++]='r'; b[i++]='1';
    b[i++]='n'; b[i++]='g'; b[i++]='}'; b[i]='\0';
    if (strlen((char*)b) == 18) printf("built\n");
    return 0;
}
EOF
gcc -O0 -fno-stack-protector -o "$OUT/stack_string" "$SRC/stackstr.c" 2>/dev/null && made stack_string

# C5: NO flag, but dense with hex blobs and GUIDs. This is the false-positive control
# for the hash/key-style pattern (v6 §6.1 ranking caveat). A well-behaved report must
# not present any of these as a High-confidence flag.
python3 - "$SRC/noise.c" <<'PY'
import sys, hashlib
lines = ['#include <stdio.h>']
for i in range(40):
    h = hashlib.sha256(str(i).encode()).hexdigest()
    lines.append(f'const char *h{i} = "{h}";')
    lines.append(f'const char *m{i} = "{hashlib.md5(str(i).encode()).hexdigest()}";')
lines.append('const char *guid = "550e8400-e29b-41d4-a716-446655440000";')
lines.append('int main(void){ printf("no flag here\\n"); return 0; }')
open(sys.argv[1], 'w').write('\n'.join(lines) + '\n')
PY
gcc -O0 -o "$OUT/hex_noise_noflag" "$SRC/noise.c" 2>/dev/null && made hex_noise_noflag

# ======================================================================================
say "Group D — stress cases"
# ======================================================================================

# D1: large file for M2's streaming-memory DoD (must not spike RSS).
if [[ ! -f "$OUT/large_blob.bin" ]]; then
    head -c 220000000 /dev/urandom > "$OUT/large_blob.bin" 2>/dev/null
    # Plant a flag deep inside so streaming correctness is checkable, not just memory use.
    printf 'flag{str34m3d_fr0m_d33p}' | dd of="$OUT/large_blob.bin" bs=1 seek=190000000 conv=notrunc status=none
    made large_blob.bin
fi

# D2: allocates aggressively — the M5 watchdog trigger target.
cat > "$SRC/memhog.c" <<'EOF'
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    for (;;) {
        char *p = malloc(64 * 1024 * 1024);
        if (!p) break;
        memset(p, 0xA5, 64 * 1024 * 1024);   /* touch it, so RSS actually grows */
        usleep(100000);
    }
    return 0;
}
EOF
gcc -O0 -o "$OUT/memhog" "$SRC/memhog.c" 2>/dev/null && made memhog

# ======================================================================================
say "Corpus summary"
printf '  %s\n' "$OUT"
find "$OUT" -maxdepth 1 -type f -printf '    %f\n' | sort
printf '  %d artifacts, %s total\n' \
    "$(find "$OUT" -maxdepth 1 -type f | wc -l)" "$(du -sh "$OUT" | cut -f1)"
