# Implementation Notes

Per execution masterplan §4: deviations from design, open questions, and conservative
choices made when a small unknown surfaced mid-build. This is the memory a solo, unpaced
project otherwise loses between sessions.

Build reference is `revctfmasterplan_v6.md`. Deviations from v3/v4/v5 that were *decided*
rather than discovered live in v6 §11 (the Deviation Register) — this file records what
came up **while building**.

---

## M0 — Foundation & Scaffolding

**Status:** complete.

### Decisions made during M0

- **Config loading is inlined in the entry script for now.** v6 §12 lists `lib/config.sh`,
  but at M0 nothing else needs it and sourcing a library before argument parsing complicates
  the precedence chain. `lib/config.sh` exists as a stub; the loader moves there in M4, when
  batch subshells need it independently. Recorded here so the layout mismatch isn't mistaken
  for an oversight.

- **`set -uo pipefail`, never `set -e`.** v5 §4.1 requires stage-level isolate-and-continue.
  A top-level `set -e` would make a single non-zero exit abort the run, which is precisely
  the behavior the design forbids. Every `lib/` file carries a comment stating this so it
  doesn't get "helpfully" added later.

- **Symlink-resolving root detection.** `install.sh` symlinks `revctf` onto `PATH`, so
  `dirname "$0"` would resolve to `/usr/local/bin` and `lib/` would not be found. The entry
  script walks the symlink chain manually rather than depending on GNU `readlink -f`, so the
  script stays portable if it is ever run somewhere without coreutils' GNU variant.

- **Full flag surface implemented at M0, not incrementally.** The execution masterplan asks
  only for an "argument-parsing skeleton". Implementing all 24 flags now costs little and
  means later milestones only wire behavior to an already-validated flag, rather than
  re-touching the parser every milestone. Validation of conflicting flag combinations
  (v5 §3.3/§3.4) is in place from the start.

- **TUI auto-disables when stdout is not a TTY**, silently rather than with a warning.
  Emitting escape sequences into a pipe would corrupt redirected output, and warning about
  it on every piped run would be noise. `--no-tui` remains available to force line mode on
  a terminal.

- **`--flag-format` is validated as an ERE at parse time.** An invalid pattern would
  otherwise surface as a confusing `grep` failure deep inside the flag scan, on every stage.

### Open questions carried forward

- **Ghidra time bound (1800s, v6 §7.4) is unvalidated.** No prior masterplan bounded Ghidra
  by time at all. 1800s is a guess sized to be well clear of a normal run; needs measuring
  against the "Ghidra slow-path binary" in the v3 §5 test corpus before it can be trusted.

- **FLOSS memory behavior is assumed, not measured.** Phase 2 inherits the tier's Ghidra
  ceiling (v6 §5) on the argument that it matches an already-derived and tested profile.
  That reasoning is sound for concurrency but FLOSS's actual peak RSS on a large binary
  should be measured in M3 rather than assumed to fit.

- **Triage/unwrap on polyglot files.** A file that is both packed and an archive will route
  down one path only. Depth cap of 2 bounds the damage and the report states what unwrap
  did, but a genuine polyglot CTF challenge could still be mis-analyzed. Revisit if it
  shows up in practice.
