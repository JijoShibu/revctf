#!/usr/bin/env bash
# lib/stage_triage.sh — Stage 0: detect and unwrap packers, archives, managed and Python artifacts. Never modifies the original target (v6 §4.1, D3)
#
# Implemented in: M2
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

stage_triage() {
    printf 'revctf: %s not yet implemented (M2)\n' "stage_triage" >&2
    return 0
}
