# Preview validation status

Updated: 3 October 2026. The preview is not ready to publish.

The proposed Ghidra dependency is now 12.1.4. Earlier Kali measurements used
11.2.1, so they are historical evidence rather than approval of the current code.
The final Kali checks and clean installation rehearsal must use the proposed
dependencies and the exact code being released.

## Completed on a temporary GitHub Linux runner

[Run 37113436084](https://github.com/JijoShibu/revctf/actions/runs/37113436084)
checked commit `b835cea74e250241b8ca34eb600226a2763e8a92`:

| Check | Result |
| --- | --- |
| Shell syntax and ShellCheck | Passed |
| Workflow syntax and release consistency | Passed |
| Controlled reliability tests | 38 passed, no failures or skips |
| Linux resource tests | 33 passed, no failures |
| Candidate accuracy and preserved evidence | 7 passed, no failures or skips |
| Publication prerequisite tests | 8 passed |

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
