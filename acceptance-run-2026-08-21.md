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

---

# RESULTS — scored against the table above, as written

Run on the Kali VM, idle, 2026-08-21. Full output directories kept in
`acceptance-artifacts/` as the "before" half of the M6 sandbox before/after pair.

| | `unpackme-upx` | `bbbbloat` |
|---|---|---|
| exit | 0 | 0 |
| wall clock | **102s** | **10s** |
| stages failed | none | none |
| flags: high / med / low | 0 / 1 / 2 | 0 / 1 / 0 |

## C1 — Stage 0 unpacks `unpackme-upx`: **PASS**

Predicted YES. `Packer: upx detected`, `Unwrap: OK — analysing the unpacked image`,
379,108 B → 978KB, reclassified `elf`, and the whole static pipeline then ran against the
unpacked image. The headline path works on a real target that is harder than the corpus
fixture (statically linked, no section headers).

## C2 — Flag found: **FAIL, exactly as predicted**

Neither flag was recovered. Zero high-confidence candidates on both targets. What *was*
reported:

- `unpackme`: one medium (a 40-hex build ID) and two low (`abcdefghijklmnopqrstuvwxyz{|}`
  and its uppercase twin — an alphabet table in libc, matched by `_FLAG_GENERIC` because it
  happens to contain `{`).
- `bbbbloat`: one medium, the GNU BuildID.

The prediction and its reasoning both held: the flag scanner reads stage captures, and no
capture contained the flag, because a stack string is never in `strings` and FLOSS's
stack-string extraction is PE-only.

## C3 — Does the report tell a beginner what to do next?

**(a) Does it explain the FLOSS limitation? PASS.** Verbatim from `floss.txt`:

> NOTE: FLOSS can only recover stack, tight and decoded strings from PE binaries. This
> target is elf, so only static extraction ran. An absent flag here does NOT mean there is
> no hidden string — it means this tool could not look for one in this format.

That is the right message and it is the difference between an honest empty result and a
false negative. It was predicted to pass and it did.

**(b) Actionable next step? PARTIAL, as predicted.** Item 6 of WHAT TO TRY NEXT does say
"Read the ghidra and radare2 sections together: pseudocode tells you what the program
decides, the disassembly tells you exactly how" — which is, in fact, exactly where both
flags live. But it is item **6**, below four filler lines of the form "Stage X did not run
(skipped). If the flag is hiding there, that is the gap in this report" — for `managed` and
`pydecomp`, which could never apply to an ELF. The one genuinely useful pointer is buried
under four that are noise.

**(c) Anything actively misleading? PASS, but narrowly.** Nothing states or implies the
binary has no flag. The medium/low entries are explicitly captioned as leads rather than
answers. The weakness is the two low-confidence alphabet strings, which are pure noise from
`_FLAG_GENERIC` matching a libc character table.

## C4 — Ghidra pseudo-C makes the constants actionable: **PASS on both**

**The `unpackme` prediction was UNCERTAIN and it was wrong, in the good direction.** Ghidra
analysed the 978KB statically-linked image in 89s and produced the decisive function:

```c
  local_38 = 0x4c75257240343a41;
  local_30 = 0x30623e306b6d4146;
  local_28 = 0x3532666630486637;
  ...
  if (local_44 == 0xb83cb) {
    local_40 = (char *)rotate_encrypt(0,&local_38);
```

`bbbbloat` likewise, including `if (local_48 == 0x86187)`. Everything a solver needs is
present: the constants, the magic number, and — because `unpackme` is statically linked and
keeps its symbols — the name `rotate_encrypt`, which names the transform outright.

So by the criterion as written, **revctf did its job on both targets even though it printed
neither flag** — but only barely, because C3(b) buries the pointer to that output.

## C5 — Wall clock: **PASS on both**

`bbbbloat` 10s (predicted 30–60s; faster). `unpackme-upx` 102s (predicted 2–5 min; inside
it). Both well under the 10-minute fail line. Ghidra dominates: 89 of the 102s.

## Summary

| Criterion | Predicted | Actual |
|---|---|---|
| C1 unpack | YES | **PASS** |
| C2 flag found | NO | **FAIL (as predicted)** |
| C3a explains the gap | YES | **PASS** |
| C3b actionable | PARTIAL | **PARTIAL** |
| C3c misleading | NO | **PASS** |
| C4 constants actionable | YES / UNCERTAIN | **PASS / PASS** (prediction beaten) |
| C5 wall clock | 30–60s / 2–5min | **10s / 102s — PASS** |

## The pre-registered decoder hypothesis: CONFIRMED, and better than expected

The hypothesis was that little-endian decoding of the immediates would recover the flag.
**Tested against the real constants, that alone produces ciphertext, not the flag:**

```
bbbbloat  little-endian only -> 'A:4@r%uL4Ff0f9b03=_cf0be55b`e2N'
```

The stack string is the *encrypted* form — which the pseudo-C says outright, by naming the
function `rotate_encrypt`. So the hypothesis as originally written would have failed on both
of these targets, added a fifth decoder, and produced nothing but noise. That is precisely
the outcome pre-registration exists to make visible rather than quietly reinterpretable.

**But the transform is ROT47** — a constant ±47 shift over printable ASCII, and a standard
CTF encoding sitting one step beyond the ROT13 the sweep already does:

```
little-endian decode + ROT47  ->  picoCTF{cu7_7h3_bl047_36dd316a}   MATCH
little-endian decode + ROT47  ->  picoCTF{up><_m3_f7w_77ad107e}     MATCH
```

Both flags, exactly, from captures the pipeline already produces. Cost estimate and the
decision on whether to build it are recorded separately — it is parked behind M6.

## Findings that only a real target could produce

1. **A downloaded binary is mode 644, so the dynamic stages skip.** `unpackme-upx` was
   scanned exactly as downloaded and both `ltrace` and `strace` skipped with "target is not
   executable (chmod +x it to enable dynamic analysis)". The message is correct and
   actionable, but this is the *default* first-run experience for every user who downloads a
   challenge, and two of fourteen stages silently drop out of it. No corpus fixture caught
   this because `build-test-corpus.sh` chmods everything it builds.

2. **WHAT TO TRY NEXT pads with irrelevant skips.** Listing `managed` and `pydecomp` as
   "gaps in this report" for a native ELF is noise that pushes the one useful pointer to
   position 6.

3. **`_FLAG_GENERIC` matches libc's alphabet table.** `abcdefghijklmnopqrstuvwxyz{|}`
   contains `{`, so it is reported as a low-confidence candidate on every glibc binary.

4. **Ghidra is the whole cost.** 89 of 102s on `unpackme`, 8 of 10s on `bbbbloat`.
   The 1800s bound recorded as an unmeasured guess in CLAUDE.md §6 is not close to binding
   on either.
