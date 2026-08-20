#!/usr/bin/env python3
"""Destination-phase assertion (PORTING.md §5.5, §7.25).

A CRC gate PASS can be two consoles identically stuck in the same wrong
place.  Sea Battle has (at least) three known traps, from recon-level
disassembly (spikes/NOTES.md M0/M2) -- NOT yet all confirmed on screen:

  1. Parked at $0164 = 0 or 8 -- the boot/idle phase, or the EXEC-default-
     table install ($52E3).  Nothing has been proven to make the game
     leave this state yet in this session's probing; a placeholder
     SCRIPT_TBL (idle-only) currently cannot drive past $0164 = 1.
  2. Parked at $0164 = 1 -- the ordinary per-tick bookkeeping phase
     (L_539B called for both seats every tick).  This is where the
     current placeholder script settles; it must NOT be mistaken for
     live play.
  3. Any of the three one-instruction self-loops at $5E90/$5EA7/$5EAE
     (bare `DECR R7`) -- every dump is stable and identical, exactly
     Soccer's $5122 trap.

** OPEN ITEM (see spikes/NOTES.md): ** $0164 = 5 (the phase whose body
calls the movement/action poll pair, the strongest live-play candidate) has
NOT yet been reached in this session -- the phase-4/6/7 transition chain's
trigger (a specific input? a pure countdown?) is unconfirmed.  This checker
currently asserts $0164 is at least past the boot phase (> 1) as the
weakest honest signal available, NOT that phase 5 was reached.  Tighten
this to `phase == 5` once that is confirmed on screen -- do not read a
"PASS" from this tool as proof that real gameplay ran until then.

Usage: check_dest_phase.py build/det_a.out [...]
"""
import re
import sys

DUMP_RE = re.compile(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#", re.M)
PC_RE = re.compile(r"^\s*(?:[0-9A-F]{4}\s+){7}([0-9A-F]{4})\s+\S+\s+\S", re.M)

PARK_PCS = (0x5E90, 0x5EA7, 0x5EAE)   # the three bare-DECR-R7 self-loops
LIVE_PHASE = 5                        # strongest candidate, UNCONFIRMED


def check(path):
    text = open(path).read()
    mem = {}
    for m in DUMP_RE.finditer(text):
        addr = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[addr + i] = int(w.rstrip("*"), 16)

    fail = []
    if not mem:
        return [f"{path}: no memory dumps found"]

    phase = mem.get(0x164)
    if phase is None:
        fail.append("no $0164 dump found (the run script must dump $0160-$016F)")
    elif phase <= 1:
        fail.append(f"parked at phase ${phase:02X} (boot/idle or first-tick "
                    f"bookkeeping) -- no evidence of live play; SCRIPT_TBL "
                    f"likely never drove a real transition (see OPEN ITEM)")

    pcs = PC_RE.findall(text)
    if pcs and int(pcs[-1], 16) in PARK_PCS:
        fail.append(f"parked at ${int(pcs[-1], 16):04X} -- one of the three "
                    f"self-loop traps. The CPU is frozen, so every checksum "
                    f"agrees trivially")

    if not any(mem.get(a, 0) for a in range(0x31D, 0x35D)):
        fail.append("object table $031D-$035C all zero -- nothing was ever "
                    "populated")

    if fail:
        return [f"{path}: {f}" for f in fail]

    note = "" if phase == LIVE_PHASE else \
        f" (WARNING: phase ${phase:02X}, not the candidate live phase " \
        f"${LIVE_PHASE:02X} -- weak signal only, see file header)"
    print(f"DEST-PHASE OK ({path}): phase ${phase:02X}{note}")
    return []


problems = []
for arg in sys.argv[1:] or ["build/det_a.out"]:
    problems += check(arg)

if problems:
    print("DEST-PHASE FAIL:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
