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

Use **Actions → Publish reviewed release → Run workflow** on `main`. Supply the full
reviewed commit and version without `v`. The workflow reruns the basic checks, requires
the current runtime digest in `docs/release-evidence.json`, and stops on unfinished Kali
checks. It builds a deterministic source archive in a read-only job. A separate job
rebuilds that exact archive, compares its checksum, and waits for the `release`
environment's maintainer approval before receiving write access.

The publisher creates an annotated tag with the project author's identity, uploads assets
to a draft, verifies the uploaded hashes, and then publishes. An interrupted draft can be
resumed if its tag and assets still match. Conflicting assets require manual review;
published tags and assets must never be replaced. The workflow downloads the public
archive without sign-in and verifies its checksum. The Kali installation and controlled
scan from that public download are a separate final check.

The evidence file is deliberately incomplete while final tests are pending. Do not mark
checks passed merely to enable publication. Generate its runtime identity with
`python3 tools/release.py digest` after committing runtime changes; record actual logs,
failed attempts, and skips alongside successful final checks.

After explicit authorization, merge the reviewed changes and verify the resulting tree.
Set the published status/date in the README and release notes, commit those edits, and
run version, documentation, syntax, and smoke checks on that final commit. If merging
introduced other code, repeat the affected tests before tagging.

Run the approved workflow at that exact commit. It creates the annotated
`v2.0.0-rc.1` tag, archive and checksum, then publishes the **pre-release** with the
reviewed notes. Do not create a parallel manual release or designate a preview as the
latest stable release.

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
Use its executable by absolute path and select the tools that were verified with that
copy. An absolute executable path alone does not undo changes to `GHIDRA_HOME` or tool
links made by installation. Record those paths before upgrading and keep the old Ghidra,
Python environment and sandbox image available.

```bash
/absolute/path/to/previous-revctf/revctf --version
GHIDRA_HOME=/absolute/path/to/previous-ghidra \
PATH="/absolute/path/to/previous-python-tools/bin:$PATH" \
REVCTF_SBX_IMAGE=previous-verified-sandbox-tag \
/absolute/path/to/previous-revctf/revctf scan ./challenge --output ./new-rollback-report
```

If that checkout is unavailable, clone the previously verified tag into another directory
and use its executable there. `v1.0.0` was the last published release when this plan was
prepared, but contains older reliability behavior. Rollback does not repair those defects.
If the older tools were removed, restore them in a separate environment before scanning;
do not point an older release at the preview tools and assume compatibility.
Do not reset a working checkout, delete reports, remove shared tools, or retag history.

## Preview feedback and stable 2.0

Prepare the [feedback request](releases/2.0-preview-feedback.md) for GitHub. Post it only
when publication/community posting has been authorized. The issue form asks for the
version, Kali version, RAM, command, expected result and relevant redacted output.

Stable 2.0.0 requires at least seven days since preview publication, one independent Kali
test report, all required checks passing, no unresolved release-blocking defects, and
maintainer review. No scheduled monitoring is created by these instructions.

Give independent testers [these instructions](INDEPENDENT-TEST.md). The automatic stable
gate requires seven days since the latest published preview and a maintainer-reviewed
GitHub issue written by the independent tester. Update that record when another preview
needs retesting. Keep the original evidence and release history.

Substantive fixes produce `rc.2`, `rc.3`, and so on, with affected checks repeated. Keep
the stable gate open until the revised behavior has adequate review. For stable 2.0.0,
update the program version, README, changelog, release notes, installer Python-environment
name and both default sandbox tags. The consistency check refuses mismatched defaults;
verify the final commit and obtain a separate publication instruction.
