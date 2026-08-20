#!/usr/bin/env python3
"""Destination-phase assertion (PORTING.md §5.5, §7.25).

A CRC gate PASS can be two consoles identically stuck in the same wrong
place. Sea Battle's boot state (phase 1, the map) is near-static under
disc-only input -- masked $3F fuzz can never launch a fleet, so a fuzz-only
run would sit there for its entire duration while every checksum agrees
trivially.

** CONFIRMED LIVE, this session (spikes/NOTES.md M4): ** the strongest
"real gameplay ran" signal on this cart is SB_INVENTORY ($01B5-$01BD, 9
packed-nibble cells), which has an exact known boot value and changes
ONLY via a keypad ship-assignment -- and SB_FLEET_STATE ($017D-$0184,
bit 2 = at sea), which is 0 at boot and gets bit 2 set only once a fleet
is actually launched. Both were driven and confirmed via live memory
dumps: pressing keypad digit "1" then ENTER (the sequence now scripted in
SCRIPT_TBL, src/vdispatch.asm) decrements an inventory nibble and sets a
fleet's at-sea bit, in that order, for both seats independently.

Known traps (recon + M3, some not yet confirmed on screen):

  1. Parked at $0164 = 0 or 1 with SB_INVENTORY unchanged -- no keypad
     input ever landed. This is where a fuzz-only run sits.
  2. $0164 = 6 -- GAME OVER, TERMINAL. Flashes forever, no path back.
  3. The three one-instruction self-loops at $5E90/$5EA7/$5EAE (bare
     `DECR R7`) are, per M3's deeper trace, inside the MOB animation-
     script DATA table, not reachable as code -- kept as a defensive
     check anyway since a future edit could change that.

$0164 == 5 (the tactical battle phase) has NOT yet been confirmed reached
by SCRIPT_TBL -- the two launched fleets are driven toward each other by
best-effort movement, not a proven collision. This checker does not
require phase 5; tighten it once collision is confirmed (spikes/NOTES.md).

Usage: check_dest_phase.py build/det_a.out [...]
"""
import re
import sys

DUMP_RE = re.compile(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#", re.M)
PC_RE = re.compile(r"^\s*(?:[0-9A-F]{4}\s+){7}([0-9A-F]{4})\s+\S+\s+\S", re.M)

PARK_PCS = (0x5E90, 0x5EA7, 0x5EAE)   # the three bare-DECR-R7 self-loops
TERMINAL_PHASE = 6                    # GAME OVER -- confirmed terminal (M3)
BATTLE_PHASE = 5                      # confirmed reachable in principle;
                                       #  NOT required by this checker yet

# Exact boot value of SB_INVENTORY ($01B5-$01BD), copied verbatim from ROM
# $5FB7-$5FBF by .START -- confirmed by dis1600 and by a live boot dump.
BOOT_INVENTORY = [0x11, 0x11, 0x22, 0x11, 0x33, 0x22, 0x11, 0x22, 0x33]


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
    elif phase == TERMINAL_PHASE:
        fail.append(f"parked at phase ${phase:02X} (GAME OVER, terminal) -- "
                    f"flashes forever, no path back; every checksum agrees "
                    f"trivially")

    inventory = [mem.get(0x1B5 + i) for i in range(9)]
    inventory_changed = None not in inventory and inventory != BOOT_INVENTORY

    fleet_launched = any(
        mem.get(0x17D + i) is not None and (mem[0x17D + i] & 0x04)
        for i in range(8)
    )

    if not inventory_changed and not fleet_launched:
        fail.append(
            "SB_INVENTORY ($01B5-$01BD) unchanged from its boot value AND "
            "no SB_FLEET_STATE cell ($017D-$0184) has bit 2 (at sea) set -- "
            "no keypad input ever landed; this run covered no real "
            "gameplay, only boot/map-idle bookkeeping"
        )

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

    battle_note = " (reached BATTLE phase)" if phase == BATTLE_PHASE else ""
    print(f"DEST-PHASE OK ({path}): phase ${phase:02X}{battle_note}, "
          f"inventory changed = {inventory_changed}, "
          f"fleet launched = {fleet_launched}")
    return []


problems = []
for arg in sys.argv[1:] or ["build/det_a.out"]:
    problems += check(arg)

if problems:
    print("DEST-PHASE FAIL:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
