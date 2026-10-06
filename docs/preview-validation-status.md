# Preview validation status

Historical preview checkpoint, updated 5 October 2026. The preview was not published.
The maintainer subsequently approved direct stable 2.0.0 publication after controlled
checks pass. Use [the stable validation record](stable-validation-status.md) for current
results and remaining requirements; the preview conditions below are historical.

The proposed dependency is Ghidra 12.1.4. Current focused tests have run on the
real 4096 MB Kali VM, where Linux reported 3915 MiB. The final broad regression,
clean installation, offline checks and timing comparisons are still running.
Earlier measurements using Ghidra 11.2.1 remain historical evidence.

## Completed on a temporary GitHub Linux runner

[Run 37302328270](https://github.com/JijoShibu/revctf/actions/runs/37302328270)
checked commit `8e3dc56f846cc0000bdd6ca94f0d88ff171c66c5`:

| Check | Result |
| --- | --- |
| Shell syntax and ShellCheck | Passed |
| Workflow syntax and release consistency | Passed |
| Controlled reliability tests | 41 passed, no failures or skips |
| Linux resource tests | 33 passed, no failures |
| Candidate accuracy and preserved evidence | 7 passed, no failures or skips |
| Publication prerequisite tests | 8 passed |
| Mocked publication failure and recovery tests | 8 passed |

An earlier run failed the early-answer cutoff test. The search copied a saved
capture before matching; that copy failed under the file-size limit, losing the
opportunity to report a complete early candidate. Searching the original capture
directly fixed that failure without raising the limit. The test still checks that
the early answer survives, the later answer is absent, and the result is UNVERIFIED.

Accuracy tests also check answers beyond the old encoded-token and byte cutoffs,
zero-byte boundaries, timeout preservation, mixed Python analysis failures, and
answers beyond the shortened managed-code report. These controlled samples do not
prove that arbitrary challenges can be solved automatically.

The local Windows run passed 38 reliability checks and skipped three Linux-specific
checks. Those skips are not Kali passes. The same controlled checks passed on Linux.

## Current focused Kali results

Kali 2026.3, Intel/AMD 64-bit, Java 21, 4096 MB allocated, 3915 MiB reported.
Existing swap remained configured; it was not created or enlarged for these checks.

| Check | Measured result |
| --- | --- |
| Ghidra heap 512 MiB | 518,979,584 bytes; process limit 768 MiB; completed |
| Ghidra heap 768 MiB | 778,502,144 bytes; process limit 1024 MiB; completed |
| Ghidra heap 1024 MiB | 1,037,959,168 bytes; process limit 1280 MiB; completed |
| Custom Java script in a path containing spaces | Completed with retained results |
| Failed custom Java script | Exit 2, partial results and stopping evidence retained |
| Recovered password supplied to the controlled challenge | Accepted; deliberately wrong answer rejected |
| Docker cleanup, interruption, simultaneous scans and startup interruption | 9 lifecycle checks passed; unrelated container retained |
| Docker output and memory limits | Exact 16 KiB file cap and measured 64 MiB memory breach passed |
| Python dependency installation | Locked runtime/build packages installed; `pip check` clean |
| Incorrect Python package checksum | Download refused as expected |

The first actual Ghidra 12.1.4 scan exposed a result-formatting defect: its Java logger
added prefixes to the completion markers. The reader marked the stage partial but
could not include its useful output properly. Emitting plain Java output fixed it;
all three heap settings and both custom-script cases passed afterward.

The first broad run failed because its extracted source lacked the generated corpus
and its discovery examples still expected unsupported Ghidra versions. A Docker test
also used an unset image variable and another checked an accidental error message.
Those test problems have been corrected. Keep that failed run in the evidence;
the replacement broad run must pass before publication.

## Feedback from an outside tester

On 4 October 2026, the maintainer relayed successful Kali feedback, describing the
latest fixes branch, 4 GB allocated and one challenge with its answer checked.
The maintainer then clarified that a friend received the whole folder, performed
the testing and said everything worked. The maintainer was not the tester.
The friend's own test details, challenge identity, saved report and exact tested
commit have not yet been recorded or inspected.

This is useful outside feedback, relayed through the maintainer. It does not
establish that the full resource, installation or cleanup tests passed. The friend
can provide the independent report for stable 2.0.0 by testing the actual published
preview and following the independent-test instructions. The publication
requirements below remain open.

## Still required before the preview

- Finish the corrected broad Kali run and the deliberately overriding Ghidra launcher
  check. Review every failure and skip.
- Rehearse clean installation, repeat installation, upgrade, rollback and offline scans.
  Confirm actual tools and recovered results rather than installer messages.
- Repeat native and Windows-file regressions, malformed and packed samples, larger
  files, memory pressure, and comparable three-run timings with 4096 MB allocated.
- Preserve all evidence, confirm no test challenge remains running, shut Kali down
  normally, and restore 16384 MB. Record the final runtime digest and remaining skips.
- Review and merge only after those requirements pass. Run the manual release
  workflow and approve its publication job, then verify the public download and scan.

`release-evidence.json` intentionally remains incomplete. A green hosted check does
not bypass these requirements. Stable 2.0.0 additionally requires seven days after
the latest preview is published and a reviewed report from another Kali tester.

The earlier Ghidra timing slowdown remains in the historical validation record;
new measurements must not omit it or shorten analysis to hide it.
