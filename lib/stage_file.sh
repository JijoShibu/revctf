#!/usr/bin/env bash
# lib/stage_file.sh — Stage 1: classify ELF/PE/Mach-O/other; gates ltrace and strace
#
# Implemented in: M2
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

stage_file() {
    printf 'revctf: %s not yet implemented (M2)\n' "stage_file" >&2
    return 0
}
