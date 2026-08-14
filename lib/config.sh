#!/usr/bin/env bash
# lib/config.sh — Config-file load + allowlist validation (currently inlined in the entry script; extracted here once M4 needs it from subshells)
#
# Implemented in: M4
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

config_load() {
    printf 'revctf: %s not yet implemented (M4)\n' "config_load" >&2
    return 0
}
