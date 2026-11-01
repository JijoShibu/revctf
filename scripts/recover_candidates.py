#!/usr/bin/env python3
"""Bounded static reversal/XOR recovery. Never executes the supplied file."""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import time

WRAPPERS = (b'flag{', b'FLAG{', b'ctf{', b'CTF{', b'HTB{', b'THM{',
            b'picoCTF{', b'DUCTF{', b'uiuctf{', b'corctf{', b'SEE{',
            b'csawctf{', b'justCTF{', b'SPECTRONA{', b'CREST{', b'academy{')
FLAG = re.compile(rb'[A-Za-z0-9_]{2,32}\{[\x20-\x7c\x7e]{4,160}\}')
PRINTABLE = re.compile(rb'[\x20-\x7e]{6,240}')


def capture_runs(data):
    """Recover bounded byte arrays and adjacent Ghidra stack stores, without evaluation."""
    runs = []
    array = re.compile(rb'(?:byte|char|uint8_t)\s+\w+\s*\[[0-9 ]*\]\s*=\s*\{([^}]{1,32768})\}')
    for match in array.finditer(data):
        tokens = match[1].split(b',')
        try:
            values = [int(t.strip(), 16 if t.strip().lower().startswith(b'0x') else 10)
                      for t in tokens if t.strip()]
            if 6 <= len(values) <= 4096 and all(0 <= n <= 255 for n in values):
                runs.append((bytes(values), match.start()))
                if len(runs) >= 128:
                    return runs
        except ValueError:
            continue
    # Ghidra may render a stack array as one literal byte assignment per line.
    # Only consecutive stores starting at index zero form a run: never combine
    # across another statement, an index gap, another array or a control block.
    literal = rb'(0[xX][0-9a-fA-F]+|[0-9]+)'
    indexed = re.compile(rb'\b(local_[0-9a-fA-F]+)\s*\[\s*' + literal +
                         rb'\s*\]\s*=\s*' + literal + rb'\s*;')
    current, anchor, name, next_index, previous_end = b'', 0, None, 0, 0
    for match in indexed.finditer(data):
        index, value = (int(token, 16 if token.lower().startswith(b'0x') else 10)
                        for token in (match[2], match[3]))
        adjacent = (match[1] == name and index == next_index and
                    not data[previous_end:match.start()].strip())
        if not adjacent or not 0 <= value <= 255:
            if len(current) >= 6:
                runs.append((current, anchor))
            current, name, next_index = b'', None, 0
        if len(runs) >= 128:
            return runs[:128]
        if 0 <= value <= 255 and (adjacent or index == 0):
            if not current:
                anchor, name = match.start(), match[1]
            current += bytes([value])
            next_index = index + 1
            if len(current) >= 4096:
                runs.append((current, anchor))
                current, name, next_index = b'', None, 0
        previous_end = match.end()
    if len(current) >= 6:
        runs.append((current, anchor))
    if len(runs) >= 128:
        return runs[:128]
    store = re.compile(rb'\blocal_([0-9a-fA-F]+)\s*=\s*0x([0-9a-fA-F]{1,16})\s*;')
    current, anchor, previous_offset, previous_width, previous_end = b'', 0, None, 0, 0
    for match in store.finditer(data):
        offset = int(match[1], 16)
        width = (len(match[2]) + 1) // 2
        adjacent = previous_offset is not None and offset == previous_offset - previous_width
        # Do not combine declarations from separate functions/control-flow blocks.
        between = data[previous_end:match.start()]
        if not adjacent or b'{' in between or b'}' in between or len(between) > 256:
            if len(current) >= 6:
                runs.append((current, anchor))
            current, anchor = b'', match.start()
        current += int(match[2], 16).to_bytes(width, 'little')
        previous_offset, previous_width, previous_end = offset, width, match.end()
        if len(current) >= 4096:
            runs.append((current[:4096], anchor))
            current, previous_offset = b'', None
        if len(runs) >= 128:
            break
    if len(current) >= 6 and len(runs) < 128:
        runs.append((current, anchor))
    return runs[:128]


def recover(source, max_bytes=16 * 1024 * 1024, seconds=20, max_hits=1024, prefixes=(), original=None):
    """Return independent occurrences, including true byte offsets and key bytes."""
    started = time.monotonic()
    hits, seen, notes = [], set(), []
    size = os.stat(source).st_size
    wrappers = tuple(dict.fromkeys((*WRAPPERS, *prefixes)))
    derived = original is not None and not os.path.samefile(source, original)

    def emit(value, offset, transform, key=b''):
        if not FLAG.fullmatch(value):
            return
        # Decoding padding may yield printable identifier characters immediately
        # before a real wrapper. Preserve the broad hit and recognizable suffixes.
        values = [(value, offset)]
        brace = value.find(b'{')
        for prefix in wrappers:
            pos = value.find(prefix)
            if 0 < pos <= brace:
                values.append((value[pos:], offset + pos))
        for candidate, location in values:
            identity = (candidate, location, transform, key)
            if identity not in seen:
                seen.add(identity)
                hits.append(dict(value=candidate.decode('ascii'), source=str(source),
                                 byte_offset=location, transform=transform,
                                 key_hex=key.hex() or None, verified=False, derived_payload=derived))

    with open(source, 'rb') as stream:
        base = 0
        while base < min(size, max_bytes):
            stream.seek(base)
            data = stream.read(min(65536 + 240, max_bytes - base))
            if not data:
                break
            for match in PRINTABLE.finditer(data):
                original = match.group()
                for candidate in FLAG.finditer(original[::-1]):
                    offset = base + match.start() + len(original) - candidate.end()
                    emit(candidate.group(), offset, 'reverse')
            for key in range(1, 256):
                decoded = data.translate(bytes(n ^ key for n in range(256)))
                for match in FLAG.finditer(decoded):
                    emit(match.group(), base + match.start(), 'xor-single', bytes([key]))
                if len(hits) >= max_hits or time.monotonic() - started >= seconds:
                    notes.append('recovery time or candidate budget reached')
                    return hits[:max_hits], notes
            # Periodic XOR preserves the XOR difference at the key period. Searching
            # those differences avoids an exponential enumeration of possible keys.
            for period in range(2, 9):
                delta = bytes(a ^ b for a, b in zip(data, data[period:]))
                for prefix in wrappers:
                    if len(prefix) < period + 3:
                        continue
                    needle = bytes(a ^ b for a, b in zip(prefix, prefix[period:]))
                    pos = delta.find(needle)
                    while pos >= 0:
                        key = bytes(data[pos + j] ^ prefix[j] for j in range(period))
                        if any(key) and len(set(key)) > 1:
                            decoded = bytes(byte ^ key[j % period]
                                            for j, byte in enumerate(data[pos:pos + 200]))
                            match = FLAG.match(decoded)
                            if match:
                                emit(match.group(), base + pos, 'xor-repeating', key)
                        pos = delta.find(needle, pos + 1)
                        if len(hits) >= max_hits or time.monotonic() - started >= seconds:
                            notes.append('recovery time or candidate budget reached')
                            return hits[:max_hits], notes
            base += 65536
            if time.monotonic() - started >= seconds:
                notes.append('recovery time budget reached')
                break
    if size > max_bytes:
        notes.append(f'recovery inspected only the first {max_bytes} of {size} bytes')
    return hits, notes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--text', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--max-bytes', type=int, default=16 * 1024 * 1024)
    parser.add_argument('--seconds', type=float, default=20)
    parser.add_argument('--prefix', action='append', default=[])
    parser.add_argument('--flag-format', default='')
    parser.add_argument('--original', type=Path)
    parser.add_argument('--capture-mode', action='store_true')
    parser.add_argument('--stage', default='binary-recovery')
    parser.add_argument('--append-evidence', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.max_bytes <= 64 * 1024 * 1024 or not 0 < args.seconds <= 120:
        parser.error('invalid recovery budget')
    prefixes = [p.encode('ascii') for p in args.prefix if re.fullmatch(r'[A-Za-z0-9_]{2,32}\{', p)]
    # Read a literal wrapper hint; never compile or apply the user's ERE in Python.
    hint = re.match(r'\^?([A-Za-z0-9_]{2,32})\\?\{', args.flag_format)
    if hint:
        prefixes.append(hint[1].encode('ascii') + b'{')
    if args.capture_mode:
        with args.source.open('rb') as stream:
            data = stream.read(1024 * 1024 + 1)
        hits, notes, started = [], [], time.monotonic()
        if len(data) > 1024 * 1024:
            notes.append('reconstruction inspected only the first 1 MiB of the capture')
        with tempfile.TemporaryDirectory(prefix='fs.reconstruct.', dir=args.text.parent) as temporary:
            runs = capture_runs(data[:1024 * 1024])
            if len(runs) >= 128:
                notes.append('reconstructed-run limit reached; completeness unverified')
            for index, (raw, anchor) in enumerate(runs):
                remaining = args.seconds - (time.monotonic() - started)
                if remaining <= 0:
                    notes.append('capture reconstruction time budget reached')
                    break
                path = Path(temporary) / str(index)
                path.write_bytes(raw)
                recovered, limited = recover(path, seconds=remaining, prefixes=prefixes)
                for hit in recovered:
                    hit.update(source=str(args.source), stage=args.stage, derived_payload=True,
                               capture_anchor_byte_offset=anchor,
                               transform='reconstructed+' + hit['transform'])
                hits.extend(recovered)
                notes.extend(limited)
                if len(hits) >= 1024:
                    hits = hits[:1024]
                    notes.append('capture recovery candidate budget reached')
                    break
    else:
        hits, notes = recover(args.source, args.max_bytes, args.seconds, prefixes=prefixes,
                              original=args.original)
        for hit in hits:
            hit['stage'] = args.stage
    args.text.write_text(''.join(hit['value'] + '\n' for hit in hits), encoding='utf-8')
    with args.evidence.open('a' if args.append_evidence else 'w', encoding='utf-8') as out:
        for hit in hits:
            out.write(json.dumps(hit, ensure_ascii=True) + '\n')
    for note in notes:
        print('Recovery incomplete: ' + note, file=__import__('sys').stderr)
    return 3 if notes else 0


if __name__ == '__main__':
    raise SystemExit(main())
