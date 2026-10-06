# RevCTF 2.0.0 release validation

Updated: 6 October 2026. This record covers the proposed release source; the public
download is checked separately after publication.

The maintainer approved direct stable publication after the controlled checks pass.
The earlier preview wait and independent test report requirements were withdrawn.
Neither decision waives checks of answers, memory, cleanup or installation.

## Environment and source

Tests used Kali 2026.3 on an Intel/AMD 64-bit VM allocated 4096 MB. Linux reported
3915 MiB. Existing swap was preserved and heavy analysis ran sequentially. Test
processes cleared a login setting pointing Docker at an unavailable Podman service;
the saved login configuration was left intact.

The application was checked at commit `55302d625cda6eb6600269cc92e34ae97c6aef6c`.
Later release-tool and documentation changes are checked separately. The final
release evidence and package manifest identify the complete runtime by SHA-256.

## Results

| Area | Result |
| --- | --- |
| Controlled reliability | 42 passed |
| RAM and output resource checks | 33 passed |
| Candidate accuracy and preserved captures | 8 passed |
| Real Docker lifecycle | 9 passed |
| Ghidra measurements, scripts and acceptance | 7 passed |
| Windows file, malformed file and overriding launcher | 3 passed |
| Broad regression, including large files | 346 passed, no failures, 2 optional checks skipped, across resumed runs |
| Deliberately broken versions | All six actual executions confirmed; 36 verification assertions passed |
| Clean and repeat installation | Passed in disposable Kali environment |
| Offline installed scan | Passed; known password accepted and wrong answer rejected |
| Upgrade and rollback | Both passed; known password accepted and existing source/reports unchanged |
| GitHub checks | Shell syntax, ShellCheck, workflow syntax, version consistency and 114 controlled tests passed before final documentation |

The broad run was interrupted during its final sections. Its completed sections
recorded 282 passes and two skips. The unfinished sections were rerun at 4 GB and
completed with 64 passes, no failures or skips. The original interrupted run is
retained; it is not presented as a single successful end-to-end invocation.

Test verification omits repeated large-file stress checks. Those checks ran in the
separate broad regression. A skipped check cannot establish that a defect was
detected; each deliberately introduced defect must turn its named checks red.

Ghidra's actual limits were measured before analysis:

| Requested analysis heap | Measured heap bytes | Whole-process limit |
| --- | --- | --- |
| 512 MiB | 518,979,584 | 768 MiB |
| 768 MiB | 778,502,144 | 1024 MiB |
| 1024 MiB | 1,037,959,168 | 1280 MiB |

The recovered password was supplied to the controlled challenge and accepted. A
wrong answer was rejected. A custom Java script in a path containing spaces worked;
a deliberately failing script preserved evidence and returned exit code 2 as expected.
An overriding launcher requesting a 2 GB heap was rejected by the memory check.
Windows-file results were checked against a known answer, without executing Windows
programs on Kali. RevCTF still labels candidates UNVERIFIED.

The clean Kali container had no host Docker socket or privileged mode. Its network
was disconnected for the installed scan. The installer and repeat installation
returned 0, required tools were present, the expected candidate and password were
recovered, and the password acceptance check succeeded. Optional `procyon-decompiler`
and `jd-cli` packages were unavailable; their Java decompiler paths are not validated.

## Timing

Three comparable runs per sample used the same requested analysis. The baseline
was the locally verified 2.0.0-rc.1 snapshot at `2270dc290b5d2394aa3fcade67bcadf53042e22f`,
using Ghidra 11.2.1. That preview snapshot was never published. The revised profile
used Ghidra 12.1.4 and locked Python tools. These compare complete profiles rather
than only Bash changes. An unsupported `stages_disabled` key did not disable steps
in either copy; trace steps were omitted with supported command options in both.

| Sample | Before median | After median | Change |
| --- | --- | --- | --- |
| Ordinary scan | 12.114 s | 11.866 s | -2.0% |
| Packed scan | 15.623 s | 10.772 s | -31.1% |
| Ghidra-enabled scan | 34.590 s | 35.227 s | +1.8% |
| Additional Ghidra-enabled round | 41.081 s | 32.520 s | -20.8% |

The additional round completed three pairs with the correct recovered answer and
exit code 0. Earlier rounds showed a combined median increase from 35.95 to
39.64 seconds (+10.3%). Keep that slowdown in the record: caches and tool versions
affect these small samples. Searches and allowances were not shortened for timing.
These observations do not promise a general speed improvement.

The rollback rehearsal used that retained preview snapshot and its older tools.
It does not establish that the published v1.0.0 tag has the newer safeguards.

## Failed attempts and skips

- The original fault-verification run reported one false failure. Reading the same
  stored baseline 50 times reproduced six false missing-result reports: an early
  match closed the pipe before the reader finished. The corrected reader consumes
  the complete stream and passed nine focused checks. All six actual captured
  executions were rechecked with it: 36 assertions passed, no failures. Application
  and fixture inputs were unchanged; no new application version is claimed tested
  by merely replaying old results. Original failures and captures are retained.
- An earlier broad run had 342 passes, two failures and two skips. A lost Python
  memory-failure explanation was corrected and checked again. An outdated installer
  assertion was also corrected and rerun. The later completed sections pass.
- The first Windows helper expected a literal flag in Ghidra's text. Ghidra instead
  used a named reference; the actual candidate section already contained the right
  flag. The helper now checks that section and completed decompilation, and fails
  if either check fails. The corrected check passed.
- An initial launcher-check script had Windows line endings. Correcting the transfer
  allowed the actual oversized-heap rejection to be checked successfully.
- An earlier run lacked generated samples and used outdated discovery expectations
  and a wrong sandbox-image setting. Those setup errors were corrected; their logs
  remain with the validation evidence.
- A Windows-host consistency command selected WSL's Bash and failed. The required
  Linux consistency check passed. Windows is not a supported execution host.
- VM access failures and an approval-service usage limit delayed checks. A later
  shutdown interrupted a broad run and left one stopped owned test container.
  Its identity was verified before removal, and its captures were preserved.
- Two optional 1 MiB Docker trace-memory breach checks were skipped because Docker
  requires about 6 MiB. A separate measured 64 MiB breach check passed. These skips
  are not counted as passes.

## Cleanup and remaining limits

Final evidence preservation, verified container absence, normal shutdown and
16384 MB restoration are the remaining local release steps. Publication is blocked
until those steps and final documentation checks are recorded as complete.

Detailed logs, captures, failed attempts and timing records are retained locally,
outside the repository and release source archive. The final archive checksum is recorded after preservation.

Actual operation at 2 GB remains unverified and requires the explicit
`--allow-low-memory` override. Four gigabytes is a recommendation, not a guarantee
that every challenge finishes. Host crashes and SIGKILL can prevent cleanup code
from running. A possible flag does not establish acceptance, and some challenges
still need human reasoning. Custom Python Ghidra scripts need a compatible runtime.

The friend's relayed successful test remains informal feedback: its exact source
and saved report were not verified. It is not substituted for the controlled checks.
