# In-place patch map for SeaBattle.bin (word address -> as1600 expression).
# Symbols are defined in src/hook.asm / src/ram.asm / src/exec_equ.asm.
# Building with tools/dump_rom.py and NO patch file must stay byte-identical
# to the original (make verify-org -- verified).
#
# STATUS (see spikes/NOTES.md M0/M2/M3 for the evidence trail): header
# relocation, the timer-arm shim, both shadow-pair operands, and (M3, a
# second deeper pass) two more sites that write SB_TICK2's countdown as a
# hardcoded literal RAM address are decoded and confirmed in the dis1600
# listing.  Sea Battle makes ZERO X_RAND1/X_RAND2 calls and has zero $035E
# references anywhere in the ROM (two independent sweeps), so unlike every
# other port in the family there are NO RNG wrapper patch sites at all.
# `make verify-patch` proves exactly the 14 words below differ from the
# original ROM -- still the smallest patch map of any port in the family
# (Soccer's, previously smallest, was 18 words).
{
    # --- Cart header ---
    # $5002/$5003: EXEC timer table pointer -> relocated table in $6000 seg.
    0x5002: "NEW_TIMER_TBL AND $FF",
    0x5003: "NEW_TIMER_TBL SHR 8",
    # $5004/$5005: start-of-game vector -> netcode init shim (falls through
    # to the original .START at $5036).
    0x5004: "NET_START AND $FF",
    0x5005: "NET_START SHR 8",

    # --- Timer-arm site -> virtualized-flag shim ---
    # $57BF: SDBD / MVII #$502C,R1 / JSR R5,X_TIMER_START.  $502C is the
    # ORIGINAL table's slot-1 address (the SB_TICK2 entry).  X_TIMER_START's
    # own arithmetic resolves an absolute ROM address against the CURRENT
    # header pointer, which is now ours -- so calling through, even
    # unmodified, computes garbage post-relocation regardless of table
    # layout.  Retargeted to SB_START_SHIM, which reimplements the real arm
    # semantics directly against SB_TICK2's real (relocated-position)
    # countdown.  The JSR is the 3-word `JSR R5,target` form
    # (0004/0118/0044), so the two operand words follow the opcode at $57BF.
    0x57C0: "((SB_START_SHIM SHR 10) SHL 2) OR $0100",  # JSR R5 @ $57BF
    0x57C1: "SB_START_SHIM AND $3FF",

    # --- Direct countdown writers -> relocated address (M3) ---
    # $5A7F-$5A94 (inside the ship-destroyed handler) writes SB_TICK2's
    # countdown as a HARDCODED LITERAL RAM ADDRESS, bypassing the timer API
    # entirely -- recon.py cannot see this class of site at all, since it
    # only looks for JSR-based timer-API calls.  On the original cart these
    # correctly targeted $0127/$0128 because SB_TICK2 was always the SECOND
    # table entry (right after the game's own slot 0).  NEW_TIMER_TBL keeps
    # SB_TICK2 at that SAME relative position (slot 2, counting the music
    # placeholder and MASTER_TICK first), so its real countdown is now
    # $0129/$012A -- these three operand words are retargeted to match.
    # Left unpatched, they would silently corrupt whatever DOES occupy
    # $0127/$0128 (MASTER_TICK's own countdown, under the natural 2-slot
    # table shape) every time a ship is destroyed, stalling the entire
    # dispatcher -- see src/hook.asm's NEW_TIMER_TBL note for the full
    # argument.  `MVII #$0127,R4` at $5A7F (operand at $5A80); the two
    # `MVO R0,G_0127`/`MVO R0,G_0128` absolute stores at $5A91/$5A94
    # (operands at $5A92/$5A95).
    0x5A80: "$0129",
    0x5A92: "$0129",
    0x5A95: "$012A",

    # --- Polled controller reads -> the shadow pairs ---
    # Sea Battle POLLS BOTH pairs directly (PORTING.md §5.3 surfaces 1 AND
    # a second poll, not just dispatch): movement at $011F/$0120 (two
    # walking-pointer sites) and action/restart at $0121/$0122 (three
    # sites) -- unlike Soccer, which never reads $0121 at all.  Every site
    # below computes addr = base + seat, with the seat number (0 or 1)
    # supplied by a REGISTER at call time (R1, R2 or R5 depending on site),
    # not baked into the immediate -- so every site patches to the SAME
    # plain base symbol, and the pair must stay CONSECUTIVE
    # (SHADOW_CTRL/SHADOW_CTRL_R = $8140/$8141, SHADOW_KP/SHADOW_KP_R =
    # $8142/$8143 -- one patched immediate serves both seats at each site).
    #
    # Movement ($011F): $5835 `MOVR R1,R2 / ADDI #$011F,R2` (both seats via
    # L_5833, called with R1=0 then R1=1 from $57C6); $58D5
    # `ADDI #$011F,R1` (R1 already holds the seat number in place).
    0x5836: "SHADOW_CTRL",      # $5835 operand -- L_5833's poll, both seats
    0x58D6: "SHADOW_CTRL",      # $58D5 operand -- L_58A6's disc-check read

    # Action/restart ($0121): $583D `MOVR R1,R2 / ADDI #$0121,R2` (same
    # L_5833 call, reads the paired action cell for whichever seat R1
    # names); $58CF `MOVR R1,R5 / ADDI #$0121,R5` (L_58A6, seat via R1);
    # $5920 `ADDI #$0121,R1` (R1 already holds the seat number in place).
    0x583E: "SHADOW_KP",        # $583D operand
    0x58D0: "SHADOW_KP",        # $58CF operand
    0x5921: "SHADOW_KP",        # $5920 operand
}
