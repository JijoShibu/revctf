#!/usr/bin/env bash
# Controlled inputs exercise saved evidence and actual candidate records.
# shellcheck disable=SC1091,SC2034,SC2329
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/revctf-accuracy.XXXXXX") || exit 1
source "$ROOT/lib/stage.sh"
source "$ROOT/lib/flagscan.sh"
source "$ROOT/lib/stage_pydecomp.sh"
source "$ROOT/lib/stage_managed.sh"
declare -A OPT=([flag_scan]=1 [flag_format]='')
REVCTF_SCRIPTS="$ROOT/scripts"
PASS=0 FAIL=0 SKIP=0
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
check() {
    local label="$1"; shift
    if ( "$@" ); then printf 'PASS %s\n' "$label"; PASS=$((PASS + 1));
    else
        local rc=$?
        if [[ $rc == 77 ]]; then printf 'SKIP %s (Linux required)\n' "$label"; SKIP=$((SKIP + 1));
        else printf 'FAIL %s\n' "$label"; FAIL=$((FAIL + 1)); fi
    fi
}
setup() {
    [[ $(uname -s) == Linux ]] || return 77
    RUN_OUTDIR="$WORK/$1/out"; RUN_WORKDIR="$WORK/$1/tmp"
    mkdir -p "$RUN_OUTDIR" "$RUN_WORKDIR"
    STAGE_ORDER=(strings); STAGE_OUT=([strings]="$RUN_OUTDIR/strings.txt")
    ST_MEM_MODE="ulimit"; ST_MEM_CEIL_MB=128
    printf 'no candidate\n' > "$RUN_OUTDIR/strings.txt"
}
has() { printf '%s\n' "${FLAG_HITS[@]}" | cut -f4- | grep -Fxq -- "$1"; }
test_hex() {
    setup hex || return
    # One contiguous flag and one separated by a zero byte.
    printf '%s\n' '666c61677b6865785f6f6b7d' '666c61677b73706c6974006e6f747265616c7d' > "$RUN_OUTDIR/strings.txt"
    flagscan_run
    [[ ${STAGE_STATUS[flagscan]} == ok ]] && has 'flag{hex_ok}' && ! has 'flag{splitnotreal}'
}
test_late() {
    setup late || return
    python3 - "$RUN_OUTDIR/strings.txt" <<'PY'
import base64
import sys
with open(sys.argv[1], 'w') as out:
    for i in range(450):
        out.write(base64.b64encode(('noise%06dwithoutanswer' % i).encode()).decode() + '\n')
    out.write(base64.b64encode(b'flag{after_old_token_cap}').decode() + '\n')
    out.write('short\n' * 710000)
    out.write('synt{nsgre_byq_ebg_pnc}\n')
PY
    flagscan_run
    [[ ${STAGE_STATUS[flagscan]} == ok ]] && has 'flag{after_old_token_cap}' && has 'flag{after_old_rot_cap}'
}
test_timeout() {
    setup timeout || return
    mkdir "$RUN_WORKDIR/bin"
    printf '#!/bin/bash\nsleep 10\n' > "$RUN_WORKDIR/bin/base64"
    chmod +x "$RUN_WORKDIR/bin/base64"
    PATH="$RUN_WORKDIR/bin:$PATH"
    printf 'flag{early_complete}\nZmFrZSBsb25nIGVuY29kZWQgdG9rZW4=\n' > "$RUN_OUTDIR/strings.txt"
    ST_T_FLAGSCAN=1
    flagscan_run
    [[ ${STAGE_STATUS[flagscan]} == partial && ${STAGE_RC[flagscan]} == 124 ]] &&
        has 'flag{early_complete}' && stage_incomplete
}
test_mixed() {
    local order="$1"
    setup "mixed-$order" || return
    RUN_FORMAT=pyinstaller
    touch "$RUN_WORKDIR/good.pyc" "$RUN_WORKDIR/bad.pyc"
    TRIAGE_MEMBERS=("$RUN_WORKDIR/$order.pyc")
    if [[ $order == good ]]; then TRIAGE_MEMBERS+=("$RUN_WORKDIR/bad.pyc");
    else TRIAGE_MEMBERS+=("$RUN_WORKDIR/good.pyc"); fi
    mkdir "$RUN_WORKDIR/bin"
    cat > "$RUN_WORKDIR/bin/pycdc" <<'SH'
#!/bin/bash
if [[ $1 == *bad.pyc ]]; then printf 'preserved error\n' >&2; exit 1; fi
printf 'flag{python_known_answer}\n'
SH
    chmod +x "$RUN_WORKDIR/bin/pycdc"
    PATH="$RUN_WORKDIR/bin:$PATH"
    stage_run pydecomp 'bytecode test' stage_pydecomp
    [[ ${STAGE_STATUS[pydecomp]} == partial ]] || return 1
    flagscan_run
    has 'flag{python_known_answer}' && grep -q 'preserved error' "$RUN_OUTDIR/pydecomp.stderr"
}
test_file_cap() {
    setup cap || return
    RUN_FORMAT=pyinstaller; PYDECOMP_MAX_FILES=1
    touch "$RUN_WORKDIR/a.pyc" "$RUN_WORKDIR/b.pyc"
    TRIAGE_MEMBERS=("$RUN_WORKDIR/a.pyc" "$RUN_WORKDIR/b.pyc")
    mkdir "$RUN_WORKDIR/bin"
    printf '#!/bin/bash\nprintf "flag{first_file}\\n"\n' > "$RUN_WORKDIR/bin/pycdc"
    chmod +x "$RUN_WORKDIR/bin/pycdc"; PATH="$RUN_WORKDIR/bin:$PATH"
    stage_run pydecomp 'file cap test' stage_pydecomp
    [[ ${STAGE_STATUS[pydecomp]} == partial && -s $RUN_OUTDIR/pydecomp-1.txt && ! -e $RUN_OUTDIR/pydecomp-2.txt ]]
}
test_managed() {
    setup managed || return
    RUN_FORMAT=java; RUN_TARGET="$RUN_WORKDIR/sample.jar"; touch "$RUN_TARGET"
    mkdir "$RUN_WORKDIR/bin"
    cat > "$RUN_WORKDIR/bin/jd-cli" <<'SH'
#!/bin/bash
for ((i=0;i<6100;i++)); do printf 'line\n'; done
printf 'flag{after_preview}\n'
SH
    chmod +x "$RUN_WORKDIR/bin/jd-cli"; PATH="$RUN_WORKDIR/bin:$PATH"
    stage_run managed 'managed test' stage_managed
    [[ ${STAGE_STATUS[managed]} == ok ]] || return 1
    ! grep -q 'flag{after_preview}' "$RUN_OUTDIR/managed.txt" || return 1
    flagscan_run
    [[ ${STAGE_STATUS[flagscan]} == ok ]] && has 'flag{after_preview}'
}
check 'hex decoding preserves byte boundaries' test_hex
check 'encoded answers beyond old token and byte caps survive' test_late
check 'search timeout retains early candidates and reports partial' test_timeout
check 'Python success followed by failure remains partial' test_mixed good
check 'Python failure followed by success remains partial' test_mixed bad
check 'Python file cap reports incomplete work' test_file_cap
check 'managed preview cutoff preserves the actual later answer' test_managed
printf '\n%d passed; %d failed; %d skipped. Artifacts: %s\n' "$PASS" "$FAIL" "$SKIP" "$WORK"
[[ $FAIL == 0 ]]
