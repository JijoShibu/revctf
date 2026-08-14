#!/usr/bin/env bash
# lib/spinner.sh — Line-mode spinner + heartbeat; the always-available fallback beneath tui.sh
#
# Implemented in: M9
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

spinner_start() {
    printf 'revctf: %s not yet implemented (M9)\n' "spinner_start" >&2
    return 0
}
