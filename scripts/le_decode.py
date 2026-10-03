#!/usr/bin/env python3
"""Recover stack strings from a disassembly or pseudo-C capture.

Read a stage capture on stdin (or from a path given as argv[1]); write the decoded runs on
stdout, one per line.

WHY THIS EXISTS
---------------
A stack string is assembled at runtime from immediate stores:

    local_38 = 0x4c75257240343a41;
    local_30 = 0x3062396630664634;

so it is invisible to `strings`, before or after unpacking. FLOSS is the tool that exists
to recover them, and its stack/tight/decoded modes are PE-only -- on an ELF it runs
`--only static`. The one tool in the pipeline built for this challenge class is
structurally unable to run on the most common file format revctf sees.

But the bytes are not missing. radare2 and Ghidra both already print them, and the flag
scanner already reads both captures. Those immediates are little-endian ASCII, so this is a
decoder over output the pipeline already produces -- not a new tool and not a new
dependency.

Measured against two real picoCTF 2022 challenges (unpackme-upx, bbbbloat): decoding alone
yields the ciphertext, because both pass the buffer through a rotate before printing. The
caller therefore also runs the result through ROT47, which recovers both flags exactly.
"""
import re
import sys

# Any 0x literal up to 8 bytes. Length is what separates signal from noise, but it cannot
# be a flat threshold in either direction:
#
#   - A run may only START at 8+ hex digits (4+ bytes). Shorter literals are overwhelmingly
#     offsets, register widths and small constants, and starting runs on them is noise.
#   - A run may be CONTINUED by a short one. The last store of a stack string is usually a
#     partial word: unpackme-upx ends with `local_1c = 0x4e`, two hex digits, which is the
#     closing brace of the flag. An 8-digit floor drops it and yields
#     `picoCTF{up><_m3_f7w_77ad107` -- a flag that looks complete and is not, which is a
#     worse failure than finding nothing.
IMM = re.compile(r'0x([0-9a-fA-F]{2,16})\b')
IMM_START_DIGITS = 8

# A run is only worth emitting if it could plausibly hold a wrapped flag.
MIN_RUN = 8
MAX_LINE = 65536
MAX_RUN = 4096


def decode(hexstr):
    """One immediate, little-endian, as text. '' if it is not plausibly ASCII."""
    if len(hexstr) % 2:
        hexstr = '0' + hexstr
    try:
        raw = bytes.fromhex(hexstr)[::-1]
    except ValueError:
        return ''
    # NULs are padding in a short trailing store, not a terminator to respect -- the flag
    # can continue in the next immediate.
    raw = raw.rstrip(b'\x00')
    if not raw:
        return ''
    # Reject anything not printable: a genuine stack string is text by construction, and
    # this is what keeps ordinary numeric constants out of the output.
    if not all(0x20 <= b <= 0x7e for b in raw):
        return ''
    return raw.decode('ascii')


def main():
    current = ''
    partial = False
    source = open(sys.argv[1], 'rb') if len(sys.argv) > 1 else sys.stdin.buffer

    def emit(run):
        if len(run) >= MIN_RUN:
            print(run, flush=True)

    while True:
        raw = source.readline(MAX_LINE + 1)
        if not raw:
            break
        if len(raw) > MAX_LINE:
            emit(current)
            current = ''
            partial = True
            while raw and not raw.endswith(b'\n'):
                raw = source.readline(MAX_LINE + 1)
            continue
        line = raw.decode('utf-8', 'replace')
        found = IMM.findall(line)
        if not found:
            emit(current)
            current = ''
            continue
        for h in found:
            if len(h) < IMM_START_DIGITS and not current:
                continue          # too short to begin a run
            piece = decode(h)
            if piece:
                if len(current) + len(piece) > MAX_RUN:
                    emit(current)
                    current = ''
                    partial = True
                current += piece
            elif current:
                emit(current)
                current = ''
    emit(current)
    if source is not sys.stdin.buffer:
        source.close()
    if partial:
        print('Stack-string search incomplete: an input line or reconstructed run exceeded its limit.', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
