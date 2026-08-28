# CLAUDE.md

The standing context for this repo lives with the other maintainer documents:

@docs/CLAUDE.md

This file exists only so that import happens. Claude Code loads `CLAUDE.md` from the
project root and nowhere else, so moving the content to `docs/` without leaving this
pointer would silently drop every convention in it — including "never add `set -e`" and
the flag-scanner's `grep -E`-only rule. Edit `docs/CLAUDE.md`, not this file.
