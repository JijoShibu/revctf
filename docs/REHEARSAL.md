# Clean-VM install rehearsal

`install.sh` has run end-to-end exactly once, on this machine — which already had the whole
toolchain. That run could not detect a missing dependency, because nothing was missing. It
already hid one: `curl`, `ca-certificates` and `python3-venv` are needed by install.sh's own
steps and were never installed by it (fixed 2026-08-28; that fix is what this rehearsal now
tests).

This is the only test that proves a fresh install works. Everything else in the project has
been verified against an environment that grew alongside the code.

**Deployment is `git clone` + `sudo ./install.sh`.** There is no CI, no package, no
distribution channel, and nothing here should add one.

---

## Before you revert the snapshot

The revert destroys the whole VM disk. Two things do not exist anywhere else:

```bash
# 1. The real acceptance binaries — NOT in the repo, and no download URL is recorded.
#    Copy them somewhere the revert cannot reach (VirtualBox shared folder, scp, USB).
sha256sum ~/revctf-realworld/*
#   253e9977f0ec8e9e5ec6f762bf5d3307bf21d1807e366ea3b57261a13fa246a6  unpackme-upx
#   6676a9c9e4eb5870c7312e21c403f5ea7b34c9ed510d161e049d26fcde3f705d  bbbbloat

# 2. Anything uncommitted. Should be nothing — check.
cd ~/revctf && git status --short && git log --oneline -1
```

The repo itself is safe: `main` and every tag are on GitHub.

---

## The rehearsal

Everything lands in `~/rehearsal/`. Create it first, on the clean VM:

```bash
mkdir -p ~/rehearsal && cd ~
```

### Phase 0 — fingerprint the clean VM, before touching anything

This is the baseline. Without it, every later failure is ambiguous between "install.sh is
broken" and "this VM is different from the one everything was verified on".

```bash
{
  echo "=== date ==="; date -u
  echo "=== os ==="; cat /etc/os-release; uname -a
  echo "=== ram/cpu/disk ==="; free -m; nproc; df -h /
  echo "=== systemd ==="; systemctl is-system-running; systemd-run --user --scope true 2>&1 | tail -2
  echo "=== what is ALREADY here (should be short) ==="
  for t in file strings binwalk hexdump ltrace strace radare2 checksec objdump readelf \
           upx floss analyzeHeadless docker git curl python3 gcc javac zip; do
      printf '%-16s %s\n' "$t" "$(command -v $t || echo MISSING)"
  done
  echo "=== packages ==="
  dpkg -l python3-venv curl ca-certificates docker.io 2>&1 | tail -8
  echo "=== env that changes behaviour ==="
  echo "DOCKER_HOST=${DOCKER_HOST:-<unset>}"; echo "GHIDRA_HOME=${GHIDRA_HOME:-<unset>}"
  echo "PATH=$PATH"
} 2>&1 | tee ~/rehearsal/00-baseline.txt
```

`DOCKER_HOST` and `GHIDRA_HOME` are in there deliberately — a stale value in either is a
documented trap that makes a working install look dead.

### Phase 1 — clone and install (this is the thing under test)

```bash
cd ~ && git clone https://github.com/JijoShibu/revctf.git 2>&1 | tee ~/rehearsal/01-clone.txt
cd ~/revctf && git log --oneline -1 | tee -a ~/rehearsal/01-clone.txt

SECONDS=0
sudo ./install.sh 2>&1 | tee ~/rehearsal/02-install.txt
echo "exit=${PIPESTATUS[0]} elapsed=${SECONDS}s" | tee -a ~/rehearsal/02-install.txt
```

Do not fix anything by hand during this phase, and do not run `bootstrap-kali.sh`. If
install.sh cannot get there on its own, that is the result.

**A non-zero exit is expected if Docker is absent** — see the predictions table below.

### Phase 2 — what actually landed

```bash
{
  echo "=== exit-relevant tools ==="
  for t in file strings binwalk hexdump ltrace strace radare2 checksec objdump readelf \
           upx floss uncompyle6 revctf analyzeHeadless docker; do
      printf '%-16s %s\n' "$t" "$(command -v $t || echo MISSING)"
  done
  echo "=== VERSIONS (CLAUDE.md §3 facts are version-stamped and decay) ==="
  upx --version 2>&1 | head -1; r2 -v 2>&1 | head -1; binwalk --help 2>&1 | head -2
  checksec --version 2>&1 | head -2; floss --version 2>&1 | head -1
  ls -d /opt/ghidra* 2>&1
  echo "=== install targets ==="
  ls -l /usr/local/bin/ | grep -Ei 'revctf|floss|uncompyle'
  ls -la ~/.revctf/ ; ls -l ~/revctf/scripts/pyinstxtractor.py 2>&1
  grep -n GHIDRA_HOME ~/.bashrc 2>&1
  docker image inspect revctf-sandbox:1 --format '{{.Id}} {{.Created}}' 2>&1
} 2>&1 | tee ~/rehearsal/03-postinstall.txt
```

The version block is not padding. §3 of CLAUDE.md records tool facts stamped with the
version they were measured against, and two have already decayed silently. A fresh apt
pulls whatever is current today, so if a harness check fails in Phase 5 I need these
versions to tell a decayed fact apart from an install defect.

### Phase 3 — dry run: one command, most of the diagnosis

```bash
cd ~/revctf
./revctf --version 2>&1 | tee ~/rehearsal/04-dryrun.txt
./revctf scan ~/unpackme-upx --dry-run 2>&1 | tee -a ~/rehearsal/04-dryrun.txt
```

This prints, without executing anything: the preflight verdict, the config path, detected
RAM and the resolved tier, every ceiling, which mechanism enforces them, and a per-stage
run/skip decision **with the reason** — including exactly why the sandbox is or is not
available. If you only capture one file, capture this one.

### Phase 4 — the real scan (the acceptance proof)

Put `unpackme-upx` back on the VM first and check the hash.

```bash
sha256sum ~/unpackme-upx   # must be 253e9977f0ec8e9e5ec6f762bf5d3307bf21d1807e366ea3b57261a13fa246a6

cd ~/revctf
SECONDS=0
revctf scan ~/unpackme-upx --output ~/rehearsal/scan-unpackme 2>~/rehearsal/05-scan.stderr | tee ~/rehearsal/05-scan.stdout
echo "exit=${PIPESTATUS[0]} elapsed=${SECONDS}s" | tee -a ~/rehearsal/05-scan.stderr
```

Note `revctf`, not `./revctf` — that also tests the `/usr/local/bin` symlink install.sh made.

**Pass condition** — the `POSSIBLE FLAGS` section must read exactly this:

```
[FLAG] Possible flags found: 1 high, 1 medium, 0 low confidence
--- high confidence ---
  picoCTF{up><_m3_f7w_77ad107e}
      found by: ghidra (recovered by stack-string+ROT47 decoding)
```

```bash
sed -n '/POSSIBLE FLAGS/,/^=\{10,\}/p' ~/rehearsal/scan-unpackme/report.txt \
  | tee ~/rehearsal/06-flags.txt
```

Two things about this check, both of which have caused mistakes here before:

**Scope it to the section.** The flag is recovered *by Ghidra*, and the report embeds every
stage capture — so the string is in the report body whether or not the flag scanner ran at
all. A whole-report `grep picoCTF` passes with the scanner completely dead. Grep the
`POSSIBLE FLAGS` section or you are testing nothing.

**This is really a Ghidra-install test.** `found by: ghidra` is the whole point: the flag is
a stack string, invisible to `strings` before or after unpacking, and FLOSS's stack-string
extraction is PE-only. Nothing but the decompile pass can reach it. So `0 high` here means
Ghidra did not install, did not run, or installed as a 12.x build whose post-script fails
while `analyzeHeadless` still exits 0 — which is precisely the silent failure install.sh
pins 11.2.1 to avoid. If you see `0 high`, capture `ghidra.stderr` from the output directory
and check `ls -d /opt/ghidra*`.

One caution when reading the historical record: `docs/acceptance-run-2026-08-21.md`
reports **0 high** for both targets. That is correct for the code of that date — the
stack-string decoder did not exist yet — and is not the baseline for this rehearsal. The
raw capture directories it refers to were removed from the repo before the public release
(5.2MB of tool output carrying absolute home paths); the block above is the expected
result, and it is the whole comparison.

Expect 2–5 minutes, dominated by Ghidra.

### Phase 5 — corpus and suite

`install.sh` deliberately does **not** install the corpus build dependencies (they are
build-only, and a user scanning a challenge never needs them). So this phase needs one
explicit extra step, and that is not a defect:

```bash
sudo apt-get install -y gcc build-essential gcc-mingw-w64 default-jdk zip unzip python3-pip

cd ~/revctf
./tools/build-test-corpus.sh 2>&1 | tee ~/rehearsal/07-corpus.txt
ls -l test-corpus/ | tee -a ~/rehearsal/07-corpus.txt     # expect 18 artifacts

./tools/run-tests.sh 2>&1 | tee ~/rehearsal/08-suite.txt   # ~15 min
tail -5 ~/rehearsal/08-suite.txt
```

Baseline on the pre-revert machine: **341 passed, 0 failed.** Any deviation is the finding.

If time is short, `REVCTF_TEST_FAST=1 ./tools/run-tests.sh` (~3 min) skips the 220MB-target
checks — say so if you use it, because it changes what "green" covers.

### Phase 6 — send me the logs

```bash
cd ~ && tar czf rehearsal-$(date +%Y%m%d).tar.gz rehearsal/ && ls -lh rehearsal-*.tar.gz
```

Or just paste `00-baseline.txt`, `02-install.txt` and `04-dryrun.txt` — those three carry
most of the diagnostic weight.

---

## Predicted failures, and what each one means

Written down in advance so a predicted failure does not cost a second revert cycle.

| What you will see | Cause | Is it a defect? |
|---|---|---|
| `warning: docker is not installed` → summary `1 step(s) failed` → **exit 1** | Kali does not ship Docker and install.sh does not install it | **Open question — your call.** README already calls Docker required for the default sandbox. See below |
| ltrace and strace `[skip]` in the dry run, naming Docker | Deviation D13 working correctly — revctf never falls back to running the target on the host | No. This is the designed behaviour |
| `optional package unavailable: jd-cli` (or procyon / mono-utils) | D7 tier two: format-conditional decompilers fail lazily | No. Warned, not counted as failed |
| Ghidra step slow or times out | ~400MB download | Only if it fails — capture the error |
| `GHIDRA_HOME` missing in the current shell after install | Appended to `~/.bashrc`; new shells only. D12 falls back to `/opt/ghidra*` | No, but confirm the fallback found it in Phase 3 |
| A harness check fails naming `upx`, `radare2` or a stripped binary | A §3 fact decayed on a newer tool version | Not an install defect. Phase 2's version block is how we tell |
| Phase 4 reports `0 high` and no `picoCTF{...}` | Ghidra did not install, or a 12.x build installed whose post-script fails while `analyzeHeadless` exits 0 | **Yes, and it is the most important one.** Capture `ghidra.stderr` and `ls -d /opt/ghidra*` |
| `python3 -m venv` fails with *ensurepip is not available* | The gap fixed on 2026-08-28 | **Yes — and it means the fix did not work.** Report it |

### The one open question the rehearsal will force

`install.sh` does not install Docker, but the sandbox is on by default and README calls
Docker required. So a clean `clone + install.sh` currently ends in exit 1 with two stages
disabled. Three ways to resolve it, and it is a product decision, not a bug fix:

1. **Install `docker.io` in `install.sh`** — the deployment path then produces a fully
   working revctf. Costs ~500MB and starts a daemon on the user's machine.
2. **Leave it, and stop counting it as a failure** — install.sh exits 0, prints how to get
   Docker, and revctf runs with the two executing stages skipped. Honest, and matches
   step_sandbox's own comment that a miss here "degrades revctf, it does not break it".
3. **Leave it exactly as is** — exit 1 is a loud, accurate report that the install is
   incomplete.

Decide after seeing the rehearsal output, not before.

---

## What happens with the result

**Clean** — the gate is recorded in `CHECKLIST.md` and `implementation-notes.md` with the
VM's Kali version and the tool versions from Phase 2, since an install result is only true
of the environment it was observed in. One commit, pushed.

**Anything fails** — it is a **v1.0.1 point release, not a re-tag**. `v1.0.0` stays as an
accurate record of what was verified at the time, and its tag message already names its
outstanding gates, so nothing in it becomes false.
