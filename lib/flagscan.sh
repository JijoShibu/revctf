#!/usr/bin/env bash
# lib/flagscan.sh — Tiered confidence regex + encoding sweep (base64/32/hex/ROT-n) + per-stage attribution (v6 §6, D5)
#
# Implemented in: M3
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; failures are reported through
# the stage error boundary and the pipeline continues.

# ======================================================================================
# HARD CONSTRAINT — read before implementing this file
# ======================================================================================
# Use `grep -E` (POSIX ERE) and nothing else. Never `grep -P`, never a PCRE engine, never
# a Bash `=~` match against a user-supplied pattern.
#
# `--flag-format` takes a regex FROM THE USER, and the flag scan runs it across every
# stage capture — which for a large target is multiple megabytes of `strings` output. A
# backtracking engine turns a pattern like `(a+)+$` into a self-inflicted denial of
# service. GNU grep -E is DFA-based and has no catastrophic-backtracking failure mode, so
# choosing the right engine removes the whole class of problem rather than trying to
# validate patterns for safety, which is not reliably possible.
#
# The entry script already validates that `--flag-format` is a syntactically valid ERE. It
# deliberately does NOT try to judge whether a pattern is "safe" — that is the engine's job.
#
# tools/run-tests.sh asserts that no PCRE flag appears anywhere in lib/.

flagscan_run() {
    printf 'revctf: %s not yet implemented (M3)\n' "flagscan_run" >&2
    return 0
}
