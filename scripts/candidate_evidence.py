#!/usr/bin/env python3
"""Create additive, versioned provenance without changing four-field flag records."""
import argparse
import json
from pathlib import Path


def build(records, captures, recovery=None):
    candidates = {}
    locations = {}
    truncated = False
    ranks = {'low': 1, 'medium': 2, 'high': 3}
    with open(records, encoding='utf-8', errors='replace') as stream:
        for index, line in enumerate(stream):
            if not line.endswith('\n'):
                truncated = True
                break
            if index >= 10000:
                truncated = True
                break
            fields = line.rstrip('\n').split('\t', 3)
            if len(fields) != 4 or fields[0] not in ranks:
                continue
            confidence, stage, transform, value = fields
            item = candidates.setdefault(value, dict(value=value, confidence=confidence,
                                                     verified=False, occurrences=[]))
            if ranks[confidence] > ranks[item['confidence']]:
                item['confidence'] = confidence
            capture = captures.get(stage)
            occurrence = dict(stage=stage, transform=transform, capture=capture,
                              capture_byte_offset=None, binary_byte_offset=None)
            # Locate plain hits in bounded chunks; do not load a large capture into RAM.
            if capture and transform == 'plain':
                needle = value.encode('utf-8')
                cache_key = (capture, value)
                if cache_key not in locations:
                    found = set()
                    try:
                        with open(capture, 'rb') as source:
                            offset, tail = 0, b''
                            while len(found) < 1000:
                                data = source.read(65536)
                                if not data:
                                    break
                                joined = tail + data
                                pos = joined.find(needle)
                                while pos >= 0 and len(found) < 1000:
                                    found.add(offset - len(tail) + pos)
                                    pos = joined.find(needle, pos + 1)
                                offset += len(data)
                                tail = joined[-len(needle) + 1:] if len(needle) > 1 else b''
                            if len(found) >= 1000:
                                truncated = True
                    except OSError:
                        pass
                    locations[cache_key] = sorted(found)
                for location in locations[cache_key]:
                    located = dict(occurrence, capture_byte_offset=location)
                    if located not in item['occurrences']:
                        item['occurrences'].append(located)
                if locations[cache_key]:
                    continue
            if occurrence not in item['occurrences']:
                item['occurrences'].append(occurrence)
    if recovery and Path(recovery).exists():
        with open(recovery, encoding='utf-8') as stream:
            for line in stream:
                if not line.endswith('\n'):
                    truncated = True
                    break
                try:
                    hit = json.loads(line)
                except json.JSONDecodeError:
                    truncated = True
                    continue
                if hit['value'] in candidates:
                    candidates[hit['value']]['occurrences'].append(dict(
                        stage=hit.get('stage', 'binary-recovery'), transform=hit['transform'],
                        capture=hit['source'], capture_byte_offset=None,
                        capture_anchor_byte_offset=hit.get('capture_anchor_byte_offset'),
                        binary_byte_offset=None if hit.get('derived_payload') else hit['byte_offset'],
                        analyzed_payload_byte_offset=hit['byte_offset'],
                        derived_payload=hit.get('derived_payload', False), key_hex=hit['key_hex']))
    return dict(schema_version=1, provenance_complete=not truncated,
                limits=['At most 1000 plain locations per value and capture; 10000 input records.'],
                candidates=list(candidates.values()),
                location_policy='Capture and derived-payload offsets are not original-input offsets; null means unknown.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--records', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--capture', action='append', nargs=2, default=[])
    parser.add_argument('--recovery')
    parser.add_argument('--search-incomplete', action='store_true')
    args = parser.parse_args()
    result = build(args.records, dict(args.capture), args.recovery)
    result['search_complete'] = not args.search_incomplete
    result['search_scope'] = 'available preserved captures and bounded recovery; not an exhaustive solver'
    temporary = args.output.with_name(args.output.name + '.tmp')
    temporary.write_text(json.dumps(result, ensure_ascii=True, indent=2) + '\n', encoding='utf-8')
    temporary.replace(args.output)
    return 0 if result['provenance_complete'] else 3


if __name__ == '__main__':
    raise SystemExit(main())
