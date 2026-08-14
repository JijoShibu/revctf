#!/usr/bin/env bash
# lib/watchdog.sh — Global RSS monitor; kills the job tree at 90% of detected RAM. Never prompts (v5 §3.1)
#
# Implemented in: M5
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

watchdog_start() {
    printf 'revctf: %s not yet implemented (M5)\n' "watchdog_start" >&2
    return 0
}
