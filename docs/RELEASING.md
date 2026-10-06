# Releasing RevCTF

Maintainer: Jijo Shibu <jijoshibu@gmail.com>

The release target is **v2.0.0**, reviewed in pull request #2. On 5 October 2026,
the maintainer approved direct stable publication after the controlled checks pass.
The earlier seven-day preview and independent-report requirements were withdrawn.
That decision is recorded for this release in `release-evidence.json`; it does not
bypass accuracy, resource, installation, cleanup or archive checks.

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

## Publish an approved release

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
`v2.0.0` tag, archive and checksum, then publishes the stable release with the
reviewed notes. Do not create a parallel manual release or overwrite an existing tag.

Download the published archive anonymously, verify the checksum, unpack it into a new
directory, and check `--version`, file permissions, shell syntax, and a controlled scan.
Record the release URL, tag commit, archive checksum and verification result. A failed
published-artifact check blocks promotion; publish a corrected version rather than moving a tag.

## Install, upgrade and rollback

The commands below apply **after the named tag has been published**. They deliberately
use a new directory so an existing checkout and its reports stay available.

```bash
git clone --branch v2.0.0 --depth 1 https://github.com/JijoShibu/revctf.git revctf-2.0.0
cd revctf-2.0.0
sudo ./install.sh
revctf --version
```

Run installation while online. Subsequent scans can run offline with the installed
dependencies. Allocate 4096 MB to Kali; Linux may report slightly less. Use a new output
directory for each scan. Review exit code 2 and partial stages before accepting any result.

Upgrading from 1.x changes failure reporting and adds the RAM startup check. Existing
scripts must handle exit code 2; `--yes` and saved configuration cannot bypass the RAM
check. `--allow-low-memory` accepts the risk explicitly and leaves warnings in the report.

For rollback, keep the prior checkout and record its commit before installing 2.0.0.
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
do not point an older release at the new tools and assume compatibility.
Do not reset a working checkout, delete reports, remove shared tools, or retag history.

## Feedback and future releases

The GitHub bug-report form asks for the version, Kali version, RAM, command, expected
result and relevant output. Remove passwords and private challenge material before
sharing a report. Independent tests remain useful even though they are not a
publication condition for 2.0.0. Give testers [these instructions](INDEPENDENT-TEST.md).
No community posts or background monitoring are scheduled by this procedure.

For future releases, agree the publication policy before preparing the version. The
usual stable gate still requires a reviewed independent report and seven days of
preview availability. The recorded direct-release decision applies only to 2.0.0.
Fixes get new versions; never move a published tag. Update the program, README,
changelog, release notes, Python environment name and sandbox defaults together.
Recheck the final commit and repeat checks affected by each change.
