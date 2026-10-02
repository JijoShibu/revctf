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
declare -g SBX_OWNER="" SBX_CLEANUP_FAILED=0 SBX_CLEANING=0
declare -gA SBX_OWNED=()

sbx_register() {
    if [[ -z $SBX_OWNER ]]; then
        read -r SBX_OWNER < /proc/sys/kernel/random/uuid || return 1
    fi
    SBX_NAME="revctf-$SBX_OWNER-$1"
    SBX_OWNED[$SBX_NAME]=reserved
    printf '%s\t%s\n' "$SBX_OWNER" "$SBX_NAME" >> "$RUN_OUTDIR/container-ownership.txt"
}

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
# Fills the named array with the `docker create` argv prefix. The caller appends the tracer
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
    # Docker -v otherwise creates a missing host path as a root-owned directory.
    [[ -d $scratch && -f $target ]] || return 1

    st_output_limit_valid || return 1
    _w=(docker create --name "$cname"
        --label "revctf.owner=$SBX_OWNER"
        --ulimit "fsize=$((ST_MAX_OUT_KB * 1024)):$((ST_MAX_OUT_KB * 1024))"
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
# leaves the traced target running indefinitely. Cleanup checks the unique ownership
# label and verifies absence; it never removes an unregistered name.
sbx_teardown() {
    local cname="$1"
    [[ -n $cname ]] || return 0
    [[ -n ${SBX_OWNED[$cname]:-} ]] || return 0
    sbx_cleanup_all
}

# One deadline covers all Docker calls, including an unresponsive daemon. Pending
# create requests are watched to the deadline, since killing the client does not
# cancel a request already accepted by dockerd.
sbx_cleanup_all() {
    [[ $SBX_CLEANUP_FAILED -eq 0 ]] || return 1
    [[ ${#SBX_OWNED[@]} -gt 0 ]] || return 0
    [[ $SBX_CLEANING -eq 0 ]] || return 1
    SBX_CLEANING=1
    local deadline=$((SECONDS + 10)) left ids id cname rc=0 pending=0
    for cname in "${!SBX_OWNED[@]}"; do
        [[ ${SBX_OWNED[$cname]} == pending ]] && pending=1
    done
    while [[ $SECONDS -lt $deadline ]]; do
        left=$((deadline - SECONDS))
        ids=$(timeout -s KILL "${left}s" docker ps -aq --filter "label=revctf.owner=$SBX_OWNER") || { rc=1; break; }
        if [[ -z $ids ]]; then
            if [[ $pending -eq 0 ]]; then SBX_OWNED=(); break; fi
            sleep 0.1
            continue
        fi
        for id in $ids; do
            left=$((deadline - SECONDS))
            [[ $left -gt 0 ]] || { rc=1; break; }
            timeout -s KILL "${left}s" docker rm -f "$id" >/dev/null 2>&1 || { rc=1; break; }
        done
        # This run issues only one creation at a time. Once its labelled container
        # has been observed and removed, the next empty listing confirms cleanup.
        pending=0
        [[ $rc -eq 0 ]] || break
    done
    # A pending creation cannot be confirmed cancelled merely from an absent container.
    [[ ${#SBX_OWNED[@]} -eq 0 ]] || rc=1
    if [[ $rc -ne 0 ]]; then
        SBX_CLEANUP_FAILED=1
        {
            printf 'The challenge may still be running. Docker cleanup could not be confirmed.\n'
            printf 'Owned label: revctf.owner=%s\n' "$SBX_OWNER"
            for cname in "${!SBX_OWNED[@]}"; do
                printf 'Container: %s\nRecovery after checking its ownership: docker rm -f %s\n' "$cname" "$cname"
            done
        } | tee -a "$RUN_OUTDIR/cleanup-warning.txt" >&2
    fi
    SBX_CLEANING=0
    return "$rc"
}
