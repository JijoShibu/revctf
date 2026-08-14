#!/usr/bin/env bash
# lib/prompt.sh — TTY detection, prompt rendering, per-run answer memoization
#
# Implemented in: M8
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

prompt_confirm() {
    printf 'revctf: %s not yet implemented (M8)\n' "prompt_confirm" >&2
    return 0
}
