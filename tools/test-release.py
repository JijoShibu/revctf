#!/usr/bin/env python3
"""Publication gates must reject missing, stale and premature evidence."""
import copy
import datetime as dt
import importlib.util
from pathlib import Path
import unittest

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


if __name__ == '__main__':
    unittest.main()
