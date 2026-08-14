#!/usr/bin/env bash
# lib/stage_objdump.sh — Stage 6 (new): objdump disassembly cross-check + readelf headers/symbols/relocations
#
# Implemented in: M2
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

stage_objdump() {
    printf 'revctf: %s not yet implemented (M2)\n' "stage_objdump" >&2
    return 0
}
