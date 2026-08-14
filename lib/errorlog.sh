#!/usr/bin/env bash
# lib/errorlog.sh — Structured diagnostic block + persistent ~/.revctf/error.log (600, 5MB rotation)
#
# Implemented in: M9
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

errorlog_record() {
    printf 'revctf: %s not yet implemented (M9)\n' "errorlog_record" >&2
    return 0
}
