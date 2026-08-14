#!/usr/bin/env bash
# lib/stage_strings.sh — Stage 2: printable strings.
#
# Implemented in: M2.  Per v5 §4.1 this file must not enable `set -e`.
#
# `strings -a -n 6` exactly as v3/M2 specifies. Streamed straight to disk via
# stage_capture — a 200MB firmware image would otherwise be buffered in a Bash variable,
# which v3 §1 explicitly forbids.
stage_strings() {
    stage_capture strings "$ST_T_STRINGS" -- strings -a -n 6 -- "$RUN_TARGET"
    return 0
}
