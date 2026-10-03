#!/usr/bin/env python3
"""Publish only the package verified by the approved release workflow."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
import release

BASE = 'https://api.github.com/repos/JijoShibu/revctf/'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(path, method='GET', body=None, upload=None):
    url = BASE + path
    headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
               'Accept': 'application/vnd.github+json', 'User-Agent': 'revctf-release'}
    data = None if body is None else json.dumps(body).encode()
    if upload is not None:
        url = 'https://uploads.github.com/repos/JijoShibu/revctf/' + path
        data = upload.read_bytes()
        headers['Content-Type'] = 'application/octet-stream'
    elif data is not None:
        headers['Content-Type'] = 'application/json'
    try:
        with urllib.request.build_opener(NoRedirect).open(
                urllib.request.Request(url, data=data, headers=headers, method=method), timeout=120) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        if error.code == 404 and method == 'GET':
            return None
        raise RuntimeError('GitHub request failed: ' + method + ' ' + path + ' (' + str(error.code) + ')') from None


def publish(version, commit, package):
    if os.environ.get('GITHUB_REF') != 'refs/heads/main' or os.environ.get('GITHUB_SHA') != commit:
        raise ValueError('Publication must run from the reviewed main commit')
    release.gate(version, commit)
    manifest = json.loads((package / 'manifest.json').read_text())
    archive = package / ('revctf-' + version + '.tar.gz')
    if (manifest['source_commit'] != commit or manifest['version'] != version or
            hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['sha256']):
        raise ValueError('Package identity or checksum mismatch')
    tag = 'v' + version
    prior = request('releases/tags/' + tag)
    if prior and not prior['draft']:
        raise ValueError('This version is already published; use a new version')
    ref = request('git/ref/tags/' + tag)
    if ref:
        obj = ref['object']
        if obj['type'] == 'tag':
            obj = request('git/tags/' + obj['sha'])['object']
        if obj['type'] != 'commit' or obj['sha'] != commit:
            raise ValueError('Existing version tag identifies another commit')
    else:
        annotated = request('git/tags', 'POST', {
            'tag': tag, 'message': 'RevCTF ' + version, 'object': commit, 'type': 'commit',
            'tagger': {'name': 'Jijo Shibu', 'email': 'jijoshibu@gmail.com',
                       'date': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')},
        })
        request('git/refs', 'POST', {'ref': 'refs/tags/' + tag, 'sha': annotated['sha']})
    notes = (release.ROOT / 'docs/releases' / (version + '.md')).read_text()
    preview = '-rc.' in version
    draft = prior or request('releases', 'POST', {
        'tag_name': tag, 'target_commitish': commit, 'name': 'RevCTF ' + version,
        'body': notes, 'draft': True, 'prerelease': preview, 'make_latest': 'false',
    })
    # Interrupted drafts are recoverable without moving tags or replacing published files.
    existing = {asset['name']: asset for asset in draft.get('assets', [])}
    for path in (archive, package / (archive.name + '.sha256'), package / 'manifest.json'):
        digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
        asset = existing.get(path.name)
        if asset:
            if asset.get('digest') != digest:
                raise ValueError('Draft asset differs: inspect and remove it manually before retrying: ' + path.name)
            continue
        uploaded = request('releases/' + str(draft['id']) + '/assets?name=' + urllib.parse.quote(path.name),
                           'POST', upload=path)
        if uploaded.get('digest') != digest:
            raise ValueError('Uploaded asset digest could not be verified; draft preserved')
    published = request('releases/' + str(draft['id']), 'PATCH', {
        'draft': False, 'prerelease': preview, 'make_latest': 'false' if preview else 'true', 'body': notes,
    })
    # No credentials on the independent public download.
    public_url = 'https://github.com/JijoShibu/revctf/releases/download/' + tag + '/' + archive.name
    with urllib.request.urlopen(public_url, timeout=120) as response:
        actual = hashlib.file_digest(response, 'sha256').hexdigest()
    if actual != manifest['sha256']:
        raise ValueError('Published archive failed anonymous verification; investigate before recommending this release')
    print(published['html_url'])
    print('Anonymous archive checksum verified. Complete the documented Kali installation check.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--package', required=True, type=Path)
    args = parser.parse_args()
    try:
        publish(args.version, args.commit, args.package)
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, 'Publication stopped: ' + str(error) + '\n')
