# pyghidra_decompile.py — Ghidra headless post-script, PyGhidra runtime.
# -*- coding: utf-8 -*-
#
# The encoding declaration above is REQUIRED, not decorative: Jython 2.7 is a Python 2
# interpreter and refuses any source file containing a non-ASCII byte without it —
# `SyntaxError: Non-ASCII character ... but no encoding declared`. The em-dashes in
# these comments are enough to trigger it, and the failure surfaces only as an empty
# Ghidra stage, because analyzeHeadless still exits 0.
#
# Implemented in: M3.
# Used on Ghidra 11.3 and later, where PyGhidra is bundled and Jython has been removed.
# Selected by lib/preflight.sh, which probes Ghidra/Features/{PyGhidra,Jython} rather than
# trusting the version number: 11.2.1 reports python_version=2.7.3, so the widely-repeated
# "11.x means PyGhidra" rule is wrong and the real boundary is 11.3.
#
# This runs under CPython 3, so f-strings are available — but the logic is deliberately

#
# Everything between the BEGIN and END markers is what revctf puts in the report; Ghidra's
# own INFO chatter on stdout is filtered out around them.
#
# argv[1] is "1" for a light pass (function inventory only, used for the OOM retry) and
# "0" for a full decompile.

import sys

from ghidra.app.decompiler import DecompInterface       # noqa: F821
from ghidra.util.task import ConsoleTaskMonitor         # noqa: F821

MAX_FUNCS = 200
MAX_LINES_PER_FUNC = 400

# Ghidra injects these into the script's namespace.
program = currentProgram                                # noqa: F821

light = False
try:
    args = getScriptArgs()                              # noqa: F821
    if len(args) > 0 and str(args[0]) == "1":
        light = True
except Exception:
    pass


def emit(text):
    print(text)


emit("=== REVCTF-GHIDRA-BEGIN ===")
try:
    fm = program.getFunctionManager()
    total = fm.getFunctionCount()

    emit("Program        : %s" % program.getName())
    emit("Language       : %s" % program.getLanguageID())
    emit("Compiler spec  : %s" % program.getCompilerSpec().getCompilerSpecID())
    emit("Image base     : %s" % program.getImageBase())
    emit("Functions found: %d" % total)
    emit("Mode           : %s" % ("light (inventory only)" if light else "full decompile"))
    emit("")

    funcs = []
    it = fm.getFunctions(True)
    while it.hasNext():
        funcs.append(it.next())

    emit("=== Function inventory ===")
    for f in funcs[:MAX_FUNCS]:
        emit("  %-40s %s  (%d bytes)" % (
            f.getName(), f.getEntryPoint(), f.getBody().getNumAddresses()))
    if len(funcs) > MAX_FUNCS:
        emit("  ... and %d more" % (len(funcs) - MAX_FUNCS))
    emit("")

    if not light:
        # Decompile the functions a CTF player actually reads first: main and anything
        # whose name suggests it guards the flag. Then everything else, budget permitting.
        interesting = []
        rest = []
        for f in funcs:
            n = f.getName().lower()
            if n == "main" or "flag" in n or "check" in n or "verify" in n or "decrypt" in n:
                interesting.append(f)
            elif not n.startswith(("_", "frame_dummy", "register_tm", "deregister")):
                rest.append(f)
        ordered = interesting + rest

        decomp = DecompInterface()
        decomp.openProgram(program)
        monitor = ConsoleTaskMonitor()

        emit("=== Decompiled pseudo-C ===")
        if interesting:
            emit("(functions likely to hold the challenge logic are shown first)")
            emit("")

        shown = 0
        for f in ordered:
            if shown >= MAX_FUNCS:
                emit("... decompilation capped at %d functions" % MAX_FUNCS)
                break
            try:
                res = decomp.decompileFunction(f, 60, monitor)
                if res is None or not res.decompileCompleted():
                    emit("/* %s: decompilation failed */" % f.getName())
                    continue
                code = res.getDecompiledFunction().getC()
                lines = code.split("\n")
                if len(lines) > MAX_LINES_PER_FUNC:
                    lines = lines[:MAX_LINES_PER_FUNC] + ["/* ... truncated ... */"]
                emit("/* ---- %s @ %s ---- */" % (f.getName(), f.getEntryPoint()))
                emit("\n".join(lines))
                emit("")
                shown += 1
            except Exception:
                emit("/* %s: %s */" % (f.getName(), sys.exc_info()[1]))
        decomp.dispose()

except Exception:
    emit("REVCTF-ERROR: %s" % sys.exc_info()[1])

emit("=== REVCTF-GHIDRA-END ===")
