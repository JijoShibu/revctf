#!/usr/bin/env bash
# lib/stage_hexdump.sh — Stage 4: 512-byte capped preview, or full dump under --full-hexdump; streamed
#
# Implemented in: M2
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

stage_hexdump() {
    printf 'revctf: %s not yet implemented (M2)\n' "stage_hexdump" >&2
    return 0
}
