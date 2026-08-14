#!/usr/bin/env bash
# lib/stage_ltrace.sh — Stage 7: setsid + timeout + orphan sweep on host, or Docker under --sandbox; ELF-gated
#
# Implemented in: M3
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

stage_ltrace() {
    printf 'revctf: %s not yet implemented (M3)\n' "stage_ltrace" >&2
    return 0
}
