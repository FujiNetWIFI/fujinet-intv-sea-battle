; EXEC ROM entry points and RAM locations used by the netcode patch.
; Addresses are the shared EXEC's (identical across all nine ports).
;
; Sea Battle uses NEITHER EXEC RNG entry ($167D/$169E) NOR $035E directly --
; confirmed by two independent sweeps of the disassembly: grep for X_RAND*
; call targets (none), and grep for any $035E reference anywhere in the ROM
; (none).  No cart-internal shift/xor PRNG loop was found either (every
; XORR/SLLC/ADCR site is ordinary multi-word arithmetic or bit manipulation,
; not a self-referential accumulator).  This is the first cart in the family
; with genuinely zero randomness -- spikes/NOTES.md M2 #3.  RNG_LO/RNG_HI
; stay declared in ram.asm (unused) so the shared engine code assembles
; unchanged; NET_RAND1/2 wrappers are NOT needed and are not defined here.

EXEC_RNG        EQU     $035E   ; 16-bit LFSR state (System RAM) -- UNUSED
EXEC_ISR_DEF    EQU     $1126   ; the EXEC's default game-time ISR
X_MUSIC_TICK    EQU     $1A71   ; music note-timer routine.  Kept as
                                ;  NEW_TIMER_TBL slot 0, stopped -- the
                                ;  defensive placeholder every port uses
                                ;  regardless of whether the cart's OWN
                                ;  table has a music entry (this one
                                ;  doesn't); see src/hook.asm's header note.

; EXEC decoded per-controller input cells, rewritten by the scan each pass.
; Sea Battle POLLS both pairs directly (M2 #5): movement via $011F+seat,
; action/restart via $0121+seat.  There is no $035D-slot-0 null gate that
; excludes the disc from dispatch the way Soccer's does -- both surfaces
; are patched.
EXEC_IN_L       EQU     $011F   ; left/seat-0 decoded movement input
EXEC_IN_R       EQU     $0120   ; right/seat-1 decoded movement input
EXEC_KP_L       EQU     $0121   ; left/seat-0 action/restart cell
EXEC_KP_R       EQU     $0122   ; right/seat-1 action/restart cell
EXEC_HTBL       EQU     $035D   ; input-handler table pointer (game-managed)
EXEC_RAW_L      EQU     $0123   ; left controller raw (inverted port) value
EXEC_RAW_R      EQU     $0124

; Original game timer entries.  Original table at $5028, THREE entries
; (4 words each: addr lo/hi, interval lo/hi); NO EXEC music-tick entry in
; slot 0 on this cart -- slot 0 is cart code (spikes/NOTES.md M0).
;
; ** REVISED DESIGN (M3, after a deep-analysis pass caught a real bug in the
; first cut) -- SB_TICK2 and SB_TICK3 are NOT reproduced in a hand-rolled
; dispatcher at all. They stay in NEW_TIMER_TBL at their ORIGINAL targets
; and intervals, UNCHANGED, and the real EXEC dispatcher ($17D5) fires them
; NATIVELY, exactly as it always did -- because MASTER_TICK does not return
; to $17D5's own table walk until its entire tick's work (including any
; stall) is complete, $17D5 cannot reach SB_TICK2/3's dispatch check until
; MASTER_TICK has fully finished, so they still freeze atomically with
; everything else during a stall with ZERO virtualization code. This
; eliminates an entire class of "did I get the reload semantics exactly
; right" risk (§7.24) for two of the three entries, for free. **
SB_TICK1        EQU     $52B6   ; interval 1 (20 Hz): the 9-phase dispatcher
                                ;  -- movement/action polls, live-play logic,
                                ;  fleet bookkeeping, phase machine.  THIS is
                                ;  the only entry MASTER_TICK reproduces.
SB_TICK2        EQU     $5C29   ; interval $812C (bit 15 set = BOOTS
                                ;  STOPPED); real countdown lives at
                                ;  $0129/$012A in NEW_TIMER_TBL's layout
                                ;  (slot 2) -- see the layout note below.
                                ;  Armed by the cart's own X_TIMER_START at
                                ;  $57BF (shimmed) AND by two more sites that
                                ;  write the countdown directly, bypassing
                                ;  the API entirely (M3, see below).
SB_TICK3        EQU     $5EB9   ; interval $28.  Reads $0164, writes no
                                ;  game state -- pure ambient SFX trigger
                                ;  (confirmed: no cart logic anywhere reads
                                ;  $0145/$0146/$0149, so its firing is not
                                ;  observable by game logic -- §7.8 is clean
                                ;  and its countdown needs no CRC coverage).
SB_START        EQU     $5036   ; original start-of-game vector target
                                ; (.START -- no keypad number-entry gate
                                ;  found: no $1910 reference anywhere)

; ---------------------------------------------------------------------------
; NEW_TIMER_TBL layout (src/hook.asm) and the countdown-corruption bug it
; fixes (M3):
;
;   slot 0  X_MUSIC_TICK, stopped   -> countdown $0125/$0126 (defensive
;           placeholder every port in the family uses, protecting whichever
;           entry sits at RAM offset 0 from the EXEC's note-duration engine,
;           which reprograms "table entry 0's countdown" via the header
;           pointer whenever a note plays, regardless of what the cart put
;           there.  This cart calls X_PLAY_MUS2 once and X_PLAY_SFX1/2
;           across 10 sites; traced the ROM's only entry-0-rearm routine
;           (~$1A64) and found ZERO callers reaching it from either -- but
;           the placeholder costs one dummy table row, so keep it anyway.)
;   slot 1  MASTER_TICK, interval 1 -> countdown $0127/$0128
;   slot 2  SB_TICK2 ($5C29), UNCHANGED target+interval -> $0129/$012A
;   slot 3  SB_TICK3 ($5EB9), UNCHANGED target+interval -> $012B/$012C
;
; THE BUG: two sites deep inside the ship-destroyed handler write SB_TICK2's
; countdown DIRECTLY, as a hardcoded LITERAL RAM ADDRESS ($0127/$0128) --
; NOT through X_TIMER_START, so relocating/shimming the JSR at $57BF does
; NOT protect them:
;   $5A80  MVII #$0127,R4            (then $5A89/$5A8B: MVO@ R0,R4 / ...)
;   $5A92  MVO  R0,$0127             ($5A95: MVO R0,$0128)
; On the ORIGINAL cart these correctly target SB_TICK2 (which was always
; the SECOND table entry, hence $0125+2=$0127).  If MASTER_TICK ever occupies
; that same RAM offset ($0127/$0128) -- which it WOULD under a naive 2-slot
; table (music placeholder + MASTER_TICK) -- these two sites would silently
; stomp MASTER_TICK's own countdown with $14/$64 every time a ship is
; destroyed, stalling the ENTIRE dispatcher (and therefore the whole
; netcode engine) for up to 100 passes, completely unannounced.  Fixed by
; keeping SB_TICK2 at the SAME relative slot position it always had
; (position 1 counting from the table's start, i.e. the SECOND armed slot,
; music placeholder aside) and PATCHING those two sites' address operands
; from $0127->$0129 to match its new absolute countdown address in the
; 4-slot layout (tools/patches.py).  Verify with `grep 0127 build/*.dis`
; after any future table-layout change -- this class of hazard is invisible
; to recon.py, which only sees JSR-based timer-API calls.
;
; SB_TICK2's real countdown lives at $0129 (lo) / $012A (hi) in the 4-slot
; layout.  SC_CNT2/SC_CNT3 (ram.asm) are a netcode-RAM MIRROR of it, kept
; in sync every tick by MASTER_TICK and restored on a resync by
; SB_REBASE_HOOK (src/hook.asm, called from resync.asm's RS_REBASE) -- see
; ram.asm for why a direct alias does not work (LS_CKSUM's tail loop walks
; SC_CNT2..RS_SPARE4 as one physically-contiguous auto-incremented range).
; NET_START does not need to seed the real cells: the EXEC's own boot-time
; X_TIMER_INIT already copies each table slot's interval word into its
; countdown before .START ever runs, using OUR relocated table's (unchanged
; for slots 2/3) interval words.
SB_CNT2_LO      EQU     $0129   ; SB_TICK2's real countdown, low byte
SB_CNT2_HI      EQU     $012A   ; SB_TICK2's real countdown, high byte

; Original entry intervals -- SB_TICK1 needs no countdown of its own
; (interval 1, dispatched unconditionally by MASTER_TICK); SB_TICK2/3 are
; seeded automatically by the EXEC's boot-time timer init, not by us.
SB_INT1         EQU     1

; The dynamic $035D phase machine.  $0164 is the phase cell (0-8); SB_TICK1
; is a 9-entry computed-jump dispatcher on it, and (unlike Soccer's single
; constant table) each phase transition installs its OWN handler table via
; the JSR-return-address idiom at $52E7 -- GAME_TBL is genuinely dynamic
; here.  Phase bodies, corrected and deepened by a second analysis pass
; that cross-referenced the EXEC's own dispatch-table format from exec.s
; (spikes/NOTES.md M3 -- supersedes the M2 draft, which mislabeled phases
; 6/7/8):
;   $0164=0  $52CD  boot/settle -> when $01D9==0: installs the MAP table at
;            $52D9, sets phase 1.  While $01D9!=0 this phase installs the
;            EXEC's own null table $1906 instead (all input dead) -- this
;            is ALSO re-entered on every map<->battle handover.
;   $0164=1  $52EA  **MAP.** victory test, per-player fleet blink
;            (L_539B(0), L_539B(1)), fleet-contact scan, mine scan.
;            $035D == $52D9 (MAP table: slot0 disc -> $5422 move selected
;            fleet, slot1 keypad -> $5439 build/launch/recall/engage,
;            buttons null).
;   $0164=2  $5301  both engaged fleets blink (pre-battle)
;   $0164=3  $5321  mine-hit colour-cycle
;   $0164=4  $5333  3-pass freeze -> phase 7, arms $01D8 := 10
;   $0164=5  $5380  **TACTICAL BATTLE.** damage resolution, then
;            L_57C6 (polled ship steering, both seats) and L_589B (polled
;            torpedo steering + fire, both seats).  $035D == $5376 (BATTLE
;            table: slot0 disc null [polled instead], slot1 keypad -> $5772
;            select/cancel target, slot2 top button null [polled], slots
;            3/4 lower buttons -> $595C fire depth charge).
;   $0164=6  $5391  **GAME OVER, TERMINAL.** Flashes $0177 ^= $0165 and
;            repaints every pass, forever -- there is no path back to
;            phase 0 without an armed SB_TICK2 countdown, which nothing
;            re-arms from here. Two consoles parked here agree trivially --
;            a false-PASS trap (§5.5/§7.25), not a hard self-loop.
;   $0164=7  $5346  battle-entry screen shake -> phase 5, installs the
;            BATTLE table at $5376.  Short (a few passes); NOT a quiescent
;            point (input dead only briefly, mid-transition INTO battle).
;   $0164=8  UNREACHABLE.  The only writers ($5F33, $5EF9) are inside dead
;            code (X_PLAY_SFX1/2/X_PLAY_MUS2 never return past their inline
;            data, per exec.s -- so code textually "after" one of those
;            calls in this disassembly is unreachable).  $52E3's
;            EXEC-null-table install is likewise dead.
SB_PHASE        EQU     $0164

; Destination-phase / sim-state cells (§5.5), from the M3 pass -- boot
; values are exact, from .START's copy of the ROM inventory table:
SB_HTBL_MAP     EQU     $52D9   ; $035D value while the MAP table is live
SB_HTBL_BATTLE  EQU     $5376   ; $035D value while the BATTLE table is live
SB_INVENTORY    EQU     $01B5   ; 9 cells, packed nibbles (hi=P0,lo=P1).
                                ;  Boot value, copied verbatim from ROM
                                ;  $5FB7-$5FBF by .START: $11 $11 $22 $11
                                ;  $33 $22 $11 $22 $33.  Changes ONLY via a
                                ;  keypad ship-assignment -- the strongest
                                ;  single "real gameplay ran" signal: masked
                                ;  disc-only fuzz can never touch it.
SB_FLEET_STATE  EQU     $017D   ; 8 cells (4 fleets/seat), bit2 = at sea.
                                ;  Boot value all zero; a fleet LAUNCH (ENTER
                                ;  accepted) sets bit2 on one cell.
SB_LEVEL        EQU     $0176   ; global map cycle counter, 0..60, +1 per
                                ;  phase-1 tick -- a liveness signal (proves
                                ;  the map-phase per-tick logic ran) but NOT
                                ;  proof that any INPUT landed.
SB_BLINK        EQU     $015F   ; +seat: fleet-blink counter 0..10, proves
                                ;  L_539B ran for both seats (also liveness
                                ;  only, not an input-landed proof).
SB_EVT_ARM      EQU     $01D8   ; 10-tick countdown gating the phase 4->7->5
                                ;  transition sequence
SB_EVT_CNT      EQU     $01D9   ; settle countdown; ($0164==0 && this==0) is
                                ;  the QUIESCENT POINT candidate (below)

; §7.6 quiescent point: primary candidate is ($0164==0 && $01D9==0) --
; equivalently $035D==$1906 (the EXEC null table) -- the map<->battle
; handover, all input dead for ~3 passes.  A weaker but MORE FREQUENT
; candidate is any $01D9!=0 window (also entered on every fleet launch and
; every depth charge, 2-4 passes each), since $52EE-$52F0 gates the entire
; per-player update on it.  BOTH require reaching the map/keypad flow at
; all, which masked $3F disc-only fuzz can never do (§7.29: a QUIESCE=1
; forcing mode that pokes $0164:=0, $01D9:=4 is required, not optional, or
; this whole branch of RS_PENDING goes untested forever).  NOT yet confirmed
; on screen -- recon-level only.

; §7.9 false-PASS candidates: THREE bare `DECR R7` one-instruction self-loops
; found at $5E90, $5EA7 and $5EAE -- all inside the MOB animation-script
; DATA table ($5E74-$5EB8, embedded UCALL targets, not reachable as code) --
; exactly Soccer's $5122 trap in shape but NOT actually reachable execution
; paths (M3 correction to the M2 draft, which flagged them as live).  The
; REAL false-PASS trap on this cart is phase 6 (game over, above) and phase
; 1 with no fleet ever launched (near-static: only SB_BLINK and SB_LEVEL
; advance) -- both are behavioural traps, not instruction-level ones, so
; det/rig/m4 verdicts must assert SB_INVENTORY or SB_FLEET_STATE changed,
; not just that the CPU is still running.

; The timer-arm site: SDBD MVII #$502C,R1 / JSR R5,X_TIMER_START at $57BF
; ($502C = original table slot 1 = the SB_TICK2 entry, an ABSOLUTE address
; that goes stale once the table is relocated -- PORTING.md §3/§7.24, Armor
; Battle's exact shape).  The JSR operand at $57C0/$57C1 is patched to
; SB_START_SHIM, which reimplements X_TIMER_START's own arm semantics
; (clear bit 15 of the CURRENT countdown) directly against SB_TICK2's real
; countdown address ($0129/$012A in the 4-slot layout), bypassing the
; broken post-relocation header-chase arithmetic entirely.
X_TIMER_START   EQU     $1844

; --- Symbols resync.asm/lockstep.asm expect under canonical (SC_*) names ---
SC_PASSLEN      EQU     $0103   ; real EXEC pass-length cell; this cart never
                                ;  writes it, kept in the resync tail as free
                                ;  insurance and to keep the family's tail
                                ;  layout identical (PORTING.md §7.16)
; SC_ISR_SAVE: Soccer's cart stashes its own saved interrupt vector at
; $0160/$0161 and RS_CLAMP_ISR forces it back to the EXEC default after a
; resync (PORTING.md §7.27's code-pointer clamp).  Sea Battle has NO cart
; ISR at all (zero $0100/$0101 writes anywhere in the ROM, M0/M2) -- there
; is no vector for the game to stash.  RS_CLAMP_ISR still runs unconditionally
; from RS_REBASE, so SC_ISR_SAVE needs a real, harmless target: a netcode-RAM
; spare, not a game-scratch cell, so the clamp touches nothing the cart
; reads.  It is a structural no-op on this cart by construction.
SC_ISR_SAVE     EQU     $81AD   ; harmless spare pair, zeroed by NET_START

; DANCE_SETTLE (src/vdispatch.asm, copied unchanged) unconditionally checks
; $0101 against SC_ISR_BODY's page before repainting a terminal screen --
; PORTING.md §7.10.  This cart never installs a cart ISR (zero $0100/$0101
; writes anywhere in the ROM, M0), so $0101 is always the EXEC default's
; high byte ($11).  Any page that can never equal $11 makes the check a
; structural no-op (falls through on the very first read, never waits).
SC_ISR_BODY     EQU     $0000
