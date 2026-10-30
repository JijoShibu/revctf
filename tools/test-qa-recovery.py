#!/usr/bin/env python3
"""Controlled regressions for recovery, provenance, format routing and safe archives."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recovery = load('recover_candidates')
evidence = load('candidate_evidence')
extractor = load('safe_extract')
source_review = load('source_review')


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.work = Path(temp.name)

    def recover(self, data, **kwargs):
        path = self.work / 'target; $(not_a_command)'
        path.write_bytes(data)
        return recovery.recover(path, **kwargs)

    def test_single_byte_all_key_extremes_and_offsets(self):
        value = b'SPECTRONA{bounded_single_byte}'
        for key in (1, 0x5a, 255):
            hits, notes = self.recover(b'\0' * 17 + bytes(b ^ key for b in value) + b'\0')
            self.assertFalse(notes)
            self.assertTrue(any(h['value'] == value.decode() and h['byte_offset'] == 17
                                and h['key_hex'] == f'{key:02x}' for h in hits))

    def test_reversal(self):
        value = b'OTHER{reverse_bytes_safely}'
        hits, _ = self.recover(b'\0' * 9 + value[::-1] + b'\0')
        self.assertTrue(any(h['value'] == value.decode() and h['byte_offset'] == 9 for h in hits))

    def test_repeating_key(self):
        value, key = b'SPECTRONA{periodic_key_recovered}', b'\x13\x37\x42'
        hits, _ = self.recover(b'\0' * 21 + bytes(b ^ key[i % 3] for i, b in enumerate(value)) + b'\0')
        self.assertTrue(any(h['value'] == value.decode() and h['key_hex'] == key.hex()
                            and h['byte_offset'] == 21 for h in hits))

    def test_custom_prefix(self):
        value, key = b'CUSTOM_EVENT{a_unique_wrapper}', b'\x29\x63\x19'
        hits, _ = self.recover(bytes(b ^ key[i % 3] for i, b in enumerate(value)),
                               prefixes=(b'CUSTOM_EVENT{',))
        self.assertTrue(any(h['value'] == value.decode() for h in hits))

    def test_byte_budget_disclosed(self):
        _, notes = self.recover(b'\0' * 1024, max_bytes=128)
        self.assertIn('first 128', notes[0])

    def test_time_budget_disclosed(self):
        _, notes = self.recover(b'\0' * 65536, seconds=0.000001)
        self.assertTrue(notes)

    def test_derived_payload_does_not_claim_original_offset(self):
        value = b'flag{derived_payload_location}'
        source, original = self.work / 'payload', self.work / 'archive'
        source.write_bytes(value[::-1])
        original.write_bytes(b'container bytes')
        hits, _ = recovery.recover(source, original=original)
        self.assertTrue(any(h['value'] == value.decode() and h['derived_payload'] for h in hits))
        rec = self.work / 'recovery.jsonl'
        rec.write_text(''.join(json.dumps(hit) + '\n' for hit in hits))
        raw = self.work / 'hits'
        raw.write_text('low\tbinary-recovery\trecovered\t' + value.decode() + '\n')
        result = evidence.build(raw, {}, rec)
        occurrence = result['candidates'][0]['occurrences'][-1]
        self.assertIsNone(occurrence['binary_byte_offset'])
        self.assertEqual(occurrence['analyzed_payload_byte_offset'], 0)

    def test_no_boundary_fabrication(self):
        hits, _ = self.recover(b'flag{a\0fragmented_value}')
        self.assertFalse(any(h['value'] == 'flag{afragmented_value}' for h in hits))

    def test_indexed_ghidra_stores_with_decimal_and_hex_literals(self):
        value = b'SPECTRONA{qa_stack_encoded_fixture}'
        encoded = bytes(b ^ 0x5a for b in value)
        capture = b'void main(void) {\n' + b''.join(
            f'  local_48[{index if index < 11 else hex(index)}] = '
            f'{byte if index % 2 else hex(byte)};\n'.encode()
            for index, byte in enumerate(encoded)) + b'}\n'
        runs = recovery.capture_runs(capture)
        self.assertEqual(runs, [(encoded, capture.index(b'local_48[0]'))])
        hits, notes = self.recover(runs[0][0])
        self.assertFalse(notes)
        self.assertTrue(any(hit['value'] == value.decode() for hit in hits))

    def test_indexed_stores_do_not_join_unrelated_writes(self):
        prefix = b''.join(f'local_48[{i}] = {i+1};\n'.encode() for i in range(3))
        suffix = b''.join(f'local_48[{i}] = {i+1};\n'.encode() for i in range(3,6))
        for boundary in (b'call();\n', b'}\n{\n', b'local_40[0] = 7;\n'):
            with self.subTest(boundary=boundary):
                self.assertEqual(recovery.capture_runs(prefix + boundary + suffix), [])
        for capture in (prefix + suffix.replace(b'[3]',b'[9]'),
                        prefix + suffix.replace(b'= 4;',b'= 256;')):
            self.assertEqual(recovery.capture_runs(capture), [])

    @unittest.skipUnless(shutil.which('gcc'), 'GCC unavailable')
    def test_compiled_elf_without_plaintext_answer(self):
        value, key = b'flag{compiled_recovery_fixture}', 0x5a
        c = self.work / 'fixture.c'
        c.write_text('volatile unsigned char data[]={' + ','.join(str(b ^ key) for b in value)
                     + '}; int main(void){return data[0]==0;}')
        target = self.work / 'fixture'
        subprocess.run(['gcc', '-O0', '-nostdlib', '-Wl,-e,main', '-o', str(target), str(c)], check=True)
        before = target.read_bytes()
        self.assertNotIn(value, before)
        hits, _ = recovery.recover(target)
        self.assertTrue(any(h['value'] == value.decode() for h in hits))
        self.assertEqual(before, target.read_bytes())

    def test_provenance_keeps_stages_and_true_binary_location(self):
        first, second = self.work / 'first', self.work / 'second'
        first.write_text('lead flag{evidence_value} again flag{evidence_value}')
        second.write_text('flag{evidence_value}')
        raw = self.work / 'hits'
        raw.write_text('low\tstrings\tplain\tflag{evidence_value}\n'
                       'high\tghidra\tplain\tflag{evidence_value}\n')
        result = evidence.build(raw, {'strings': str(first), 'ghidra': str(second)})
        candidate = result['candidates'][0]
        self.assertEqual(candidate['confidence'], 'high')
        self.assertFalse(candidate['verified'])
        self.assertEqual(len(candidate['occurrences']), 3)
        self.assertEqual(candidate['occurrences'][0]['capture_byte_offset'], 5)
        self.assertIsNone(candidate['occurrences'][0]['binary_byte_offset'])

    def test_python_source_is_parsed_not_executed(self):
        source = self.work / 'source.py'
        marker = self.work / 'executed'
        source.write_text(f"open({str(marker)!r}, 'w').write('unsafe')\nvalue = input()\n")
        hints = source_review.review(source)
        self.assertFalse(marker.exists())
        self.assertTrue(any('external file' in h for h in hints))

    def test_partial_raw_record_is_not_invented(self):
        raw = self.work / 'hits'
        raw.write_text('high\tstrings\tplain\tflag{cut')
        result = evidence.build(raw, {})
        self.assertEqual(result['candidates'], [])
        self.assertFalse(result['provenance_complete'])

    def test_partial_recovery_line_preserves_earlier_evidence(self):
        raw, rec = self.work / 'hits', self.work / 'recovered'
        value = 'flag{early_complete_value}'
        raw.write_text('high\tbinary-recovery\trecovered\t' + value + '\n')
        hit = dict(value=value, source='original', transform='xor-single',
                   byte_offset=5, key_hex='5a')
        rec.write_text(json.dumps(hit) + '\n' + '{"value":')
        result = evidence.build(raw, {}, rec)
        self.assertFalse(result['provenance_complete'])
        self.assertTrue(any(o.get('key_hex') == '5a' for o in result['candidates'][0]['occurrences']))


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.work = Path(temp.name)

    def zip(self, entries):
        path = self.work / 'archive.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, value in entries:
                archive.writestr(name, value)
        return path

    def test_valid_zip_preserves_names_and_bytes(self):
        path = self.zip([('a space/quote; $.bin', b'original')])
        result = extractor.extract(path, self.work / 'out', 1024)
        self.assertEqual(Path(result['files'][0]).read_bytes(), b'original')

    def test_zip_traversal_rejected_before_any_payload_write(self):
        path = self.zip([('valid', b'ok'), ('../outside', b'bad')])
        with self.assertRaises(ValueError):
            extractor.extract(path, self.work / 'out', 1024)
        self.assertFalse((self.work / 'out/valid').exists())
        self.assertFalse((self.work / 'outside').exists())

    def test_absolute_windows_and_backslash_paths_rejected(self):
        for name in ('/outside', 'C:/outside', 'a\\..\\outside'):
            with self.subTest(name=name):
                path = self.zip([(name, b'bad')])
                with self.assertRaises(ValueError):
                    extractor.extract(path, self.work / 'out', 1024)

    def test_symlink_rejected(self):
        path = self.work / 'link.zip'
        link = zipfile.ZipInfo('link')
        link.create_system = 3
        link.external_attr = 0o120777 << 16
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr(link, '../outside')
        with self.assertRaises(ValueError):
            extractor.extract(path, self.work / 'out', 1024)

    def test_tar_hardlink_and_device_rejected(self):
        for kind in (tarfile.LNKTYPE, tarfile.CHRTYPE):
            path = self.work / 'bad.tar'
            with tarfile.open(path, 'w') as archive:
                member = tarfile.TarInfo('bad')
                member.type, member.linkname = kind, '../outside'
                archive.addfile(member)
            with self.assertRaises(ValueError):
                extractor.extract(path, self.work / 'out', 1024)

    def test_expansion_and_member_budgets(self):
        path = self.zip([('a', b'x' * 700), ('b', b'y' * 700)])
        with self.assertRaises(ValueError):
            extractor.extract(path, self.work / 'bytes', 1024)
        with self.assertRaises(ValueError):
            extractor.extract(path, self.work / 'members', 4096, max_members=1)

    def test_valid_compressed_tar(self):
        path = self.work / 'valid.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            member = tarfile.TarInfo('payload')
            member.size = 5
            archive.addfile(member, io.BytesIO(b'hello'))
        result = extractor.extract(path, self.work / 'out', 1024)
        self.assertEqual(result['expanded_bytes'], 5)


@unittest.skipUnless(os.name == 'posix' and shutil.which('bash'), 'Linux Bash required')
class PipelineTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.work = Path(temp.name)

    def bash(self, code):
        setup = r'''
set -uo pipefail
ROOT=$1; WORK=$2
source "$ROOT/lib/stage.sh"
source "$ROOT/lib/flagscan.sh"
source "$ROOT/lib/report.sh"
declare -A OPT=([flag_scan]=1 [flag_format]='' [summary_only]=0 [ghidra_script]=''
               [skip_ghidra]=0 [light_decompile]=0 [force_full_decompile]=0)
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
REVCTF_SCRIPTS="$ROOT/scripts"
RUN_WORKDIR="$WORK/tmp"; RUN_OUTDIR="$WORK/out"; RUN_TARGET="$WORK/target"
mkdir -p "$RUN_WORKDIR" "$RUN_OUTDIR"
ST_MEM_MODE=ulimit; ST_MEM_CEIL_MB=128; ST_MEM_IS_JVM=0
STAGE_ORDER=(strings); STAGE_OUT=([strings]="$WORK/capture")
'''
        result = subprocess.run(['bash', '-c', setup + code, 'qa', str(ROOT), str(self.work)],
                                text=True, capture_output=True, timeout=60, cwd=self.work)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_actual_flag_worker_recovers_and_attributes_xor(self):
        value = b'SPECTRONA{worker_recovered_value}'
        (self.work / 'target').write_bytes(bytes(b ^ 0x5a for b in value))
        (self.work / 'capture').write_text('no plaintext answer here\n')
        self.bash('flagscan_run; [[ ${STAGE_STATUS[flagscan]} == ok ]]')
        result = json.loads((self.work / 'out/candidate-evidence.json').read_text())
        hit = next(c for c in result['candidates'] if c['value'] == value.decode())
        self.assertFalse(hit['verified'])
        self.assertTrue(any(o.get('key_hex') == '5a' and o['binary_byte_offset'] == 0
                            for o in hit['occurrences']))

    def test_xor_stack_immediates_from_decompiler_capture(self):
        value = b'SPECTRONA{nonprintable_stack_cipher}'
        encoded = bytes(b ^ 0x5a for b in value)
        lines = []
        for pos in range(0, len(encoded), 8):
            word = int.from_bytes(encoded[pos:pos + 8].ljust(8, b'\0'), 'little')
            lines.append(f'local_{0x80 - pos:x} = 0x{word:016x};')
        (self.work / 'capture').write_text('\n'.join(lines) + '\n')
        self.bash('STAGE_ORDER=(ghidra); STAGE_OUT=([ghidra]="$WORK/capture"); flagscan_run; '
                  '[[ ${STAGE_STATUS[flagscan]} == ok ]]')
        result = json.loads((self.work / 'out/candidate-evidence.json').read_text())
        hit = next(c for c in result['candidates'] if c['value'] == value.decode())
        self.assertTrue(any(o.get('transform') == 'reconstructed+xor-single'
                            and o.get('capture_anchor_byte_offset') == 0
                            and o['binary_byte_offset'] is None for o in hit['occurrences']))

    def test_unknown_encoded_wrapper_and_noise_order(self):
        import base64
        (self.work / 'capture').write_text(base64.b64encode(b'UNFAMILIAR{encoded_wrapper}').decode()
                                         + '\n' + 'a' * 32 + '\n')
        output = self.bash('flagscan_run; flagscan_report')
        self.assertIn('UNFAMILIAR{encoded_wrapper}', output)
        self.assertLess(output.index('--- low confidence'), output.index('--- medium confidence'))

    def test_no_high_confidence_advice_for_hashes(self):
        (self.work / 'capture').write_text('a' * 32 + '\n')
        output = self.bash('flagscan_run; _rp_next')
        self.assertIn('Only hash-like leads', output)
        self.assertNotIn('Submit the high-confidence', output)

    def test_generated_worker_quotes_literal_paths(self):
        self.work = self.work / "space ' ; $(touch INJECTED)"
        self.work.mkdir()
        value = b'flag{quoted_path_recovery}'
        original = bytes(b ^ 0x5a for b in value)
        (self.work / 'target').write_bytes(original)
        (self.work / 'capture').write_text('no plaintext answer\n')
        self.bash('flagscan_run; [[ ${STAGE_STATUS[flagscan]} == ok ]]')
        self.assertFalse((self.work / 'INJECTED').exists())
        self.assertEqual((self.work / 'target').read_bytes(), original)
        result = json.loads((self.work / 'out/candidate-evidence.json').read_text())
        self.assertTrue(any(c['value'] == value.decode() for c in result['candidates']))

    def test_oversized_custom_pattern_rejected_before_dependency_probes(self):
        (self.work / 'target').write_bytes(b'input remains unchanged')
        result = subprocess.run(['bash', str(ROOT / 'revctf'), 'scan', str(self.work / 'target'),
                                 '--flag-format', 'a' * 4097, '--dry-run'],
                                capture_output=True, text=True, timeout=10, cwd=self.work)
        self.assertEqual(result.returncode, 1)
        self.assertIn('4096-character limit', result.stderr)

    def test_custom_pattern_budget_keeps_other_searches(self):
        (self.work / 'capture').write_text('flag{builtin_survives_pattern_timeout}\n')
        bindir = self.work / 'bin'
        bindir.mkdir()
        wrapper = bindir / 'grep'
        wrapper.write_text('#!/bin/bash\nfor arg in "$@"; do\n'
                           'if [[ $arg == SLOW_CUSTOM ]]; then sleep 30; fi\ndone\n'
                           'exec /usr/bin/grep "$@"\n')
        wrapper.chmod(0o755)
        self.bash(r'''
PATH="$WORK/bin:$PATH"
OPT[flag_format]=SLOW_CUSTOM
flagscan_run
[[ ${STAGE_STATUS[flagscan]} == partial ]] || exit 5
flagscan_report | /usr/bin/grep -q 'flag{builtin_survives_pattern_timeout}'
''')
        sidecar = json.loads((self.work / 'out/candidate-evidence.json').read_text())
        self.assertFalse(sidecar['search_complete'])

    def test_python_and_wasm_native_stages_skip(self):
        (self.work / 'target').write_text('#!/usr/bin/env python3\nprint("source only")\n')
        self.bash(r'''
source "$ROOT/lib/stage_triage.sh"
[[ $(_triage_classify "$RUN_TARGET") == python-source ]] || exit 3
for stage in objdump checksec radare2 ghidra; do
    source "$ROOT/lib/stage_$stage.sh"
done
PF_GHIDRA_HEADLESS=not-executed
for RUN_FORMAT in python-source wasm; do
    stage_objdump; stage_checksec; stage_radare2; stage_ghidra
    for stage in objdump checksec radare2 ghidra; do
        [[ ${STAGE_STATUS[$stage]} == skipped ]] || exit 4
    done
done
''')

    def test_archive_member_selection_discloses_omissions(self):
        with zipfile.ZipFile(self.work / 'target', 'w') as archive:
            archive.writestr('first.py', 'print("first")\n')
            archive.writestr('second.py', 'print("second")\n')
        self.bash(r'''
source "$ROOT/lib/stage_triage.sh"
RUN_ORIGINAL=$RUN_TARGET
stage_triage
[[ ${STAGE_STATUS[triage]} == partial && $RUN_FORMAT == python-source ]] || exit 6
[[ $TRIAGE_LIMIT_NOTE == *multiple* ]] || exit 7
[[ -f $RUN_OUTDIR/source-review.txt ]] || exit 8
''')

    def test_archive_depth_limit_is_real(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, 'w') as archive:
            archive.writestr('payload.py', 'print("payload")\n')
        with zipfile.ZipFile(self.work / 'target', 'w') as archive:
            archive.writestr('inner.zip', inner.getvalue())
        self.bash(r'''
source "$ROOT/lib/stage_triage.sh"
RUN_ORIGINAL=$RUN_TARGET
TRIAGE_MAX_DEPTH=1
stage_triage
[[ ${STAGE_STATUS[triage]} == partial && $RUN_FORMAT == archive ]] || exit 9
[[ $TRIAGE_LIMIT_NOTE == *depth* ]] || exit 10
''')

    def test_shell_syntax(self):
        for path in [ROOT / 'revctf', ROOT / 'install.sh', *ROOT.glob('lib/*.sh')]:
            result = subprocess.run(['bash', '-n', str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, str(path) + result.stderr)

    def ghidra_fixture(self, import_failure):
        launcher = self.work / 'headless'
        if import_failure:
            launcher.write_text('#!/bin/bash\necho "No load spec found for import file"\n')
        else:
            launcher.write_text('#!/bin/bash\nwhile [[ $# -gt 0 ]]; do\n'
                                'if [[ $1 == RevctfMemoryGuard.java ]]; then shift; '
                                'printf "verified=1\\n" > "$1"; fi\nshift\ndone\n'
                                'printf "%s\\n" "=== REVCTF-GHIDRA-BEGIN ===" '
                                '"challenge text: No load spec found" "=== REVCTF-GHIDRA-END ==="\n')
        launcher.chmod(0o755)
        return self.bash(r'''
source "$ROOT/lib/tier.sh"
source "$ROOT/lib/stage_ghidra.sh"
RUN_FORMAT=elf
PF_GHIDRA_HEADLESS="$WORK/headless"
PF_GHIDRA_SCRIPT_KIND=pyghidra
pf_check_disk() { return 0; }
: > "$(stage_out_path ghidra)"
stage_ghidra
printf '%s\n' "${STAGE_STATUS[ghidra]}" "${STAGE_NOTE[ghidra]:-}"
cat "$(stage_err_path ghidra)"
''')

    def test_import_failure_is_not_mislabeled_heap_failure(self):
        output = self.ghidra_fixture(True)
        self.assertIn('import failed', output)
        self.assertNotIn('heap could not be verified', output)

    def test_challenge_text_is_not_a_loader_error(self):
        output = self.ghidra_fixture(False)
        self.assertTrue(output.startswith('ok\n'), output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
