#!/usr/bin/env bash
# lib/stage_triage.sh — Stage 0: detect the real payload, and unwrap it.
#
# Implemented in: M2.  Deviation D3 (v6 §4.1).
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`.
#
# Why this runs before everything else: `strings`, `radare2` and Ghidra pointed at a
# UPX-packed binary, a .jar, or a zip produce confident, wrong output — which is worse
# than no output, because it reads like a clean negative. Stage 0 resolves what the
# target actually is and, where it can, produces the real payload for the rest of the
# pipeline to analyse.
#
# Invariants:
#   - The user's original file is NEVER modified. Every unwrap writes to a copy under
#     RUN_WORKDIR.
#   - A failed unwrap is a stage failure, not a file failure: the report says the target
#     is packed and its static results are unreliable, and analysis continues on the
#     original bytes. (This path is not hypothetical — upx 4.2.2 cannot unpack a PIE ELF,
#     and PIE is the default on modern Kali. See implementation-notes.md.)
#   - Recursion into containers is capped at TRIAGE_MAX_DEPTH.

TRIAGE_MAX_DEPTH="${TRIAGE_MAX_DEPTH:-2}"

# Read by lib/report.sh and the orchestrator; shellcheck cannot see across sourced files.
# shellcheck disable=SC2034
declare -g TRIAGE_UNWRAPPED=0        # 1 when RUN_TARGET != RUN_ORIGINAL
declare -g TRIAGE_METHOD=""          # upx | archive | pyinstaller | ""
declare -ga TRIAGE_MEMBERS=()        # extracted members worth analysing separately

# ======================================================================================
# Format classification
# ======================================================================================
# `file` output is the primary signal, with magic-byte checks where `file` is ambiguous
# (a .jar is "Zip archive data" to older file(1); a .NET assembly is just "PE32+").
_triage_classify() {
    local t="$1" desc magic
    desc=$(file -b "$t" 2>/dev/null)

    # First four bytes, as hex, for the cases `file` does not disambiguate.
    magic=$(head -c 4 "$t" 2>/dev/null | od -An -tx1 | tr -d ' \n')

    case "$magic" in
        cafebabe)  printf 'java';  return 0 ;;   # raw .class
        7f454c46)  # ELF — but a Go/Rust binary is still ELF, so no further branching
                   printf 'elf';   return 0 ;;
    esac

    case "$desc" in
        *"ELF "*)                     printf 'elf' ;;
        *"Mach-O"*)                   printf 'macho' ;;
        *"Java archive"*|*"Java class"*) printf 'java' ;;
        *"Byte-compiled Python"*|*"python 2"*|*"python 3"*) printf 'pyc' ;;
        *"PE32"*|*"MS-DOS executable"*)
            if _triage_is_dotnet "$t"; then printf 'dotnet'; else printf 'pe'; fi ;;
        *"Zip archive"*)
            if _triage_zip_has_classes "$t"; then printf 'java'; else printf 'archive'; fi ;;
        *"gzip compressed"*|*"POSIX tar"*|*"XZ compressed"*|*"bzip2 compressed"*|\
        *"7-zip archive"*|*"Squashfs"*|*"cpio archive"*|*"RAR archive"*)
            printf 'archive' ;;
        *)                            printf 'other' ;;
    esac
    return 0
}

# A .NET assembly is a PE whose optional header carries a CLI/CLR data directory.
# `rabin2 -I` reports it, which is cheaper and more reliable than parsing headers here.
_triage_is_dotnet() {
    local t="$1"
    rabin2 -I "$t" 2>/dev/null | grep -qiE '^(lang|bintype).*(cil|dotnet|\.net)' && return 0
    strings -a "$t" 2>/dev/null | grep -qm1 '_CorExeMain\|mscoree.dll' && return 0
    return 1
}

_triage_zip_has_classes() {
    command -v 7z >/dev/null 2>&1 || return 1
    7z l -ba "$1" 2>/dev/null | grep -qm1 '\.class$'
}

# ======================================================================================
# Packer detection
# ======================================================================================
_triage_packer() {
    local t="$1"
    if upx -t "$t" >/dev/null 2>&1; then printf 'upx'; return 0; fi
    # `upx -t` fails on a packed-but-corrupt image too, so fall back to the stub marker.
    if grep -qa 'UPX!' "$t" 2>/dev/null; then printf 'upx'; return 0; fi
    printf ''
    return 1
}

# ======================================================================================
# Unwrap actions
# ======================================================================================
# Each returns 0 on success with RUN_TARGET repointed, non-zero on failure with a reason
# in TRIAGE_FAIL_REASON. None of them touches RUN_ORIGINAL.
declare -g TRIAGE_FAIL_REASON=""

_triage_unwrap_upx() {
    local copy
    copy="$RUN_WORKDIR/unpacked.$(basename -- "$RUN_ORIGINAL")"
    cp -- "$RUN_TARGET" "$copy" 2>/dev/null || {
        TRIAGE_FAIL_REASON="could not copy the target into the work directory"; return 1; }

    local err rc=0
    err=$(timeout -k 5 "$ST_T_UNWRAP" upx -d -q "$copy" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        # upx 4.2.2 fails here on any PIE ELF with "Exception: checksum error". Report
        # the real message rather than a generic failure so the user can tell a genuine
        # corruption apart from this known upx limitation.
        # upx prints a listing table before the real message, so pick the diagnostic
        # line rather than flattening the whole thing into one unreadable blob.
        local msg
        msg=$(grep -aoiEm1 '(exception|error)[^\n]*' <<< "$err" | head -c 120)
        [[ -z $msg ]] && msg=$(grep -av '^[[:space:]]*$' <<< "$err" | tail -1 | head -c 120)
        TRIAGE_FAIL_REASON="upx -d exited $rc — ${msg:-no diagnostic output}"
        rm -f "$copy"
        return 1
    fi
    RUN_TARGET="$copy"
    TRIAGE_METHOD="upx"
    TRIAGE_UNWRAPPED=1
    return 0
}

_triage_unwrap_archive() {
    pf_require_tool 7z >/dev/null 2>&1 || {
        TRIAGE_FAIL_REASON="7z is required to extract archives but is not installed"; return 1; }

    local dir="$RUN_WORKDIR/extracted"
    mkdir -p "$dir" || { TRIAGE_FAIL_REASON="could not create the extraction directory"; return 1; }

    if ! timeout -k 5 "$ST_T_UNWRAP" 7z x -y -o"$dir" -- "$RUN_TARGET" >/dev/null 2>&1; then
        TRIAGE_FAIL_REASON="7z could not extract this container"
        return 1
    fi

    # Collect the members worth analysing: executables and other binaries, biggest first,
    # so a report on a firmware image leads with the substantial payload rather than a
    # stray config file.
    local f
    while IFS= read -r f; do
        TRIAGE_MEMBERS+=("$f")
    done < <(find "$dir" -type f -size +0 -printf '%s\t%p\n' 2>/dev/null \
             | sort -rn | cut -f2- | head -50)

    [[ ${#TRIAGE_MEMBERS[@]} -gt 0 ]] || {
        TRIAGE_FAIL_REASON="the container extracted but held no files"; return 1; }

    TRIAGE_METHOD="archive"
    TRIAGE_UNWRAPPED=1
    # The container itself stays RUN_TARGET; members are analysed as their own targets by
    # the orchestrator, which is what keeps recursion depth explicit.
    return 0
}

_triage_unwrap_pyinstaller() {
    local dir="$RUN_WORKDIR/pyinst"
    mkdir -p "$dir" || { TRIAGE_FAIL_REASON="could not create the extraction directory"; return 1; }

    # PyInstaller archives are readable by python's own tooling when pyinstxtractor is
    # unavailable, but extraction quality differs enough that the dedicated tool wins.
    if command -v pyinstxtractor >/dev/null 2>&1; then
        ( cd "$dir" && timeout -k 5 "$ST_T_UNWRAP" pyinstxtractor "$RUN_TARGET" >/dev/null 2>&1 )
    elif python3 -c 'import PyInstaller' >/dev/null 2>&1; then
        TRIAGE_FAIL_REASON="pyinstxtractor is not installed"
        return 1
    else
        TRIAGE_FAIL_REASON="pyinstxtractor is not installed"
        return 1
    fi

    local f
    while IFS= read -r f; do TRIAGE_MEMBERS+=("$f"); done \
        < <(find "$dir" -type f \( -name '*.pyc' -o -name '*.pyz' \) 2>/dev/null | head -50)

    [[ ${#TRIAGE_MEMBERS[@]} -gt 0 ]] || {
        TRIAGE_FAIL_REASON="no Python bytecode was recovered from the bundle"; return 1; }

    TRIAGE_METHOD="pyinstaller"
    TRIAGE_UNWRAPPED=1
    return 0
}

_triage_is_pyinstaller() {
    grep -qam1 'pyi-\|PyInstaller\|MEIPASS' "$1" 2>/dev/null
}

# ======================================================================================
# The stage
# ======================================================================================
stage_triage() {
    local name="triage"
    local out; out="$(stage_out_path "$name")"
    local size desc packer

    # TRIAGE_* are read by lib/report.sh and the orchestrator, which shellcheck
    # cannot see from here.
    # shellcheck disable=SC2034
    TRIAGE_UNWRAPPED=0
    # shellcheck disable=SC2034
    TRIAGE_METHOD=""
    TRIAGE_MEMBERS=()
    TRIAGE_FAIL_REASON=""

    size=$(st_file_size "$RUN_ORIGINAL")
    desc=$(file -b "$RUN_ORIGINAL" 2>/dev/null)
    RUN_FORMAT=$(_triage_classify "$RUN_ORIGINAL")

    {
        printf 'Target       : %s\n' "$RUN_ORIGINAL"
        printf 'Size         : %s (%s bytes)\n' "$(st_human_size "$size")" "$size"
        printf 'file(1)      : %s\n' "${desc:-unknown}"
        printf 'Classified as: %s\n' "$RUN_FORMAT"
    } > "$out"

    if [[ ${OPT[no_unwrap]:-0} -eq 1 ]]; then
        printf 'Unwrap       : disabled (--no-unwrap)\n' >> "$out"
        stage_write "$name" ok
        stage_set_status "$name" ok "unwrap disabled by --no-unwrap"
        return 0
    fi

    # --- packers first: a packed archive is still packed ---
    packer=$(_triage_packer "$RUN_ORIGINAL")
    if [[ -n $packer ]]; then
        printf 'Packer       : %s detected\n' "$packer" >> "$out"
        if _triage_unwrap_upx; then
            printf 'Unwrap       : OK — analysing the unpacked image\n' >> "$out"
            printf 'Unpacked to  : %s (%s)\n' \
                "$RUN_TARGET" "$(st_human_size "$(st_file_size "$RUN_TARGET")")" >> "$out"
            # Re-classify: the unpacked image is what matters from here on.
            RUN_FORMAT=$(_triage_classify "$RUN_TARGET")
            printf 'Reclassified : %s\n' "$RUN_FORMAT" >> "$out"
        else
            {
                printf 'Unwrap       : FAILED — %s\n' "$TRIAGE_FAIL_REASON"
                printf '\n'
                printf 'This target is packed and could not be unpacked automatically.\n'
                printf 'Static results below are read from the packer stub, not the real\n'
                printf 'program, so treat missing strings and empty disassembly as\n'
                printf 'unreliable rather than as evidence of nothing being there.\n'
                printf 'Next steps: unpack it manually (upx -d), or dump the process\n'
                printf 'image after the stub decompresses it at runtime.\n'
            } >> "$out"
            stage_write "$name" failed
            stage_set_status "$name" failed \
                "target is $packer-packed and could not be unpacked: $TRIAGE_FAIL_REASON"
            return 0
        fi
    fi

    # --- containers and managed/bytecode formats ---
    case "$RUN_FORMAT" in
        archive)
            if _triage_unwrap_archive; then
                {
                    printf 'Unwrap       : extracted %d member(s), depth cap %d\n' \
                        "${#TRIAGE_MEMBERS[@]}" "$TRIAGE_MAX_DEPTH"
                    printf 'Members      :\n'
                    printf '  %s\n' "${TRIAGE_MEMBERS[@]:0:20}"
                    if [[ ${#TRIAGE_MEMBERS[@]} -gt 20 ]]; then
                        printf '  ... and %d more\n' $(( ${#TRIAGE_MEMBERS[@]} - 20 ))
                    fi
                } >> "$out"
            else
                printf 'Unwrap       : FAILED — %s\n' "$TRIAGE_FAIL_REASON" >> "$out"
                stage_write "$name" failed
                stage_set_status "$name" failed "container not extracted: $TRIAGE_FAIL_REASON"
                return 0
            fi
            ;;
        pe|dotnet)
            if _triage_is_pyinstaller "$RUN_ORIGINAL"; then
                RUN_FORMAT="pyinstaller"
                printf 'Detected     : PyInstaller bundle\n' >> "$out"
                if _triage_unwrap_pyinstaller; then
                    printf 'Unwrap       : recovered %d bytecode file(s)\n' "${#TRIAGE_MEMBERS[@]}" >> "$out"
                else
                    printf 'Unwrap       : FAILED — %s\n' "$TRIAGE_FAIL_REASON" >> "$out"
                fi
            fi
            ;;
        elf)
            if _triage_is_pyinstaller "$RUN_ORIGINAL"; then
                RUN_FORMAT="pyinstaller"
                printf 'Detected     : PyInstaller bundle (ELF host)\n' >> "$out"
                _triage_unwrap_pyinstaller \
                    && printf 'Unwrap       : recovered %d bytecode file(s)\n' "${#TRIAGE_MEMBERS[@]}" >> "$out" \
                    || printf 'Unwrap       : FAILED — %s\n' "$TRIAGE_FAIL_REASON" >> "$out"
            fi
            ;;
    esac

    # --- routing summary: which later stages this classification enables or skips ---
    {
        printf '\nRouting\n'
        case "$RUN_FORMAT" in
            elf)    printf '  native ELF — full static pipeline, ltrace and strace enabled\n' ;;
            pe)     printf '  native PE — full static pipeline, FLOSS in all modes, no ltrace/strace\n' ;;
            dotnet) printf '  .NET assembly — routed to managed decompilation; native disassembly is not useful\n' ;;
            java)   printf '  Java bytecode — routed to managed decompilation; native disassembly is not useful\n' ;;
            pyc)    printf '  Python bytecode — routed to Python decompilation\n' ;;
            pyinstaller) printf '  PyInstaller bundle — extracted bytecode routed to Python decompilation\n' ;;
            archive) printf '  container — members analysed individually\n' ;;
            macho)  printf '  Mach-O — static stages only; ltrace and strace do not apply\n' ;;
            *)      printf '  unrecognised format — running the format-agnostic stages only\n' ;;
        esac
    } >> "$out"

    stage_write "$name" ok
    return 0
}
