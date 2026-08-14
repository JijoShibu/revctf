#!/usr/bin/env bash
# lib/preflight.sh — Tool discovery, Ghidra/binwalk version detection, RAM tier resolution, systemd-run usability probe, disk-space and swap checks
#
# Implemented in: M1
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

preflight_run() {
    printf 'revctf: %s not yet implemented (M1)\n' "preflight_run" >&2
    return 0
}
