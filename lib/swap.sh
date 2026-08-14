#!/usr/bin/env bash
# lib/swap.sh — Auto-create a 1-2GB swap file on a low tier with no active swap; prompt-gated (v5 §3.1)
#
# Implemented in: M5
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

swap_ensure() {
    printf 'revctf: %s not yet implemented (M5)\n' "swap_ensure" >&2
    return 0
}
