# Real-world acceptance run — picoCTF 2022, 2026-08-21

The 18-file corpus is synthetic and self-referential: it was written to exercise paths we
already believed in, so it can only confirm them. This is revctf's first contact with a
challenge nobody here wrote.

**The success criteria and the predictions below were written and committed BEFORE the run.**
That is the point of the exercise. Results are appended afterwards and scored against these
exactly as written — not reinterpreted to fit whatever happened.

## Targets

Genuine picoCTF 2022 Reverse Engineering challenges, fetched from a public mirror
(`HHousen/PicoCTF-2022`).

| File | Size | What it is | Known flag |
|---|---|---|---|
| `unpackme-upx` | 379,108 B | statically-linked UPX-packed ELF, **no section headers** | `picoCTF{up><_m3_f7w_77ad107e}` |
| `bbbbloat` | 14,472 B | stripped PIE ELF, dynamically linked | `picoCTF{cu7_7h3_bl047_36dd316a}` |

sha256:
```
253e9977f0ec8e9e5ec6f762bf5d3307bf21d1807e366ea3b57261a13fa246a6  unpackme-upx
6676a9c9e4eb5870c7312e21c403f5ea7b34c9ed510d161e049d26fcde3f705d  bbbbloat
```

**Both flags are stack strings** — assembled at runtime from `movabs` immediates and then
transformed by a helper function. Neither appears in `strings`, before or after unpacking.
This was checked before choosing them: a target whose flag `strings` finds would have tested
nothing revctf's own corpus does not already test.

## Criteria, and the prediction for each

### C1 — Does Stage 0 unpack `unpackme-upx`?
This is revctf's headline path, against a harder input than the corpus fixture: statically
linked, and with no section headers.

**Prediction: YES.** upx 4.2.4 is installed and CLAUDE.md §3 records that the 4.2.2 PIE
unpack defect is fixed. Nothing about a static, section-header-less ELF should defeat it.

### C2 — Is the flag found?
**Prediction: NO, for both.** Stated plainly and in advance so there is no room to claim a
partial win afterwards. The reasoning: the flag scanner reads stage captures, and no capture
will contain the flag. `strings` cannot see a stack string. FLOSS is the tool that exists to
recover stack strings, and CLAUDE.md §3 records that its stack/tight/decoded modes are
**PE-only** — on ELF it runs `--only static`. So the one tool in the pipeline capable of this
class of challenge is structurally unable to run on this class of file.

If a flag *is* found, that is a genuine surprise and will be recorded as one.

### C3 — If not found, does the report tell a beginner what to do next?
**This is the real test, and the one that decides whether the tool is honest.**

"No flag candidates" with a missing or misleading explanation is a **worse** outcome than a
crash: a crash tells the user something went wrong, whereas a clean-looking empty result
tells them the binary has no flag in it. That is a false negative presented as a fact.

Scored on three specific things:
- **(a)** Does the report say FLOSS did not attempt stack-string extraction, and that this is
  because the file is ELF rather than because nothing was found?
- **(b)** Does it point at a next step a beginner could actually take?
- **(c)** Is there anything actively misleading — a phrasing that reads as "there is no flag
  here"?

**Prediction: (a) YES** — `stage_floss.sh` is format-aware and the harness pins the wording
"does NOT mean there is no hidden string". **(b) PARTIAL** — I expect generic next-steps, not
"this looks like a stack string; read the decompilation". **(c) NO**, but held loosely; this
is exactly the kind of thing that reads worse in a real report than it does in a unit check.

### C4 — Does Ghidra's pseudo-C make the `movabs` constants visible and actionable?
If yes, revctf has done its job even without printing the flag — **but only if the report
points the reader there.** A correct answer buried in `ghidra.txt` that the report never
mentions is not a success.

**Prediction: YES for `bbbbloat`** (it is small, and this is the documented solution path).
**UNCERTAIN for `unpackme-upx`** — ~700KB of statically-linked code with no section headers
is an unusually hostile input for headless analysis, and the 1800s Ghidra bound is still the
unmeasured guess recorded in CLAUDE.md §6.

### C5 — Wall-clock time. Would someone actually wait?
**Prediction: `bbbbloat` 30–60s. `unpackme-upx` 2–5 minutes**, dominated by Ghidra over a
static binary. Anything past ~10 minutes fails this criterion regardless of what it found.

## Scoring rule

Each criterion is PASS, PARTIAL or FAIL against the text above as written. A criterion is not
rewritten after the fact. Where a prediction was wrong, the prediction is marked wrong and
left in place.

## A candidate fix, registered before the run (do NOT build until scored)

If C2 fails and C4 passes — the flag is not recovered, but the constants that encode it *are*
visible in the captures — then the gap may be far cheaper to close than "FLOSS cannot do stack
strings on ELF" suggests.

Stack strings surface in disassembly and pseudo-C as 8-byte immediates:

```
mov qword [rbp-0x20], 0x4654435f6f636970
```

Those bytes are little-endian ASCII (`picoCTF_` in that example). The flag scanner already
reads every stage capture, and `_fs_sweep_encodings` already decodes base64, base32, hex and
ROT13. A pass that pulls hex immediates of 4+ bytes out of the radare2 and Ghidra captures,
converts them little-endian to ASCII, joins adjacent ones and re-runs the existing flag regex
would cover this whole challenge class — using output the pipeline already produces, with no
new tool and no new dependency.

**This is registered as a hypothesis, not a plan.** It is written down now so that the cost
estimate made afterwards cannot be quietly shaped by the result. It gets built only if:

1. C4 confirms the constants are actually present in the captures, **and**
2. the implementation is genuinely small — on the order of 20 lines inside the existing sweep.

If it turns out to need a disassembly parser, per-tool output handling, or special cases per
architecture, it fails the standing rule (a fix must not cost more than the defect it
prevents) and is recorded as rejected with the reason.
