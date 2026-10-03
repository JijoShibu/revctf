#!/usr/bin/env python3
"""Real Docker lifecycle tests, using only an owned, generated sleeping program.

Requires installed revctf dependencies and the current preview sandbox. No network access.
All retained evidence is under a fresh temporary directory printed at startup.
"""
import os
from pathlib import Path
import signal
import subprocess as sp
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix="revctf-lifecycle."))
print(f"Evidence: {WORK}", flush=True)
env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}",
           DBUS_SESSION_BUS_ADDRESS=f"unix:path=/run/user/{os.getuid()}/bus")
env.pop("REVCTF_RAM_MB", None)
env.pop("REVCTF_CEIL_MB", None)
source = WORK / "wait.c"
source.write_text('#include <unistd.h>\nint main(void){for(;;) sleep(1);}\n')
sp.run(["gcc", "-o", str(WORK / "wait"), str(source)], check=True)
config = WORK / "config"
config.write_text("stages_disabled = strings,binwalk,hexdump,checksec,objdump,radare2,strace,floss,managed,pydecomp,ghidra\n")
passed = failed = 0
owned_names = set()
processes = []

def restore_stop_signals():
    # nohup/background test launchers can ignore both INT and HUP. Restore the
    # normal foreground dispositions before exec; Bash cannot undo ignored signals.
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGHUP, signal.SIG_DFL)

def docker(*args):
    return sp.run(["docker", *args], capture_output=True, text=True, timeout=15)

def start(label, extra=(), custom_env=None, exit_probe=False):
    out = WORK / label
    log = (WORK / f"{label}.console").open("w")
    cmd = [str(ROOT / "revctf"), "scan", str(WORK / "wait"), "--config", str(config),
           "--skip-ghidra", "--skip-strace", "--no-tui", "--timeout", "60", "--output", str(out), *extra]
    if exit_probe:
        # An extra shell trap exits during a live scan, exercising revctf's EXIT
        # handler without editing the application under test.
        cmd = ['bash', '-c', 'trap "exit 17" USR1; source "$@"', 'exit-probe', *cmd]
    # Launch directly from Python so SIGINT is not inherited as ignored from a
    # non-interactive shell's background job.
    p = sp.Popen(cmd, stdout=log, stderr=sp.STDOUT, env=custom_env or env, start_new_session=True,
                 preexec_fn=restore_stop_signals)
    log.close()
    processes.append(p)
    deadline = time.monotonic() + 75
    name = None
    while time.monotonic() < deadline:
        record = out / "container-ownership.txt"
        if record.exists():
            lines = record.read_text().splitlines()
            if lines:
                name = lines[-1].split("\t")[1]
                owned_names.add(name)
                state = docker("inspect", "--format", "{{.State.Running}}", name)
                if state.returncode == 0 and state.stdout.strip() == "true":
                    return p, out, name
        if p.poll() is not None:
            raise AssertionError(f"{label}: scan exited early ({p.returncode}); see console")
        time.sleep(.1)
    raise AssertionError(f"{label}: no running positive control")

def absent(name):
    r = docker("ps", "-aq", "--filter", f"name=^/{name}$")
    return r.returncode == 0 and not r.stdout.strip()

def interrupted(sig):
    p, out, name = start(f"signal-{sig}")
    before = time.monotonic()
    os.kill(p.pid, sig)
    rc = p.wait(timeout=18)
    assert rc == 128 + sig, (rc, sig)
    assert time.monotonic() - before < 15
    assert absent(name), name
    assert not (out / ".revctf-lock").exists()
    assert "INCOMPLETE" in (out / "report.txt").read_text()
    assert (out / "ltrace.interrupted-trace.txt").exists()

def timeout_case():
    p, out, name = start("timeout", ["--timeout", "3"])
    assert p.wait(timeout=30) == 2
    assert absent(name)
    report = (out / "report.txt").read_text()
    assert "partial" in report and "timed out" in report

def concurrent():
    a, oa, na = start("concurrent-a")
    b, ob, nb = start("concurrent-b")
    os.kill(a.pid, signal.SIGTERM)
    assert a.wait(timeout=18) == 143 and absent(na)
    assert docker("inspect", "--format", "{{.State.Running}}", nb).stdout.strip() == "true"
    os.kill(b.pid, signal.SIGTERM)
    assert b.wait(timeout=18) == 143 and absent(nb)

def unexpected_exit():
    p, out, name = start('unexpected-exit', exit_probe=True)
    os.kill(p.pid, signal.SIGUSR1)
    assert p.wait(timeout=18) == 17 and absent(name)
    assert 'unexpected exit 17' in (out/'report.txt').read_text()
    assert not (out/'.revctf-lock').exists()

def startup_interrupt():
    wrapper = WORK / "delayed-docker"
    wrapper.mkdir()
    script = wrapper / "docker"
    script.write_text('#!/bin/bash\nif [[ $1 == create ]]; then\n /usr/bin/docker "$@"\n rc=$?\n sleep 30\n exit "$rc"\nfi\nexec /usr/bin/docker "$@"\n')
    script.chmod(0o755)
    custom = dict(env, PATH=str(wrapper) + ":" + env["PATH"])
    out = WORK / "during-create"
    with (WORK / "during-create.console").open("w") as log:
        p = sp.Popen([str(ROOT / "revctf"), "scan", str(WORK / "wait"), "--config", str(config),
                      "--skip-ghidra", "--no-tui", "--output", str(out)],
                     env=custom, stdout=log, stderr=sp.STDOUT, start_new_session=True)
    processes.append(p)
    deadline = time.monotonic() + 75
    name = None
    while time.monotonic() < deadline:
        record = out / "container-ownership.txt"
        if record.exists() and record.read_text().strip():
            name = record.read_text().splitlines()[-1].split("\t")[1]
            owned_names.add(name)
            if docker("inspect", name).returncode == 0:
                break
        assert p.poll() is None
        time.sleep(.1)
    assert name and docker("inspect", name).returncode == 0, "no created positive control"
    os.kill(p.pid, signal.SIGTERM)
    assert p.wait(timeout=18) == 143 and absent(name)

def container_file_limit():
    # Invoke the application's own container argument builder, not a retyped limit.
    script = r'''
set -uo pipefail
source "$ROOT/lib/stage.sh"
source "$ROOT/lib/sandbox.sh"
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
RUN_OUTDIR="$EVIDENCE"
ST_MAX_OUT_KB=16
mkdir "$EVIDENCE/scratch"
chmod 777 "$EVIDENCE/scratch"
sbx_register fsize || exit 1
trap 'sbx_cleanup_all' EXIT
declare -a args=()
sbx_wrap args "$EVIDENCE/scratch" /bin/true "$SBX_NAME" 128 || exit 1
timeout 10 "${args[@]}" bash -c 'head -c 32768 /dev/zero > /work/big' > "$EVIDENCE/container-id" || exit 1
SBX_OWNED[$SBX_NAME]=created
rc=0
timeout 10 docker start --attach "$SBX_NAME" > "$EVIDENCE/start.out" 2> "$EVIDENCE/start.err" || rc=$?
[[ $(stat -c %s "$EVIDENCE/scratch/big") -eq 16384 && $rc -ne 0 ]]
'''
    out = WORK / 'file-limit'
    out.mkdir()
    run = sp.run(['bash', '-c', script], env=dict(env, ROOT=str(ROOT), EVIDENCE=str(out)),
                 capture_output=True, text=True, timeout=35)
    (out/'test.log').write_text(run.stdout + run.stderr)
    assert run.returncode == 0, run.stderr
    names = (out/'container-ownership.txt').read_text().splitlines()
    assert all(absent(line.split('\t')[1]) for line in names)

def container_memory_limit():
    out = WORK / 'memory-limit'
    out.mkdir()
    code = out / 'allocate.c'
    code.write_text('''#include <stdio.h>
#include <stdlib.h>
int main(void) {
    FILE *f = fopen("/sys/fs/cgroup/memory.max", "r");
    char limit[64];
    if (!f || !fgets(limit, sizeof limit, f)) return 3;
    fclose(f); printf("%s", limit); fflush(stdout);
    volatile unsigned char *p = malloc(256UL*1024*1024);
    if (!p) return 4;
    for (size_t i=0; i<256UL*1024*1024; i+=4096) p[i]=1;
    return 0;
}
''')
    sp.run(['gcc', '-o', str(out/'allocate'), str(code)], check=True)
    # The sandbox runs as nobody; a restrictive developer umask must not block the probe.
    (out/'allocate').chmod(0o755)
    script = r'''
set -uo pipefail
source "$ROOT/lib/stage.sh"
source "$ROOT/lib/sandbox.sh"
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
RUN_OUTDIR="$EVIDENCE"
mkdir "$EVIDENCE/scratch"
chmod 777 "$EVIDENCE/scratch"
sbx_register memory || exit 1
trap 'sbx_cleanup_all' EXIT
declare -a args=()
sbx_wrap args "$EVIDENCE/scratch" "$EVIDENCE/allocate" "$SBX_NAME" 64 || exit 1
timeout 10 "${args[@]}" /target > "$EVIDENCE/container-id" || exit 1
SBX_OWNED[$SBX_NAME]=created
rc=0
timeout 15 docker start --attach "$SBX_NAME" > "$EVIDENCE/measured-limit.txt" 2> "$EVIDENCE/start.err" || rc=$?
docker inspect --format '{{.State.OOMKilled}}' "$SBX_NAME" > "$EVIDENCE/oom.txt"
[[ $rc -eq 137 ]] && grep -qx 67108864 "$EVIDENCE/measured-limit.txt" && grep -qx true "$EVIDENCE/oom.txt"
'''
    run = sp.run(['bash', '-c', script], env=dict(env, ROOT=str(ROOT), EVIDENCE=str(out)),
                 capture_output=True, text=True, timeout=40)
    (out/'test.log').write_text(run.stdout + run.stderr)
    assert run.returncode == 0, run.stderr + (out/'start.err').read_text()
    names = (out/'container-ownership.txt').read_text().splitlines()
    assert all(absent(line.split('\t')[1]) for line in names)


def check(label, fn):
    global passed, failed
    try:
        fn()
        passed += 1
        print("PASS", label, flush=True)
    except Exception as exc:
        failed += 1
        print("FAIL", label, repr(exc), flush=True)

try:
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        check(f"signal {sig}: exact owned container removed, evidence preserved", lambda sig=sig: interrupted(sig))
    check("timeout preserves partial trace and removes container", timeout_case)
    check("simultaneous scans cannot remove each other's containers", concurrent)
    check("unexpected shell exit cleans its live container and preserves evidence", unexpected_exit)
    check("interruption during container creation removes the created container", startup_interrupt)
    check("Docker enforces the exact 16 KiB file limit", container_file_limit)
    check("Docker's measured 64 MiB limit kills an excessive allocation", container_memory_limit)
finally:
    for p in processes:
        if p.poll() is None:
            os.kill(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=18)
            except sp.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
    for name in owned_names:
        if not absent(name):
            docker("rm", "-f", name)
print(f"{passed} passed; {failed} failed", flush=True)
raise SystemExit(1 if failed else 0)
