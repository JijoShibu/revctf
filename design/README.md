# Design documents

These were previously kept beside the repo rather than inside it, which meant a fresh
clone did not have them — while `CLAUDE.md` §1 names `revctfmasterplan_v6.md` §11 as the
**highest authority** for resolving conflicts. A cold session was therefore instructed to
obey a document it could not read. They are version-controlled now so that cannot happen.

**Read `revctfmasterplan_v6.md` first — it consolidates all four.**

| File | Authority | What it is for |
|---|---|---|
| `revctfmasterplan_v6.md` | **1 (final)** | Consolidated spec. §11 is the Deviation Register — every departure from v3/v4/v5 and why |
| `revctf_executionmasterplan.md` | 2 | Milestone order, dependencies, Definition-of-Done gates |
| `revctfmasterplan_v5.md` | 2 | Behaviour, CLI surface, user agency, crash resilience |
| `revctfmasterplan_v4.md` | 3 (gaps only) | RAM tier table, resource isolation, watchdog, Ghidra OOM retry |
| `revctfmasterplanv3.md` | 4 (gaps only) | Memory derivations, base CLI semantics, per-stage invocations, sandbox hardening |

## These documents are historical, not current

v3–v5 describe things that are no longer true. The Deviation Register in v6 §11 is what
reconciles them, and `implementation-notes.md` records what was learned while building.
Two traps in particular:

- **v3 §1's "Ghidra 11.x+ → PyGhidra" is wrong.** The real boundary is 11.3. Probing a
  real 11.2.1 install reports Jython 2.7.3. See `CLAUDE.md` §3.
- **v4 §3 and v5 §3.1 specify auto-creating a swap file.** That feature was removed
  entirely — deviation **D10**. Do not re-add it; the harness fails the build if it
  reappears.

When a design document and the code disagree, the code plus `CLAUDE.md` plus the Deviation
Register win, and the disagreement gets recorded rather than silently resolved.
