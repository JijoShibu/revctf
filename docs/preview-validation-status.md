# Preview validation status

Updated: 4 October 2026. The preview is not ready to publish.

The proposed Ghidra dependency is now 12.1.4. Earlier Kali measurements used
11.2.1, so they are historical evidence rather than approval of the current code.
The final Kali checks and clean installation rehearsal must use the proposed
dependencies and the exact code being released.

## Completed on a temporary GitHub Linux runner

[Run 37113699536](https://github.com/JijoShibu/revctf/actions/runs/37113699536)
checked commit `d309a91d8850ccb668652d1776bd18212591c970`:

| Check | Result |
| --- | --- |
| Shell syntax and ShellCheck | Passed |
| Workflow syntax and release consistency | Passed |
| Controlled reliability tests | 38 passed, no failures or skips |
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

The local Windows run passed 35 reliability checks and skipped three: one required
real symbolic links and two required Linux limits. Those skips are not Kali passes.

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

- Restore access to the real Kali test machine, finish the current Ghidra heap and
  process-limit checks, and independently run recovered answers against the fixtures.
- Repeat Docker cleanup, ownership, interruption, output-limit and isolation checks.
- Finish the dependency lock, then rehearse clean installation, repeat installation,
  upgrade, rollback and offline scans. Test failed downloads and tool installation.
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
