#!/usr/bin/env bash
# lib/tui.sh — Live stage table (TTY), heartbeat lines (redirected). Isolated behind tui_init/tui_stage_update/tui_prompt/tui_teardown so a defect degrades display only (v6 §10, D1)
#
# Implemented in: M4
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

tui_init() {
    printf 'revctf: %s not yet implemented (M4)\n' "tui_init" >&2
    return 0
}
