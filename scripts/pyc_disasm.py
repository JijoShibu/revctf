#!/usr/bin/env python3
"""Disassemble a .pyc file to a readable bytecode listing.

Implemented in: M3.

This is the always-available fallback for lib/stage_pydecomp.sh. It exists because:

  * `python3 -m dis somefile.pyc` DOES NOT WORK. `dis` treats its argument as *source*,
    so a .pyc yields `SyntaxError: source code string cannot contain null bytes`. That
    failure is silent-ish in a pipeline and looks like "nothing to decompile".
  * The real decompilers are version-locked. uncompyle6 tops out around Python 3.8 and
    pycdc is not packaged anywhere, so on a modern interpreter neither may work.

A bytecode listing is not source, but for CTF purposes it is usually enough: string
constants appear verbatim in LOAD_CONST, which is where a flag normally lives.

The header preceding the marshalled code object grew over time, so its size is derived
from the running interpreter's magic number rather than hardcoded:
    <3.3   : 8 bytes  (magic + mtime)
    3.3-3.6: 12 bytes (magic + mtime + source size)
    3.7+   : 16 bytes (magic + flags + mtime + source size, PEP 552)
"""

import dis
import importlib.util
import marshal
import sys


def header_size() -> int:
    if sys.version_info >= (3, 7):
        return 16
    if sys.version_info >= (3, 3):
        return 12
    return 8


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: pyc_disasm.py <file.pyc>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        with open(path, "rb") as fh:
            head = fh.read(header_size())
            if len(head) < 4:
                print("not a .pyc file (too short)", file=sys.stderr)
                return 1

            expected = importlib.util.MAGIC_NUMBER
            if head[:4] != expected:
                # Not fatal: marshal often still loads a nearby version, and a partial
                # listing beats refusing outright. Say so, because a mismatch is exactly
                # the kind of thing that explains weird output further down.
                print("NOTE: this .pyc was built by a different Python version than the")
                print("      one running (%s). The listing below may be incomplete."
                      % ".".join(str(v) for v in sys.version_info[:3]))
                print("")

            code = marshal.load(fh)
    except Exception as exc:                                  # noqa: BLE001
        print("could not load bytecode: %s" % exc, file=sys.stderr)
        return 1

    try:
        dis.dis(code)
    except Exception as exc:                                  # noqa: BLE001
        print("could not disassemble: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
