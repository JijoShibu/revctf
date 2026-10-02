#!/usr/bin/env bash
# Startup check uses real total RAM, independently of tier simulation hooks.
declare -g RAM_MEASURED=0 RAM_TOTAL_MIB=0 RAM_GATE_NOTE="" RAM_GATE_BLOCKED=0

ram_measure() {
    [[ $RAM_MEASURED -eq 1 ]] && return 0
    RAM_MEASURED=1
    local value
    value=$(awk '/^MemTotal:/ { printf "%d", $2/1024; exit }' /proc/meminfo 2>/dev/null)
    if ! [[ $value =~ ^[1-9][0-9]{0,8}$ ]]; then
        value=$(free -m 2>/dev/null | awk '/^Mem:/ { print $2; exit }')
    fi
    if [[ $value =~ ^[1-9][0-9]{0,8}$ ]]; then RAM_TOTAL_MIB=$value; fi
    return 0
}

ram_gate() {
    ram_measure
    RAM_GATE_NOTE=""
    RAM_GATE_BLOCKED=0
    [[ $RAM_TOTAL_MIB -ge 3891 ]] && return 0
    local amount="could not be measured"
    [[ $RAM_TOTAL_MIB -gt 0 ]] && amount="${RAM_TOTAL_MIB} MiB (below the approximate 4 GB minimum)"
    RAM_GATE_NOTE="Linux total RAM: $amount. Allocate at least 4 GB (4096 MB) to Kali. Shut down Kali, increase its memory in your virtual machine settings, then restart it."
    if [[ ${OPT[allow_low_memory]:-0} -eq 1 ]]; then
        RAM_GATE_NOTE="LOW MEMORY OVERRIDE: $RAM_GATE_NOTE A slower or incomplete scan is possible; existing resource limits remain active."
        printf 'revctf: WARNING: %s\n' "$RAM_GATE_NOTE" >&2
        return 0
    fi
    # shellcheck disable=SC2034  # used by the entry script's dry-run summary
    RAM_GATE_BLOCKED=1
    printf 'revctf: scan blocked: %s\nTo accept a potentially slower or incomplete scan, pass --allow-low-memory explicitly.\n' "$RAM_GATE_NOTE" >&2
    return 1
}
