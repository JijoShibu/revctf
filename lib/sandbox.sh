#!/usr/bin/env bash
# lib/sandbox.sh — Docker isolation for the two stages that EXECUTE the target.
#
# Implemented in: M6.
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`.
#
# ======================================================================================
# WHY THE CONTRACT LIVES HERE AND NOT IN THE IMAGE
# ======================================================================================
# docker/Dockerfile supplies TOOLS. This file supplies the ISOLATION, as `docker run`
# flags. A contract baked into an image is invisible at the call site, survives no rebuild
# and cannot be asserted against; a contract expressed as flags shows up in the process
# table, is recorded verbatim in the report by stage_record_exec, and is what the m6
# harness section greps for. If you move a flag from here into the Dockerfile you have
# deleted the only evidence that it was applied.
#
# Deviation D13 (v6 §11): --sandbox is ON by default. When Docker is unavailable the two
# executing stages SKIP; they never fall back to the host. A false sense of isolation is
# worse than a known absence of one, and a command that is a security boundary on one
# machine and not another — with the user believing they were isolated either way — is
# exactly that. --no-sandbox is the deliberate, stated override.

declare -g SBX_IMAGE="${REVCTF_SBX_IMAGE:-revctf-sandbox:1}"
# shellcheck disable=SC2034  # read by lib/stage_dynamic.sh and the entry script, separate files
declare -g SBX_WHY=""
declare -g SBX_OK=-1          # -1 = not yet probed, 0 = unavailable, 1 = available

# sbx_available — is the sandbox usable? Sets SBX_WHY when it is not.
#
# Probed once per run and cached: `docker info` costs ~100ms and both executing stages ask.
sbx_available() {
    [[ ${SBX_OK} -ge 0 ]] && return $(( 1 - SBX_OK ))

    SBX_OK=0
    if ! command -v docker >/dev/null 2>&1; then
        SBX_WHY="Docker is not installed"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        # A STALE DOCKER_HOST LOOKS EXACTLY LIKE A DEAD DAEMON, and cost real time on this
        # very host: DOCKER_HOST pointed at a podman socket that no longer existed, so every
        # docker call failed while `systemctl status docker` said active. Naming the variable
        # turns a ten-minute hunt into a one-line fix. revctf does NOT unset it — that is the
        # user's environment, and silently overriding it would hide the same problem again.
        if [[ -n ${DOCKER_HOST:-} ]]; then
            SBX_WHY="the Docker daemon is not reachable (DOCKER_HOST is set to '${DOCKER_HOST}' — if that socket is stale, unset it)"
        elif ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
            SBX_WHY="the Docker daemon is not reachable (this user is not in the 'docker' group — try: newgrp docker)"
        else
            SBX_WHY="the Docker daemon is not reachable"
        fi
        return 1
    fi
    if ! docker image inspect "$SBX_IMAGE" >/dev/null 2>&1; then
        # shellcheck disable=SC2034  # SBX_WHY is read by lib/stage_dynamic.sh, a separate file
        SBX_WHY="the sandbox image $SBX_IMAGE is not built (run install.sh, or: docker build -t $SBX_IMAGE docker/)"
        return 1
    fi

    SBX_OK=1
    return 0
}

# sbx_scratch <run-workdir> — make the writable scratch directory, print its path.
#
# --read-only makes the container filesystem immutable, which is the point; the tracer still
# has to write its `-o` trace somewhere, and that somewhere is this bind mount. It is mode
# 0777 because the container runs as `nobody`, whose uid does not exist on the host and
# cannot be chowned to meaningfully. It sits INSIDE RUN_WORKDIR, which is 0700, so nothing
# outside this run can reach it: the mount resolves on the host side and the container never
# needs to traverse the 0700 parent.
sbx_scratch() {
    local wd="$1" dir="$1/sbx"
    [[ -d $wd ]] || return 1
    mkdir -p -- "$dir" 2>/dev/null || return 1
    chmod 0777 -- "$dir" 2>/dev/null || return 1
    printf '%s' "$dir"
    return 0
}

# sbx_wrap <array-name> <scratch-dir> <target> <container-name> <mem-mb>
#
# Fills the named array with the `docker run` argv prefix. The caller appends the tracer
# command; the target is at /target (read-only) and the scratch dir is at /work.
#
# THE MEMORY CEILING MUST BE PASSED HERE, NOT LEFT TO systemd-run.
#
# st_run_bounded wraps what it launches in `systemd-run --scope -p MemoryMax`. Under the
# sandbox the process it launches is the docker CLIENT; the container is forked by dockerd
# and lives in a completely different cgroup, so the scope bounds a client that uses a few
# MB and bounds the traced target at nothing at all. That is the precise "reported but not
# enforced" shape M5 existed to eliminate — the same defect, one level further out. The
# tier's Phase-2 ceiling is therefore handed to `docker run --memory`, and --memory-swap is
# pinned to the same figure so the container cannot buy headroom back with swap.
sbx_wrap() {
    local -n _w="$1"
    local scratch="$2" target="$3" cname="$4" mem="$5"

    _w=(docker run --rm --name "$cname"
        --network=none
        --read-only
        --cap-drop=ALL
        --security-opt no-new-privileges
        --user nobody
        --pids-limit 128)

    # 0 means "this stage has no ceiling" (tier_ceiling_for_stage's documented sentinel),
    # not "bound it at zero".
    if is_uint "$mem" && [[ $mem -gt 0 ]]; then
        _w+=(--memory "${mem}m" --memory-swap "${mem}m")
    fi

    _w+=(-v "$scratch:/work"
         -v "$target:/target:ro"
         -w /work
         "$SBX_IMAGE")
    return 0
}

# sbx_teardown <container-name> — the sandboxed equivalent of the orphan sweep.
#
# dyn_sweep_orphans signals a PROCESS GROUP, and under the sandbox there is no process group
# to signal: ST_LAST_PGID belongs to the docker client, not to anything inside the container.
# Worse, killing the client does not stop the container — `timeout` firing on `docker run`
# leaves the traced target running indefinitely. So teardown is unconditional and by name.
# --rm covers the normal exit; this covers every other one.
sbx_teardown() {
    local cname="$1"
    [[ -n $cname ]] || return 0
    docker rm -f "$cname" >/dev/null 2>&1
    return 0
}
