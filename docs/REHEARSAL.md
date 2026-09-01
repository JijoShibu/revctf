# Clean-install rehearsal

**Purpose.** Prove that a box following only the documented steps ends with a working
`revctf` and a green harness — and catch this project's recurring defect, *things that look
installed or tested but quietly do nothing*, before a release.

**Deployment is `git clone` + `sudo ./install.sh`.** There is no CI, no package, no
distribution channel, and nothing here should add one.

**Golden rule.** Never trust an exit code. After every step check the *artifact the user
keeps* — the tool on `PATH`, the file on disk, the flag in the report — not "the script
said OK."

This file replaces the two earlier rehearsal documents (a root `REHEARSAL.md` and an older
`docs/REHEARSAL.md`). There is one plan so no session runs the wrong one.

---

## Why a container, not the dev VM

`install.sh` has run end-to-end on a machine that already had the whole toolchain. That run
could not detect a missing dependency, because nothing was missing. It already hid one:
`curl`, `ca-certificates` and `python3-venv` are needed by install.sh's own steps and were
never installed by it (fixed 2026-08-28).

The dev VM cannot test this. It is provisioned, and reverting a snapshot costs a full
rebuild cycle. **A throwaway `kalilinux/kali-rolling` container runs the install as root on
a genuinely empty box** — verified 2026-09-01, where the zero-state probe found *everything*
absent including `python3`, `curl` and `git`.

Use the VM for the harness, the scans and the two human gates. Use a container for the
install.

---

## Phase A — from-zero install (the load-bearing gate)

Two runs, because the interesting behaviour is what happens when Docker is absent.

### A-1 · Happy path, Docker reachable

Confirms the full install including the sandbox image.

```bash
unset DOCKER_HOST
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/rehearsal/a1-inside.sh:/a1.sh:ro \
  kalilinux/kali-rolling bash /a1.sh
```

> **The socket mount gives the container root-equivalent control of the host daemon.** That
> is why install.sh can build `revctf-sandbox:1` from inside. Run it only on a machine you
> own, from a throwaway `--rm` container. Some agent sandboxes refuse this mount; if yours
> does, run A-1 by hand and let A-2 carry the automated result.

### A-2 · Docker absent

No socket, no `docker.io`. This is the run that *observes* the missing-Docker behaviour the
provisioned box hides, and it needs no privileged mount.

```bash
unset DOCKER_HOST
docker run --rm -v ~/rehearsal/a2-inside.sh:/a2.sh:ro \
  kalilinux/kali-rolling bash /a2.sh
```

### What the in-container script must do

Order matters — the zero-state proof has to come first or it proves nothing.

```bash
export DEBIAN_FRONTEND=noninteractive

# 1. ZERO-STATE PROOF, before touching anything.
for t in file objdump binwalk ltrace strace r2 checksec upx 7z floss \
         analyzeHeadless python3 curl git; do
  command -v "$t" >/dev/null 2>&1 && echo "PRESENT: $t" || echo "absent:  $t"
done
#    Every line must read "absent". A PRESENT line means this is not a from-zero test.

# 2. Bootstrap ONLY what fetching the repo needs. For A-1 add docker.io; for A-2 do not.
apt-get update -qq && apt-get install -y -qq git

# 3. Clone and install.
git clone https://github.com/JijoShibu/revctf.git /root/revctf
cd /root/revctf && ./install.sh; echo "install.sh exit=$?"   # note it, do NOT trust it

# 4. VERIFY ARTIFACTS. Package name != binary name, so map them explicitly —
#    a `${pkg%%-*}` style probe reports a false MISS for binutils and p7zip-full.
for pkg in file:file binutils:objdump binwalk:binwalk ltrace:ltrace strace:strace \
           radare2:r2 checksec:checksec upx-ucl:upx p7zip-full:7z \
           squashfs-tools:unsquashfs; do
  b=${pkg##*:}
  command -v "$b" >/dev/null 2>&1 && echo "ok   $pkg" || echo "MISS $pkg"
done
command -v floss && floss --version            # must come from a venv, not system pip
command -v analyzeHeadless; ls -d /opt/ghidra_*  # must be 11.2.1, never 11.3+ / 12.x
ls -l scripts/pyinstxtractor.py                # fetched, or PyInstaller unwrap is dead
docker images | grep -i revctf                 # A-1 only: sandbox image built?
revctf --version
dpkg -l curl ca-certificates python3-venv      # the 2026-08-28 bootstrap fix
```

**Gate A:** every core tool resolves; FLOSS runs from a venv; Ghidra is 11.2.1;
`pyinstxtractor.py` exists; A-1 built the sandbox image; and A-2's missing-Docker behaviour
is recorded exactly as observed.

---

## Phase B — code from the public source

```bash
cd ~ && git clone https://github.com/JijoShibu/revctf.git ~/rehearsal/clone
cd ~/rehearsal/clone
git tag --list | sort -V         # v1.0.0 must be here; a missing tag is itself a finding
git describe --tags --always
head -1 revctf | cat -A          # must end in `$`, not `^M$`
file revctf tools/*.sh lib/*.sh | grep -i CRLF && echo "!! CRLF" || echo "LF ok"
```

Clone **anonymously** — `GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone …`. With
stored credentials in play a private repo clones too, and the check proves nothing.

**Gate B:** cloned from GitHub, `v1.0.0` present, no CRLF.

---

## Phase C — corpus and harness

`install.sh` deliberately does **not** install the corpus build dependencies. They are
build-only and a user scanning a challenge never needs them, so this extra step is not a
defect:

```bash
sudo apt-get install -y gcc build-essential gcc-mingw-w64 default-jdk zip unzip python3-pip

cd ~/revctf
./tools/build-test-corpus.sh          # expect 18 artifacts
./tools/run-tests.sh                  # ~15 min
./tools/verify-harness.sh             # proves the checks bite
```

Run the suite **alone**. Two JVMs at 1024M on a ~3.9GB host is a squeeze, and concurrent
runs have produced four phantom Ghidra failures that cost a session to diagnose.

Baseline: **342 passed, 0 failed, 1 skipped** (the skip is `jd-cli`, a D7 lazy-failure
tool). Any deviation is the finding.

`REVCTF_TEST_FAST=1` (~3 min) skips the 220MB-target checks — say so if you use it, because
it changes what "green" covers.

**Gate C:** 342 green, and `verify-harness.sh` proves the harness bites.

---

## Phase D — real acceptance scan

The synthetic corpus cannot cover this. Put `unpackme-upx` on the box and check the hash
first — these binaries are in no repo and no download URL is recorded:

```
253e9977f0ec8e9e5ec6f762bf5d3307bf21d1807e366ea3b57261a13fa246a6  unpackme-upx
6676a9c9e4eb5870c7312e21c403f5ea7b34c9ed510d161e049d26fcde3f705d  bbbbloat
```

```bash
revctf scan ~/unpackme-upx --output ~/rehearsal/scan-unpackme
```

Note `revctf`, not `./revctf` — that also tests the `/usr/local/bin` symlink.

**Pass condition** — the `POSSIBLE FLAGS` section must read exactly this:

```
[FLAG] Possible flags found: 1 high, 1 medium, 0 low confidence
--- high confidence ---
  picoCTF{up><_m3_f7w_77ad107e}
      found by: ghidra (recovered by stack-string+ROT47 decoding)
```

```bash
sed -n '/POSSIBLE FLAGS/,/^=\{10,\}/p' ~/rehearsal/scan-unpackme/report.txt
```

Two things about this check, both of which have caused mistakes here before:

**Scope it to the section.** The flag is recovered *by Ghidra*, and the report embeds every
stage capture — so the string is in the report body whether or not the flag scanner ran at
all. A whole-report `grep picoCTF` passes with the scanner completely dead.

**This is really a Ghidra-install test.** `found by: ghidra` is the point: the flag is a
stack string, invisible to `strings` before or after unpacking, and FLOSS's stack-string
extraction is PE-only. Nothing but the decompile pass reaches it. So `0 high` means Ghidra
did not install, did not run, or installed as a 12.x build whose post-script fails while
`analyzeHeadless` still exits 0 — precisely the silent failure the 11.2.1 pin avoids.
Capture `ghidra.stderr` and `ls -d /opt/ghidra*`.

Then the guarantees the report is supposed to carry:

```bash
# sandbox actually engaged — the real docker flags, not revctf's own adjectives
grep -nE -- '--network=none|--read-only|--cap-drop' ~/rehearsal/scan-unpackme/report.txt

# captures 0600, created dirs 0700
find ~/rehearsal/scan-unpackme -type f -exec stat -c '%a' {} \; | sort -u
find ~/rehearsal/scan-unpackme -type d -exec stat -c '%a' {} \; | sort -u

# the original target is never modified
sha256sum ~/unpackme-upx
```

Spot-checks worth running once: `--dry-run`, `--skip-ghidra --summary-only`,
`--flag-format 'HTB\{[^}]+\}'` (ERE — never PCRE), and `--no-sandbox` (the host path must
be loudly reported).

**Gate D:** flags first in the report; sandbox engaged or safe-skipped with a reason;
permissions `0600`/`0700`; target hash unchanged.

Expect 2–5 minutes per target, dominated by Ghidra. A long unattended run can be killed by
session teardown — run these in your own terminal, not from an agent's background job.

---

## Phase E — the gates no headless run can close

```bash
./tools/tui-selftest.sh      # a HUMAN watches redraw / cursor / resize on a real terminal
./tools/verify-tier-c.sh     # needs a real 2048MB boot; refuses above 2560MB by design
./tools/measure-host.sh      # optional: the numbers M5 was designed around
```

`tui-selftest.sh` refuses a pipe, and five of its six checks are human judgements. Piping
`y` fabricates a pass, which is worse than leaving the gate open — a fabricated pass is
indistinguishable from a real one in the record.

**Gate E:** both watched by a person, on the hardware they claim.

---

## Predicted failures, and what each one means

Written down in advance so a predicted failure does not cost a second cycle.

| What you will see | Cause | Is it a defect? |
|---|---|---|
| `warning: docker is not installed` → `1 step(s) failed` → exit 1 | Kali does not ship Docker and install.sh does not install it | **Open product question** — see below |
| ltrace and strace `[skip]` naming Docker | Deviation D13 working correctly — revctf never falls back to running the target on the host | No. Designed behaviour |
| `optional package unavailable: jd-cli` (or procyon / mono-utils) | D7 tier two: format-conditional decompilers fail lazily | No. Warned, not counted as failed |
| Ghidra step slow | ~400MB download | Only if it fails — capture the error |
| `GHIDRA_HOME` unset in the current shell after install | Appended to `~/.bashrc`; new shells only. D12 falls back to `/opt/ghidra*` | No, but confirm the fallback found it |
| A check fails naming `upx`, `radare2` or a stripped binary | A §3 fact decayed on a newer tool version | Not an install defect — the version block tells them apart |
| `0 high` and no `picoCTF{...}` in Phase D | Ghidra absent, or a 12.x build whose post-script fails while `analyzeHeadless` exits 0 | **Yes, and the most important one** |
| `python3 -m venv` fails, *ensurepip is not available* | The gap fixed 2026-08-28 | **Yes — the fix did not work.** Report it |
| `DOCKER_HOST` points at a dead podman socket | The `podman-docker` package ships `/etc/profile.d/podman-docker.sh` and reinstates it every login | No. `lib/sandbox.sh` and `install.sh` already detect it and say "unset it" |

### The open question this forces

`install.sh` does not install Docker, but the sandbox is on by default and README calls
Docker required. So a clean `clone + install.sh` ends in exit 1 with two stages disabled.
Three ways to resolve it, and it is a product decision, not a bug fix:

1. **Install `docker.io` in `install.sh`** — the deployment path then produces a fully
   working revctf. Costs ~500MB and starts a daemon on the user's machine.
2. **Leave it, and stop counting it as a failure** — exit 0, print how to get Docker, and
   run with the two executing stages skipped. Matches `step_sandbox`'s own comment that a
   miss here "degrades revctf, it does not break it".
3. **Leave it exactly as is** — exit 1 is a loud, accurate report that the install is
   incomplete.

Decide against A-2's real output, not against predicted output.

---

## What happens with the result

**Clean** — the gate is recorded in `CHECKLIST.md` and `implementation-notes.md` with the
Kali version and the tool versions observed, since an install result is only true of the
environment it was observed in.

**Anything fails** — it is a **point release, not a re-tag**. The existing tag stays as an
accurate record of what was verified at the time, and its message already names its
outstanding gates, so nothing in it becomes false.
