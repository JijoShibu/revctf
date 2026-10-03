#!/usr/bin/env python3
"""Exercise publication failures without contacting GitHub or publishing anything."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).with_name('publish-release.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.package = Path(temporary.name)
        self.version = '2.0.0-rc.1'
        self.commit = 'a' * 40
        self.archive = self.package / ('revctf-' + self.version + '.tar.gz')
        self.archive.write_bytes(b'controlled source archive')
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.package / 'manifest.json').write_text(json.dumps(dict(
            source_commit=self.commit, version=self.version, sha256=self.digest)))
        (self.package / (self.archive.name + '.sha256')).write_text(self.digest + '  ' + self.archive.name + '\n')
        self.calls = []
        self.prior = None
        self.tag = {'object': {'type': 'commit', 'sha': self.commit}}
        self.bad_upload = False
        patchers = [
            mock.patch.dict(publisher.os.environ, GITHUB_REF='refs/heads/main', GITHUB_SHA=self.commit),
            mock.patch.object(publisher.release, 'gate'),
            mock.patch.object(publisher, 'request', side_effect=self.request),
            mock.patch.object(publisher.urllib.request, 'urlopen', side_effect=lambda *a, **k: io.BytesIO(self.archive.read_bytes())),
        ]
        for patcher in patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def request(self, path, method='GET', body=None, upload=None):
        self.calls.append((path, method, body))
        if path.startswith('releases/tags/'):
            return self.prior
        if path.startswith('git/ref/'):
            return self.tag
        if path == 'releases' and method == 'POST':
            return {'id': 42, 'assets': []}
        if upload:
            return {'digest': 'sha256:' + ('0' * 64 if self.bad_upload else hashlib.sha256(upload.read_bytes()).hexdigest())}
        if path == 'releases/42' and method == 'PATCH':
            return {'html_url': 'https://github.com/JijoShibu/revctf/releases/tag/v' + self.version}
        self.fail('Unexpected API operation: ' + method + ' ' + path)

    def publish(self):
        with contextlib.redirect_stdout(io.StringIO()):
            publisher.publish(self.version, self.commit, self.package)

    def test_published_version_cannot_be_replaced(self):
        self.prior = {'draft': False}
        with self.assertRaisesRegex(ValueError, 'already published'):
            self.publish()
        self.assertTrue(all(method == 'GET' for _, method, _ in self.calls))

    def test_tag_cannot_be_moved(self):
        self.tag['object']['sha'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'another commit'):
            self.publish()
        self.assertTrue(all(method == 'GET' for _, method, _ in self.calls))

    def test_corrupt_package_stops_before_api_calls(self):
        self.archive.write_bytes(b'changed contents')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_upload_mismatch_keeps_draft_unpublished(self):
        self.bad_upload = True
        with self.assertRaisesRegex(ValueError, 'draft preserved'):
            self.publish()
        self.assertFalse(any(method == 'PATCH' for _, method, _ in self.calls))

    def test_interrupted_draft_resumes_without_replacing_assets(self):
        self.prior = {'draft': True, 'id': 42, 'assets': [
            {'name': path.name, 'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in self.package.iterdir()]}
        self.publish()
        self.assertFalse(any(method == 'POST' for _, method, _ in self.calls))
        updates = [body for _, method, body in self.calls if method == 'PATCH']
        self.assertEqual(len(updates), 1)
        self.assertTrue(updates[0]['prerelease'])
        self.assertFalse(updates[0]['draft'])

    def test_conflicting_draft_asset_refuses_publication(self):
        self.prior = {'draft': True, 'id': 42, 'assets': [{'name': self.archive.name, 'digest': 'sha256:' + '0' * 64}]}
        with self.assertRaisesRegex(ValueError, 'Draft asset differs'):
            self.publish()
        self.assertFalse(any(method == 'PATCH' for _, method, _ in self.calls))

    def test_wrong_workflow_commit_refuses_publication(self):
        with mock.patch.dict(publisher.os.environ, GITHUB_SHA='b' * 40):
            with self.assertRaisesRegex(ValueError, 'reviewed main commit'):
                self.publish()
        self.assertEqual(self.calls, [])

    def test_anonymous_download_mismatch_is_reported(self):
        with mock.patch.object(publisher.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong archive')):
            with self.assertRaisesRegex(ValueError, 'anonymous verification'):
                self.publish()


if __name__ == '__main__':
    unittest.main()
