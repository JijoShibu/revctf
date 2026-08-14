#!/usr/bin/env bash
# lib/stage_pydecomp.sh — Stage 12 (new): .pyc and PyInstaller extraction + decompile; entered only via triage routing
#
# Implemented in: M3
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

stage_pydecomp() {
    printf 'revctf: %s not yet implemented (M3)\n' "stage_pydecomp" >&2
    return 0
}
