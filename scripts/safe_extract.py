#!/usr/bin/env python3
"""Extract ZIP/tar regular files with containment and cumulative byte/count limits."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tarfile
import zipfile


def extract(source, destination, max_bytes, max_members=1000):
    destination = Path(destination)
    if destination.exists() and any(destination.iterdir()):
        raise ValueError('extraction destination must be empty')
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    root = destination.resolve()
    budget = min(max_bytes, shutil.disk_usage(root).free // 2)
    if budget <= 0 or max_members <= 0:
        raise ValueError('invalid extraction budget')
    if zipfile.is_zipfile(source):
        archive = zipfile.ZipFile(source)
        members = archive.infolist()
        def info(member):
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise ValueError('archive links and special files are forbidden')
            return member.filename, member.file_size, member.is_dir()
        opener = archive.open
    elif tarfile.is_tarfile(source):
        archive = tarfile.open(source, 'r:*')
        members = []
        for member in archive:
            members.append(member)
            if len(members) > max_members:
                archive.close()
                raise ValueError('archive member-count limit reached')
        def info(member):
            if not (member.isfile() or member.isdir()) or member.sparse:
                raise ValueError('archive links, sparse and special files are forbidden')
            return member.name, member.size, member.isdir()
        opener = archive.extractfile
    else:
        raise ValueError('safe extraction currently supports ZIP and tar containers only')
    paths, declared, names = [], 0, set()
    try:
        if len(members) > max_members:
            raise ValueError('archive member-count limit reached')
        # Validate every member before creating any archive-controlled file.
        for member in members:
            name, size, directory = info(member)
            path = PurePosixPath(name)
            if (not name or '\\' in name or ':' in name or '\x00' in name or
                    path.is_absolute() or '..' in path.parts):
                raise ValueError('unsafe archive member path')
            target = root.joinpath(*path.parts)
            if target == root and directory:
                continue
            if not target.is_relative_to(root) or target == root or target in names:
                raise ValueError('duplicate or unsafe archive member')
            names.add(target)
            declared += size
            if size < 0 or declared > budget:
                raise ValueError('archive expansion exceeds byte limit or free-disk headroom')
            paths.append((member, target, directory))
        written, files = 0, []
        for member, target, directory in paths:
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if directory:
                target.mkdir(mode=0o700, exist_ok=True)
                continue
            # All ancestors were created in a private directory; never follow a
            # member link or replace another member even on overlapping names.
            with opener(member) as src, target.open('xb') as out:
                os.chmod(target, 0o600)
                while True:
                    chunk = src.read(min(65536, budget - written + 1))
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > budget:
                        raise ValueError('actual archive expansion exceeded byte budget')
                    out.write(chunk)
            files.append(str(target))
        return dict(files=files, expanded_bytes=written, byte_limit=budget, member_count=len(members))
    finally:
        archive.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--max-bytes', type=int, required=True)
    parser.add_argument('--max-members', type=int, default=1000)
    parser.add_argument('--manifest', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = extract(args.source, args.destination, args.max_bytes, args.max_members)
        args.manifest.write_text(json.dumps(result) + '\n', encoding='utf-8')
        print(result['expanded_bytes'], result['member_count'])
    except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile, RuntimeError) as error:
        parser.exit(1, 'Safe extraction failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
