# Releasing RevCTF

Maintainer: Jijo Shibu <jijoshibu@gmail.com>

The next proposed version is **v2.0.0-rc.1**. Its code is being reviewed in pull request
#2. Preparing files or an archive does not publish a release. The pull request remains
unmerged until the maintainer explicitly authorizes merging and publication.

## Before publication

1. Check live tags, releases, and the pull request head. Never replace a published tag.
2. Run the basic checks and the real Kali tests described in [REHEARSAL.md](REHEARSAL.md).
   Record the exact source commit, environment, results, failures and skips in the
   validation record. An earlier green run does not validate changed behavior.
3. Resolve incorrect answers, surviving challenge processes, file damage, installation
   failures, and ineffective resource limits before publication. Required checks must
   pass; unsupported optional scenarios must be named rather than counted as passes.
4. Review the upgrade notes and prepare a source archive from the reviewed commit.
   Use `git archive`, which includes tracked files only, and record its SHA-256 checksum.
   Inspect the archive for local captures, credentials, test binaries, and obsolete files.
5. Verify all test challenges have stopped. Shut the test VM down normally and restore
   its original memory allocation. Record both the configured memory and powered-off state.
6. Present the pull request, validation record, archive, and checksum for review. Do not
   merge, create a remote tag, publish a release, or post feedback requests at this step.

## Publish an approved preview

After explicit authorization, merge the reviewed changes and verify the resulting tree.
Set the published status/date in the README and release notes, commit those edits, and
run version, documentation, syntax, and smoke checks on that final commit. If merging
introduced other code, repeat the affected tests before tagging.

Create an annotated `v2.0.0-rc.1` tag at that exact commit. Build a new source archive and
checksum from the tag so they match the published source, not the earlier review archive.
Create a GitHub release marked **pre-release**, attach the archive and checksum, and
use the reviewed release notes. Do not designate a preview as the latest stable release.

Download the published archive anonymously, verify the checksum, unpack it into a new
directory, and check `--version`, file permissions, shell syntax, and a controlled scan.
Record the release URL, tag commit, archive checksum and verification result. A failed
published-artifact check blocks promotion; fix it in a new preview rather than moving a tag.

## Install, upgrade and rollback

The commands below apply **after the named tag has been published**. They deliberately
use a new directory so an existing checkout and its reports stay available.

```bash
git clone --branch v2.0.0-rc.1 --depth 1 https://github.com/JijoShibu/revctf.git revctf-2.0-preview
cd revctf-2.0-preview
sudo ./install.sh
revctf --version
```

Run installation while online. Subsequent scans can run offline with the installed
dependencies. Allocate 4096 MB to Kali; Linux may report slightly less. Use a new output
directory for each scan. Review exit code 2 and partial stages before accepting any result.

Upgrading from 1.x changes failure reporting and adds the RAM startup check. Existing
scripts must handle exit code 2; `--yes` and saved configuration cannot bypass the RAM
check. `--allow-low-memory` accepts the risk explicitly and leaves warnings in the report.

For rollback, keep the prior checkout and record its commit before installing the preview.
Call its executable by absolute path to avoid changing shared dependencies or PATH:

```bash
/absolute/path/to/previous-revctf/revctf --version
/absolute/path/to/previous-revctf/revctf scan ./challenge --output ./new-rollback-report
```

If that checkout is unavailable, clone the previously verified tag into another directory
and use its executable there. `v1.0.0` was the last published release when this plan was
prepared, but contains older reliability behavior. Rollback does not repair those defects.
Do not reset a working checkout, delete reports, remove shared tools, or retag history.

## Preview feedback and stable 2.0

Prepare the [feedback request](releases/2.0-preview-feedback.md) for GitHub. Post it only
when publication/community posting has been authorized. The issue form asks for the
version, Kali version, RAM, command, expected result and relevant redacted output.

Stable 2.0.0 requires at least seven days since preview publication, one independent Kali
test report, all required checks passing, no unresolved release-blocking defects, and
maintainer review. No scheduled monitoring is created by these instructions.

Substantive fixes produce `rc.2`, `rc.3`, and so on, with affected checks repeated. Keep
the stable gate open until the revised behavior has adequate review. For stable 2.0.0,
update the program version, README, changelog, release notes and consistency checks;
verify the final commit and obtain a separate publication instruction.
