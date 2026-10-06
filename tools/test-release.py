#!/usr/bin/env python3
"""Publication gates must reject missing, stale and premature evidence."""
import copy
import datetime as dt
import importlib.util
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.record = dict(version='2.0.0-rc.1', runtime_sha256='a' * 64,
            configured_ram_mib=4096, vm_restored_16gb=True, open_blockers=[],
            checks={name: {'result': 'passed', 'evidence': 'controlled-test-record'} for name in release.REQUIRED})

    def test_complete_evidence(self):
        release.validate_evidence(self.record, '2.0.0-rc.1', 'a' * 64)

    def build_sample(self, destination, name='revctf'):
        tar = io.BytesIO()
        payload = b'controlled source bytes\n'
        with tarfile.open(fileobj=tar, mode='w') as archive:
            member = tarfile.TarInfo('revctf-2.0.0/' + name)
            member.size = len(payload)
            member.mode = 0o755
            archive.addfile(member, io.BytesIO(payload))
        with patch.object(release, 'version', return_value='2.0.0'), \
             patch.object(release, 'git', side_effect=['b' * 40, '']), \
             patch.object(release, 'runtime_digest', return_value='a' * 64), \
             patch.object(release.subprocess, 'check_output', return_value=tar.getvalue()):
            return release.build(destination, '2.0.0')

    def test_source_package_identity_and_repeatability(self):
        with tempfile.TemporaryDirectory() as temporary:
            first, second = Path(temporary) / 'first', Path(temporary) / 'second'
            digest = self.build_sample(first)
            self.assertEqual(digest, self.build_sample(second))
            data = (first / 'revctf-2.0.0.tar.gz').read_bytes()
            self.assertEqual(data, (second / 'revctf-2.0.0.tar.gz').read_bytes())
            self.assertEqual(data[4:8], b'\0' * 4)  # no build timestamp
            self.assertEqual(data[9], 255)  # no platform-specific OS byte
            self.assertEqual(digest, hashlib.sha256(data).hexdigest())
            manifest = json.loads((first / 'manifest.json').read_text())
            self.assertEqual(manifest['source_commit'], 'b' * 40)
            self.assertEqual(manifest['sha256'], digest)
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(data))) as archive:
                member = archive.getmember('revctf-2.0.0/revctf')
                self.assertEqual(member.mode, 0o755)
                self.assertEqual(archive.extractfile(member).read(), b'controlled source bytes\n')

    def test_source_package_excludes_private_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, 'Private or local artifact'):
                self.build_sample(Path(temporary) / 'package', '.env')
            self.assertFalse((Path(temporary) / 'package').exists())

    def test_every_missing_check_rejected(self):
        for name in release.REQUIRED:
            record = copy.deepcopy(self.record)
            del record['checks'][name]
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.validate_evidence(record, '2.0.0-rc.1', 'a' * 64)

    def test_stale_runtime(self):
        with self.assertRaises(ValueError):
            release.validate_evidence(self.record, '2.0.0-rc.1', 'b' * 64)

    def test_failed_check(self):
        self.record['checks']['known_answers']['result'] = 'failed'
        with self.assertRaises(ValueError):
            release.validate_evidence(self.record, '2.0.0-rc.1', 'a' * 64)

    def test_vm_restoration_required(self):
        self.record['vm_restored_16gb'] = False
        with self.assertRaises(ValueError):
            release.validate_evidence(self.record, '2.0.0-rc.1', 'a' * 64)

    def test_preview_period_and_independent_report(self):
        now = dt.datetime(2026, 10, 10, tzinfo=dt.timezone.utc)
        previews = [dict(prerelease=True, draft=False, tag_name='v2.0.0-rc.1', published_at='2026-10-03T00:00:00Z')]
        self.record['independent_test'] = dict(version='2.0.0-rc.1', result='passed', maintainer_reviewed=True,
                                               tester='independent-tester', issue_number=42)
        release.check_stable(self.record, previews, now)
        with self.assertRaises(ValueError):
            release.check_stable(self.record, previews, now - dt.timedelta(seconds=1))
        self.record['independent_test']['tester'] = 'JijoShibu'
        with self.assertRaises(ValueError):
            release.check_stable(self.record, previews, now)

    def test_no_published_preview(self):
        with self.assertRaises(ValueError):
            release.check_stable(self.record, [], dt.datetime.now(dt.timezone.utc))

    def test_null_independent_report(self):
        self.record['independent_test'] = None
        previews = [dict(prerelease=True, draft=False, tag_name='v2.0.0-rc.1', published_at='2026-10-03T00:00:00Z')]
        with self.assertRaisesRegex(ValueError, 'independent Kali report'):
            release.check_stable(self.record, previews, dt.datetime(2026, 10, 11, tzinfo=dt.timezone.utc))

    def test_direct_stable_decision(self):
        self.record['stable_release_decision'] = dict(version='2.0.0',
            maintainer='Jijo Shibu <jijoshibu@gmail.com>', approved_on='2026-10-05',
            preview_wait_waived=True, independent_report_waived=True,
            required_controlled_checks=True)
        self.assertTrue(release.direct_stable_approved(self.record, '2.0.0'))
        self.assertFalse(release.direct_stable_approved(self.record, '2.0.1'))
        for name in ('preview_wait_waived', 'independent_report_waived',
                     'required_controlled_checks'):
            changed = copy.deepcopy(self.record)
            changed['stable_release_decision'][name] = False
            self.assertFalse(release.direct_stable_approved(changed, '2.0.0'))
        # The decision changes the feedback policy, never the technical gates.
        self.record['version'] = '2.0.0'
        self.record['checks']['installation']['result'] = 'failed'
        with self.assertRaises(ValueError):
            release.validate_evidence(self.record, '2.0.0', 'a' * 64)

    def test_missing_direct_stable_decision(self):
        self.assertFalse(release.direct_stable_approved(self.record, '2.0.0'))

    def test_future_release_cannot_use_an_old_preview(self):
        self.record['version'] = '2.0.1'
        previews = [dict(prerelease=True, draft=False, tag_name='v2.0.0-rc.1',
                         published_at='2026-10-03T00:00:00Z')]
        with self.assertRaisesRegex(ValueError, 'matching preview'):
            release.check_stable(self.record, previews, dt.datetime(2026, 10, 11, tzinfo=dt.timezone.utc))

    def test_future_release_uses_its_own_preview_and_report(self):
        self.record['version'] = '2.0.1'
        self.record['independent_test'] = dict(version='2.0.1-rc.1', result='passed',
            maintainer_reviewed=True, tester='independent-tester', issue_number=43)
        previews = [dict(prerelease=True, draft=False, tag_name='v2.0.1-rc.1',
                         published_at='2026-10-03T00:00:00Z')]
        release.check_stable(self.record, previews, dt.datetime(2026, 10, 11, tzinfo=dt.timezone.utc))


if __name__ == '__main__':
    unittest.main()
