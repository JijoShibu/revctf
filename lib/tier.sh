#!/usr/bin/env bash
# lib/tier.sh — RAM-tier resolution (v6 §5) and --jobs-*/--maxmem-ghidra override handling
#
# Implemented in: M5
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

tier_resolve() {
    printf 'revctf: %s not yet implemented (M5)\n' "tier_resolve" >&2
    return 0
}
