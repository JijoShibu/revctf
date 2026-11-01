# Releasing RevCTF

The current target is **v2.1.0-rc.1**. The maintainer authorized stabilization and
flag recovery first, followed by a release candidate. Stable 2.1.0 is a separate
promotion; the 2.0.0 direct-stable exception does not apply.

## Required sequence

1. Work on a new branch; never move a published version tag or replace release assets.
2. Run syntax, ShellCheck, workflow/version consistency, all controlled suites and
   the QA recovery suite. Save failures and skips as well as the final results.
3. Validate the exact runtime on Kali amd64 at a real 4096 MiB VM allocation: known
   answers, resource/output limits, Ghidra, real Docker cleanup/isolation, broad
   regression, installation/reinstallation, offline scan, timing and upgrade/rollback.
   Original independent report fixtures remain unavailable; label synthetic fixtures.
4. Keep `docs/release-evidence.json` pending until each check really completes.
   Compute the runtime digest after adding/committing runtime files. Historical
   evidence in `docs/releases/2.0.0-evidence.json` cannot satisfy the new gate.
5. Preserve evidence; confirm all owned processes/containers have stopped. Shut the
   test VM down normally and restore its original 16384 MiB allocation.
6. Push a reviewed PR and require the protected `controlled-tests` check. The user's
   request authorizes release preparation, merging once gates pass, and publication.
   Do not bypass branch protection, a failed check, or release-environment approval.
7. Merge, recheck the final source identity, and run **Publish reviewed release** on
   main with the exact full commit and version `2.1.0-rc.1`.
8. The existing workflow builds/verifies the deterministic archive, checks current
   Kali evidence, uses the protected release environment, creates an annotated tag,
   verifies uploaded checksums and publishes the prerelease. It does not replace tags.
9. Independently download the public archive, verify its SHA-256, unpack in a fresh
   directory, inspect executable modes and run a controlled installed scan on Kali.
   Record the public URL, tag commit, archive checksum and actual verification result.

Do not mark evidence passed merely to enable publication. Ubuntu and hosted checks
are controlled coverage; they do not replace the real Kali/Ghidra/Docker profile.

## Rollback and promotion

Preserve the verified v2.0.0 checkout and its Ghidra, Python environment and sandbox
image before installation. Invoke that executable and tool profile explicitly, with
new report directories. Do not reset another working checkout or delete reports.
The new installer uses a versioned Python environment and sandbox image.

Stable promotion requires the normal matching-preview availability and independent
report gates enforced by the publisher. A failed public-artifact check requires a
new candidate; never retag the existing candidate or reuse a stale evidence digest.
