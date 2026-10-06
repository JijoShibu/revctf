# RevCTF 2.0.0 release validation

Updated: 6 October 2026. Publication remains pending.

The maintainer approved stable 2.0.0 publication after controlled checks pass and
withdrew the earlier preview wait and independent-report requirements. This does
not waive checks of answers, memory, cleanup, installation or the source download.

## Completed evidence

The real Kali VM used 4096 MB, with Linux reporting 3915 MiB. Existing swap was
left unchanged. Heavy analysis ran sequentially. Tests used the local Docker daemon;
the login environment pointed DOCKER_HOST at an unavailable Podman service, so the
test commands cleared that variable for their own processes.

| Area | Result |
| --- | --- |
| Controlled reliability | 41 passed |
| RAM and output resource checks | 33 passed |
| Candidate accuracy and preserved captures | 8 passed |
| Real Docker lifecycle | 9 passed; exact owned containers removed; unrelated container retained |
| Ghidra 12.1.4 | 7 passed, including measured heaps, custom scripts, deliberate failure and answer acceptance |
| Corrected resource enforcement | 34 passed, no failures, 2 skipped |
| Corrected documentation assertions | 20 passed, no failures or skips |
| Clean installation and repeat installation | Passed in disposable Kali environment |
| Offline installed scan | Passed; known password accepted, wrong answer rejected |

The broad regression initially reported 342 passed, 2 failed and 2 skipped. One
failure exposed a lost Python memory-failure explanation; the code was corrected,
and accuracy and resource enforcement were rerun successfully. The other was an
outdated test assertion for the installer, corrected and rerun successfully. Keep
these failed attempts; the broad run was not wholly green.

The two resource skips concerned proving a Docker trace memory breach at a 1 MiB
setting where the smallest working container needed about 6 MiB. They are not
passes. A separate real 64 MiB Docker memory-breach check passed. Optional analysis
formats and Windows program execution do not extend the core support promise.

Actual Ghidra measurements were:

| Requested heap | Measured heap bytes | Whole-process allowance |
| --- | --- | --- |
| 512 MiB | 518,979,584 | 768 MiB |
| 768 MiB | 778,502,144 | 1024 MiB |
| 1024 MiB | 1,037,959,168 | 1280 MiB |

The known password was recovered from the decompilation and supplied to the test
challenge. It was accepted, while the wrong-answer control was rejected. RevCTF
still labels candidates UNVERIFIED; it does not automatically establish acceptance
for arbitrary challenges.

## Timing

Three comparable runs per sample completed before the final version/default change.
Each recovered the expected answer. The baseline used the older verified tools,
including Ghidra 11.2.1; the revised copy used Ghidra 12.1.4 and locked Python tools.
These measurements therefore compare complete tool profiles, not just Bash edits.

| Sample | Before median | After median | Change |
| --- | --- | --- | --- |
| Ordinary scan | 12.114 s | 11.866 s | -2.0% |
| Packed scan | 15.623 s | 10.772 s | -31.1% |
| Ghidra scan | 34.590 s | 35.227 s | +1.8% |

The additional Ghidra round was interrupted after four of six runs. It must be
repeated. Earlier rounds also showed a combined median increase from 35.95 to
39.64 seconds (+10.3%); that slowdown remains part of the historical record.
Searches were not shortened to improve timings. These samples are not a general
speed guarantee.

## Final stable checks still required

The 2.0.0 source preparation is commit
`f8192c2ee3a079dfc9195c1f39b96e71559ad692`. Its versioned Python environment and
sandbox defaults differ from the earlier tested preview defaults. Repeat affected
installation, sandbox and controlled scan checks against this source.

[GitHub run 37418030285](https://github.com/JijoShibu/revctf/actions/runs/37418030285)
passed shell syntax, ShellCheck, workflow checks, version consistency, 41 reliability
checks, 33 resource checks, 8 accuracy checks, 10 release-gate tests and 8 publisher
tests. Hosted checks supplement real Kali tests.

Still required:

- Final Kali source checks, real default sandbox, installation and offline scans.
- Oversized Ghidra launcher rejection; Windows-file and malformed-file checks.
- The additional three-pair Ghidra timing round and verification that deliberately
  broken code causes the named tests to fail.
- Upgrade and rollback evidence, with existing reports and old tools preserved.
- Evidence preservation, no surviving test challenges, normal shutdown and 16384 MB restoration.
- Exact final-commit GitHub checks, reviewed merge, manual release process, and
  anonymous archive verification plus a controlled scan of that download.

On 6 October, Kali started at 4096 MB and briefly allowed saved results to be read,
then stopped responding to command requests. Normal shutdown was requested.
The new validation job has not been confirmed started. The release evidence file
remains incomplete. No merge, tag or publication is claimed.

The friend's relayed successful test remains informal feedback: its exact source
and saved report have not been verified. It is not substituted for the checks above.
Operation with an actual 2 GB allocation remains unverified. Host crashes and
SIGKILL can prevent cleanup code from running.
