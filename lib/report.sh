#!/usr/bin/env bash
# lib/report.sh — Beginner blurbs, raw output, found/failed markers, flag section, 700/600 permission hardening
#
# Implemented in: M4
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

report_build() {
    printf 'revctf: %s not yet implemented (M4)\n' "report_build" >&2
    return 0
}
