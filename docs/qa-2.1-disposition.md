# Four-report QA disposition for 2.1

Scope agreed with the maintainer: stabilization and flag recovery first; publish a
2.1.0 release candidate after gates pass. Retain Ghost Core as beginner content.
The source reports are inputs, not commands to execute. Original report binaries,
full scan directories and the exact Flag Hunters build were not supplied.

## Implemented in this candidate; integration validation still required

| IDs | Change or disposition |
| --- | --- |
| R01–R03 | Bounded single-byte XOR, reversal and prefix-constrained repeating XOR recovery; synthetic/compiled fixtures do not substitute for the missing original suite. |
| R04 | Unfamiliar decoded wrappers retained at low confidence; recognizable ROT mirrors suppressed. |
| R05 | Flag-like text displayed ahead of hash metadata without claiming acceptance. |
| R06 | Additive evidence sidecar preserves stage occurrences and known offsets/keys. Unknown locations remain null. |
| R07 | Advice depends on actual confidence counts and applicable analysis. |
| F01 | Python-source routing and bounded, non-executing AST hints. |
| F02 | Explicit WASM recognition and accurate unsupported-native skips; a WASM adapter is deferred. |
| F03 | Import errors take precedence over missing guard evidence. |
| F04 | Explain unavailable runtime files/secrets; do not promise a remote solve. |
| F05 | ZIP/tar extraction and selected-payload analysis; multiple-member/depth omissions are partial. Full member batch traversal is deferred. |
| S01 | Pre-execution warning for explicit no-sandbox; retain safe default skip. |
| S02 | Honest writable-scratch/shared-kernel wording and disabled IPC; custom seccomp research deferred. |
| S03 | Bounded Docker probes; rootless/remote-daemon profiles require separate validation. |
| S05 | Reject unsafe ZIP/tar paths, links and special files before payload writes; cumulative streamed per-container budget. |
| S08 | Bound pattern length and syntax validation; preserve the bounded grep-E worker. Engine migration is deferred. |
| S10 | Qualify existing-directory permissions and report-sharing guidance. |
| O05–O06 | Warn that prompts/yes/debug do not supply planned functionality. Their implementations are deferred. |
| Q01 | Controlled recovery/routing/extraction tests added to existing suites and CI. Original fixtures still needed. |
| Q02 | Correct capability, permission, isolation and archive coverage claims. |

## Existing safeguards to revalidate, not new claimed fixes

S04 filename/command safety, S06 private temporary files and locks, S07 explicitly
trusted custom scripts, S09 pinned/hash-verified downloads, S11 owned process/container
cleanup, O01 resource modes, O08 supported dependency profiles, and O09 protective path/
output rejection remain release-validation responsibilities. No exploit is claimed
merely because a report proposed an audit. Do not label an unrun test passed.

## Later features and remaining limitations

R08 hash explanations and R09 symbolic/concolic solving are later work; arbitrary
hash inversion is not promised. O02 aggregate run storage quotas remain open beyond
the improved per-container extraction budget. O03 performance work needs measured
profiles; O04 batch/concurrency, O07 caching, complete O05/O06 behavior, additional
O08 platforms and alternative containment backends remain separate releases.

C01–C08 are challenge-authoring work. Readable secrets, direct equality, symbols and
an easy solve are expected for the retained beginner Ghost Core. Runtime, packaging
and hardening evidence is still needed before making broader claims. C09 is the
intentional Flag Hunters target flaw; it is not a RevCTF injection defect and is not
patched or contacted by this release.

All report concerns are retained under their original IDs. Implemented means code
exists; it does not mean the real Kali release gates have passed.
