#!/usr/bin/env bash
# lib/stage_strace.sh — Stage 9 (new): syscall trace complementing ltrace, plus ldd linkage listing
#
# Implemented in: M3
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

stage_strace() {
    printf 'revctf: %s not yet implemented (M3)\n' "stage_strace" >&2
    return 0
}
