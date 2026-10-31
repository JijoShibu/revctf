# RevCTF 2.1 release-candidate validation

Status: implementation and controlled validation complete; Kali integration and publication pending.

Base: v2.0.0, a4460e6e87b6933b9d2b57a52623317321aa7d78.
The candidate uses a separate worktree and never moves existing release tags.

## Actual local observations

- Ubuntu WSL, Python 3.14.4; controlled test environment, not the supported Kali profile.
- Recovery helper initially failed an XOR-padding case; recognized-wrapper suffixes
  now retain correct source offsets. The focused regression passes.
- Ubuntu initially lacked C runtime start objects. The static compiled fixture uses
  a freestanding ELF link; build dependencies were then installed for broader checks.
- 17 helper tests passed, then 22 tests including real flag-worker, provenance,
  routing, advice and shell-syntax integration passed.
- Existing reliability: 42 passed. Existing accuracy: 8 passed.
- First resource run: 32 passed, 1 failed in unresponsive-Docker cleanup simulation.
  Investigation is required; this failure is retained, not counted as passed.
- ShellCheck first flagged generated-worker quoting; targeted comments explain the
  intentional delayed expansion. The final style rerun is pending.

## Required before publication

Final exact-runtime controlled checks and CI; real 4096 MiB Kali operation; Docker
isolation/lifecycle; Ghidra memory/known answers; installation/reinstallation;
offline scan; upgrade/rollback; timing; retained failed attempts and skips; verified
cleanup; normal VM shutdown and restoration to its original 16384 MiB allocation.

The Kali VM booted at 4096 MiB. SSH was unavailable at its newly assigned address;
maintainer assistance was requested. No submitted challenge was executed there.
Original report fixtures are absent; synthetic regressions must be labeled as such.

The release evidence file deliberately remains pending until these checks actually
complete. Earlier 2.0.0 evidence is preserved as historical evidence only.

## Final controlled matrix

All shell syntax checks, ShellCheck 0.11.0 style checks, and release-version
consistency passed in a native Linux snapshot of the candidate source.

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Reliability | 42 | 0 | 0 |
| Resources | 33 | 0 | 0 |
| Existing accuracy | 8 | 0 | 0 |
| New QA recovery/routing/safety | 33 | 0 | 0 |
| Release gates | 14 | 0 | 0 |
| Publisher | 8 | 0 | 0 |
| Mutation-reader assertions | 9 | 0 | 0 |
| Total | 147 | 0 | 0 |

Runtime fingerprint: `2da3fbf48becb0149603497777c79ff94a2f340478cc60455d4e06a378d57b2c`.
Private local controlled-evidence archive SHA-256: `f94eb8640e2a194cd5a0e3b640e1b252cd4d3cd9f47e1d118cb69b05c01301c4`.
The archive retains the final matrix and earlier failed attempts; it is not a
public source-release asset and does not contain the original missing report fixtures.

The cleanup simulation exposed a real command-pipe deadline problem. TERM with a
one-second forced-stop fallback fixed it; all 33 resource checks then passed.
Ghidra mock tests initially lacked required option/tier setup and an optional-note
default. Correcting those fixtures allowed import-cause and challenge-text negative
controls to execute; both pass. This is not claimed as real Ghidra validation.
The generated-worker quoting diagnostics are also resolved; final style checks pass.

New regressions cover contiguous and reconstructed XOR bytes, literal special-character
paths, unknown wrappers, preserved early records after interruption, source parsing
without execution, real archive depth/member omissions, and regex budget exhaustion.
No submitted challenge or remote challenge service was executed by these tests.

## Real Kali integration: first attempt

The isolated candidate at commit `0d158e18380f18b7ef3a00d0501cb8cc79ca2508`
passed the same 147 controlled assertions on Kali, with the VM allocated 4096 MiB.
The measured guest memory was 3915 MiB. A new known-answer native suite then
recovered plaintext, single-byte XOR, reversed and repeating-key XOR flags. Each
answer was independently accepted by its generated program in a restricted Docker
container; deliberately wrong answers were rejected and input hashes were unchanged.

The fifth, stack-encoded fixture failed exact recovery despite scan exit 0. Its
preserved Ghidra capture used consecutive `local_48[index] = literal;` assignments,
where the reconstruction parser only recognized initializer lists and packed local
stores. The runner stopped at this failure. This attempt is retained as a failure;
the original report binaries remain unavailable.

The parser now recognizes consecutive literal byte stores starting at index zero,
without crossing intervening statements, array names, index gaps or control blocks.
New positive and negative regressions cover the observed decimal/hexadecimal form.
The runtime fingerprint is now
`c0bd4245773977b6c5831dddeaea6cedfa4bbb210f3649e6895880fe84bf0d27`;
the earlier matrix/archive identifies the previous runtime. Final controlled and
real integration validation of the corrected runtime remain required before release.

## Corrected-runtime Kali checks completed so far

The corrected runtime above passed 149 controlled assertions (35 in the QA suite),
shell syntax, style and release consistency on the real 4096 MiB Kali allocation.
All five generated native recovery fixtures now pass exact-candidate, independent
acceptance, wrong-answer rejection, unchanged-input and provenance checks.

Seven real Ghidra checks passed: 512/768/1024 MiB heap requests with measured heaps
below each request and exact enforced process limits, a custom script in a path
with spaces, preserved partial output from a deliberately failing custom script,
and independent correct/wrong password checks. The first shared-corpus invocation
had skipped because the corpus was not built; that preparation failure is retained.
The generator then built 18 artifacts (211 MiB) before real corpus/Ghidra checks.

The first nine Docker lifecycle checks passed. Their broad-suite repeat found an
intermittent OOM-status assertion failure: the cgroup limit was 67108864 bytes and
the retained Docker exit event was 137, but the immediately read OOM status was
false. Three focused probes enforced the same limit, exited 137 and confirmed OOM;
one delivered its OOM event after the container-exit event. The failing original
container had already been destroyed before an OOM event was recorded.

The test now waits at most five seconds for that metadata while still requiring
the exact measured cap, exit 137 and confirmed OOM status. It also preserves the
exit code and final state. All nine corrected lifecycle checks passed in a separate
test copy with only its source-root lookup redirected to the same checkout. This
changes test synchronization, not the application or its resource limits; the
runtime digest stays unchanged. The broader run and remaining release gates are
still pending, and earlier failures/skips must not be counted as passed runs.

The broad run also exposed an outdated QA-3 assertion: it required `triage ok` for
a tar with two members, whereas 2.1 intentionally marks selected-member coverage
partial. The retained capture confirms archive classification, extraction of both
members, selection of an ELF and native routing; it was not an outer-UPX detection
failure. The test now directly requires those behaviors and preserves its original
UPX regression intent. It additionally requires explicit partial coverage/exit 2,
candidate recovery from the selected payload and an unchanged archive hash.

All five corrected archive assertions passed on Kali in a separate harness copy.
The first copy also had unintended Windows-decoding differences in unrelated
Unicode text, and its standalone style check failed. The committed source passed
CI; the actual tracked `qa-archive` section still needs a real Kali rerun to remove
the copy's whole-file correspondence uncertainty. `qa-archive` is an additive developer-test section, also called by the
existing `qa` section; application interfaces and the runtime digest are unchanged.
The original broad-run failure is retained. Its final summary and the remaining
release gates are still required before publication.

## Resumed broad-result review and matcher diagnostic correction

The preserved full Kali run completed at the prior runtime with **343 passed,
3 failed, 2 skipped**. Its failures were the Docker OOM-metadata race, the outdated
archive assertion, and a newly inspected shared 124/137 matcher branch. The two
1 MiB Docker scenarios remain unsupported skips, not successful executions.

The matcher branch reported a per-capture budget for both timeout and SIGKILL.
SIGKILL alone does not identify its cause. Separate branches now name an actual
10-second timeout or an unconfirmed SIGKILL cause, while preserving completed
candidates, continuing other searches and marking coverage incomplete. A controlled
injected-137 regression checks both preserved candidates and the honest diagnostic;
the existing actual-timeout regression remains in place. Both focused checks and
the complete **36-test QA suite** pass in Ubuntu WSL; ShellCheck style passes for
the changed library. These are controlled checks, not renewed Kali evidence.

The new application fingerprint is
`4f6ba2724db11d193288629b704597dd438b1e6d94fd467a291b9e709d6bd64d`.
Current-runtime Kali validation, mutation verification, timing, installation,
offline/upgrade/rollback and restoration remain pending. The original broad log
and failed exit remain retained. No tag or release has been published.
