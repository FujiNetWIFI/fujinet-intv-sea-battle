; Netcode hook segment for Sea Battle (Mattel 1980).
;
; STATUS: M3 pass (spikes/NOTES.md) -- a second, deeper disassembly pass
; caught a real bug in the first cut (two cart sites write SB_TICK2's
; countdown as a HARDCODED LITERAL RAM ADDRESS, bypassing the timer API
; entirely; under the original 2-slot table they would have silently
; stomped MASTER_TICK's own countdown -- see the NEW_TIMER_TBL note below).
; Fixed by a 4-slot table that preserves SB_TICK2's original relative
; position and patches those two sites' operands to match.  Sea Battle has
; ZERO RNG call sites (no X_RAND1/X_RAND2, no $035E reference anywhere in
; the ROM -- confirmed by two independent sweeps), so there are no RNG
; wrapper patch sites at all, unlike every other port.
;
; The cart header's timer-table pointer ($5002) is patched to NEW_TIMER_TBL:
;
;   slot 0  X_MUSIC_TICK, stopped  -> countdown $0125/$0126.  Defensive
;           placeholder every port in the family uses: the EXEC's note-
;           duration engine reprograms "table entry 0's RAM countdown" via
;           the header pointer whenever a note plays, regardless of what
;           the cart put there.  Traced the ROM's only entry-0-rearm
;           routine and found zero callers reaching it from this cart's
;           X_PLAY_MUS2/X_PLAY_SFX1/2 sites -- but the placeholder costs
;           one dummy row, so keep it anyway (M3).
;   slot 1  MASTER_TICK, interval 1, always armed -> countdown $0127/$0128.
;           Our master dispatcher, every pass.
;   slot 2  $5C29 (SB_TICK2), UNCHANGED target+interval -> $0129/$012A.
;   slot 3  $5EB9 (SB_TICK3), UNCHANGED target+interval -> $012B/$012C.
;
; ** SB_TICK2 and SB_TICK3 are NOT reproduced in a hand-rolled dispatcher.
; They stay at their original ROM targets and intervals and fire NATIVELY
; via the real $17D5 dispatcher (exec_equ.asm has the full timing argument
; for why this is still stall-safe): MASTER_TICK does not return to $17D5's
; own table walk until its entire tick's work -- including any stall -- is
; done, so $17D5 physically cannot reach slot 2/3's dispatch check any
; earlier.  This is why SB_TICK2's original table POSITION (immediately
; after slot 0 in the ORIGINAL 3-slot table) matters: two sites deep in the
; ship-destroyed handler ($5A80, $5A92, $5A95) write its countdown as a
; hardcoded literal RAM address ($0127/$0128 on the original cart), not
; through the timer API -- so they are patched (tools/patches.py) to the
; new address ($0129/$012A) that matches its new slot position instead. **
;
; No X_SCAN self-call hazard: unlike NASL Soccer, this cart never calls the
; controller scan itself (zero references to $14F1 anywhere in the ROM), so
; $035D only needs nulling AFTER the tick, not before as well.
;
; Two input surfaces polled directly by this cart (M2 #5), BOTH needing a
; shadow pair: movement at $011F/$0120 (two sites, walking-pointer form) and
; action/restart at $0121/$0122 (three sites) -- unlike Soccer, which never
; reads $0121 at all.  The $035D handler table is DYNAMIC here (the 9-phase
; dispatcher installs a different table per phase via the JSR-return-address
; idiom at $52E7), so GAME_TBL_LO/HI genuinely varies tick to tick, unlike
; Soccer's single constant $5869 -- adopt-don't-restore (§5.3) is load-
; bearing.

        ORG     $6000

NEW_TIMER_TBL:
        DECLE   X_MUSIC_TICK AND $FF, X_MUSIC_TICK SHR 8
        DECLE   $01, $80                ; interval $8001: stopped, one-shot
        DECLE   MASTER_TICK AND $FF, MASTER_TICK SHR 8
        DECLE   $01, $00                ; every pass, always armed
        DECLE   SB_TICK2 AND $FF, SB_TICK2 SHR 8
        DECLE   $2C, $81                ; original interval word, UNCHANGED
                                        ;  (boots stopped: bit 15 set)
        DECLE   SB_TICK3 AND $FF, SB_TICK3 SHR 8
        DECLE   $28, $00                ; original interval word, UNCHANGED
        DECLE   $00, $00                ; terminator

; ---------------------------------------------------------------------------
; NET_START -- patched start-of-game vector ($5004, original target $5036).
; Runs after the title screen, before the EXEC main loop starts (the EXEC
; jumps here with R5 = $108F), so netcode RAM is initialized before the
; first MASTER_TICK.  Falls through to the original .START.
;
; SB_TICK2/3's real countdowns need NO seeding here: the EXEC's own
; boot-time X_TIMER_INIT (run before .START, from the relocated header
; pointer) already copies NEW_TIMER_TBL's interval words into $0125-$012C,
; using the SAME words the original cart shipped with -- this is the whole
; benefit of leaving those two entries native instead of virtualizing them.
; SC_CNT2/SC_CNT3's netcode-RAM mirror starts at NET_START's zero fill,
; which is harmless: MASTER_TICK's first tick refreshes it from the real
; cells before anything reads it.
; ---------------------------------------------------------------------------
NET_START:
        PSHR    R5                      ; EXEC main-loop return
        MVII    #NET_RAM, R4
        MVII    #NET_RAM_SIZE, R1
        CLRR    R0
@@zero: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@zero
        MVII    #SPIKE_DELAY, R0        ; virt-dispatch delay depth (spike knob)
        MVO     R0,     DELAY_EN
        ; Seat defaults for local builds: seat 0 of a 2-player game.  The
        ; netplay path overwrites both from the START payload.
        MVII    #2,     R0
        MVO     R0,     NET_COUNT
    IF SPIKE_VIRT <> 0
        JSR     R5,     LS_RING_INIT    ; idle-fill the dispatch rings
    ENDI
    IF SPIKE_ECHO <> 0
        JSR     R5,     ECHO_TEST       ; parks with results; never returns
    ENDI
    IF NET_SESSION <> 0
        JSR     R5,     SES_MAIN        ; login/lobby; arms NET_ACTIVE or not
    ENDI
        PULR    R5
        J       SB_START

; NET_NULL_TBL: handed to the EXEC scan (via $035D) while dispatch is
; virtualized so its event dispatch resolves null pointers and never calls
; game code from real local input.  Zeros on both sides of the base cover
; negative slot indexes.
NET_NULL_TBL:
        DECLE   0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        DECLE   0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; ---------------------------------------------------------------------------
; MASTER_TICK -- timer entry 1 of NEW_TIMER_TBL, dispatched by the EXEC
; every main-loop pass.  May clobber R0-R3.  Returns via the dispatcher's
; R5.
; ---------------------------------------------------------------------------
MASTER_TICK:
        PSHR    R5
    IF STALL_N <> 0
        ; Stall injector (spike c): every 64th pass, busy-spin ~STALL_N
        ; frames INSIDE the dispatch (mainline).  The ISR keeps firing but
        ; $0102 sits at 0 mid-pass, so it takes its skip path: display
        ; continues, object motion and the rest of the pass freeze.  That is
        ; exactly how a network-wait stall behaves; a skip-dispatch stall is
        ; WRONG (object motion would run on).
        MVI     FRM_CTR, R0
        INCR    R0
        ANDI    #$3F,   R0
        MVO     R0,     FRM_CTR
        BNEQ    @@no_stall
        DIS
        MVI     $102,   R2
        CLRR    R0
        MVO     R0,     $102
        EIS
        MVII    #STALL_N * 3000, R1     ; ~15 cycles/iter, ~1 frame per 1000
@@spin: DECR    R1
        BNEQ    @@spin
        DIS
        MVO     R2,     $102
        EIS
@@no_stall:
    ENDI
    IF NET_SESSION <> 0
        MVI     NET_ACTIVE, R0
        TSTR    R0
        BEQ     @@mt_local
        JSR     R5,     LS_PASS         ; lockstep netplay path
        PULR    R7
@@mt_local:
    ENDI
        JSR     R5,     UPDATE_SHADOW
    IF SPIKE_RECORD <> 0
        JSR     R5,     REC_CAPTURE     ; log the live cells for this tick
    ENDI
    IF SPIKE_VIRT <> 0
        ; Virtualized local dispatch.  BOTH seats replay, every tick: there
        ; is no turn arbiter on this cart (see ram.asm) -- the per-player
        ; update L_539B and both poll routines run for seat 0 then seat 1
        ; every tick regardless of anything either controller does.
        JSR     R5,     VIRT_CAPTURE
        JSR     R5,     LS_TBL_ADOPT
        MVI     GAME_TBL_HI, R1
        SWAP    R1,     1
        ADD     GAME_TBL_LO, R1
        BEQ     @@mt_no_tbl
        MVO     R1,     $35D
@@mt_no_tbl:
        JSR     R5,     SHADOW_FROM_RINGS
        CLRR    R0
        MVO     R0,     VD_SIDE         ; seat 0 -> $011F/$0121, MOB $031D
        MVO     R0,     VD_CTRL
        JSR     R5,     LS_VDISPATCH
        MVII    #1,     R0
        MVO     R0,     VD_SIDE         ; seat 1 -> $0120/$0122, MOB $0335
        MVO     R0,     VD_CTRL
        JSR     R5,     LS_VDISPATCH
    ENDI
        JSR     R5,     SC_GAME_TICK
    IF SPIKE_VIRT <> 0
        JSR     R5,     LS_TBL_ADOPT
        MVII    #NET_NULL_TBL+4, R0
        MVO     R0,     $35D
    ENDI
    IF SPIKE_TRACE <> 0
        JSR     R5,     TRACE_TICK
    ELSE
        ; sim tick counter (16-bit across two 8-bit cells)
        MVI     TICK_LO, R0
        INCR    R0
        MVO     R0,     TICK_LO
        CMPI    #$100,  R0
        BNEQ    @@mt_out
        MVI     TICK_HI, R0
        INCR    R0
        MVO     R0,     TICK_HI
    ENDI
@@mt_out:
        PULR    R7

; ---------------------------------------------------------------------------
; SC_GAME_TICK -- lockstep.asm (generic, unchanged) calls this by name from
; BOTH MASTER_TICK's local path and LS_PASS's netplay path ("all four
; entries, always armed" -- a comment written for an earlier port; on this
; cart there is exactly one entry left to reproduce by hand). SB_TICK2/
; SB_TICK3 (table slots 2/3) fire NATIVELY, dispatched by $17D5 immediately
; after MASTER_TICK returns -- see the NEW_TIMER_TBL note at the top of
; this file for why that is still stall-safe.
;
; SB_TICK1 is NOT native, and DOES need an explicit call here: $17D5's
; slot 1 target is MASTER_TICK (our code), not SB_TICK1 (the game's own
; 9-phase dispatcher) -- the table entry that used to point at SB_TICK1 was
; REPLACED, not kept alongside MASTER_TICK, so nothing calls it unless we
; do. (Caught by the M3 boot-dump check: an earlier draft of this routine
; reasoned SB_TICK1 was "dispatched by $17D5 calling MASTER_TICK" and
; dropped the call entirely -- $0164 stayed at 0 forever, i.e. the game's
; own logic silently never ran at all. Confirmed live by re-decoding
; det_a.out after the fix.)
;
; Also does the two pieces of per-tick bookkeeping that must happen on
; BOTH paths, in time for LS_CKSUM/RS_PENDING (both called after this, on
; both paths -- lockstep.asm's own call order): mirroring SB_TICK2's real
; countdown into SC_CNT2/SC_CNT3, and computing SB_QUIESCENT. Putting these
; in MASTER_TICK's local-only section instead would have left them stale
; during actual netplay (NET_ACTIVE returns via LS_PASS before ever
; reaching that section) -- caught the same way as the SB_TICK1 bug, by
; asking "does this run on BOTH paths" rather than trusting a green build.
;
; Interval 1, so unconditional -- called every tick, exactly like every
; other port's single mandatory game-logic entry.
;
; Clobbers R0-R3. Returns via the caller's R5.
; ---------------------------------------------------------------------------
SC_GAME_TICK:
        PSHR    R5
        JSR     R5,     SB_TICK1
        ; Mirror SB_TICK2's REAL countdown into netcode RAM, so LS_CKSUM
        ; (generic, unchanged) sees SB_TICK2's actual live pacing.  See
        ; ram.asm/exec_equ.asm for why this can't be a direct alias.
        MVI     SB_CNT2_LO, R0
        MVO     R0,     SC_CNT2
        MVI     SB_CNT2_HI, R0
        MVO     R0,     SC_CNT3
        ; SB_QUIESCENT: 1 iff $0164==0 (spikes/NOTES.md M4's corrected
        ; quiescent point) -- resync.asm's generic RS_PENDING reads this
        ; through SC_PHASE/SC_PHASE_DEAD (exec_equ.asm/ram.asm).
        ;
        ; CORRECTED from the M3 draft, which additionally required
        ; $01D9==0.  Phase 0's OWN body ($52CD, dispatched by SB_TICK1
        ; just above this point in the SAME tick) tests $01D9==0 FIRST and
        ; transitions to phase 1 immediately when true -- so by the time
        ; this check runs (after SB_TICK1 has already executed this tick),
        ; "$0164==0 AND $01D9==0" can essentially never be observed: if
        ; $01D9 WAS 0 when SB_TICK1 ran, $0164 is already 1 by now.  Sitting
        ; in phase 0 at all (checked post-tick) already means $01D9 was
        ; NONZERO this tick -- i.e. still counting down -- which is exactly
        ; the settling window, confirmed live-traced to $5C65-$5C6E: every
        ; tactical-battle exit sets $0164:=0 then $01D9:=4, a real,
        ; RECURRING 4-tick quiescent window every time a battle ends, not a
        ; one-time boot artifact.
        MVI     SB_PHASE, R0
        TSTR    R0
        BNEQ    @@gt_not_q
        MVII    #1,     R0
        MVO     R0,     SB_QUIESCENT
        B       @@gt_qout
@@gt_not_q:
        CLRR    R0
        MVO     R0,     SB_QUIESCENT
@@gt_qout:
        PULR    R7

; SC_POSSESSION -- lockstep.asm (generic, unchanged) calls this by name
; from LS_PASS, right after SC_GAME_TICK ("ARB_SEAT for NAME_DRAW, display
; only" -- a Soccer-specific comment; Soccer's ARB_SEAT highlighted
; whichever team held the ball). Sea Battle has no equivalent possession
; concept -- ARB_SEAT (ram.asm) stays declared and always zero. Stub.
SC_POSSESSION:
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; SB_START_SHIM -- replaces the stale-absolute-address JSR at $57BF/$57C0
; (`SDBD / MVII #$502C,R1 / JSR R5,X_TIMER_START`).  $502C was the ORIGINAL
; table's slot-1 address (SB_TICK2's entry); the header pointer it gets
; resolved against is now OUR relocated table, so X_TIMER_START's own
; offset arithmetic (stale ROM address minus the NEW header pointer) is
; broken regardless of table layout -- calling through is not an option.
;
; Reimplements X_TIMER_START's actual arming semantics directly against
; SB_TICK2's real countdown ($0129/$012A in the 4-slot layout): clear bit
; 15 of the CURRENT countdown value (SB_TICK2's header interval is $812C,
; so this yields $012C = 300 passes = 15 s, exactly the original constant).
; Bit 15 is the top bit of the HIGH byte, so only $012A needs touching.
;
; Must preserve every register the call site's surrounding code still needs
; across the call -- PORTING.md §7.24: R1 held the (now-irrelevant)
; absolute address; the next instruction is `JSR R5,L_5F85` (a retreat SFX
; trigger), which does not consume R1 before overwriting it.  Clobbers R0
; only.
; ---------------------------------------------------------------------------
SB_START_SHIM:
        MVI     SB_CNT2_HI, R0
        ANDI    #$7F,   R0
        MVO     R0,     SB_CNT2_HI
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; SB_REBASE_HOOK -- called from resync.asm's RS_REBASE (one added line;
; resync.asm is otherwise unchanged) after a state image has been applied.
; Two jobs:
;
; 1. Restore SB_TICK2's real countdown from the just-applied SC_CNT2/SC_CNT3
;    mirror. Without this, a resync would silently desync the ONE piece of
;    state this cart tracks outside the standard $015D-$01EF image range --
;    the pushed image would look right in the mirror but the real
;    dispatcher would keep running on its own unsynchronized countdown.
;
; 2. Clamp $0164 (SB_PHASE) to 0-8.  It indexes a raw computed jump at
;    $52C3 (`ADD@ R5,R7`) with NO bounds check in the cart itself -- the
;    single most dangerous transported cell found in this port (worse than
;    a code-pointer clamp: it is read as an offset into a jump straight out
;    of the phase dispatcher).  A corrupted wire byte here would jump
;    execution to an arbitrary ROM address.  Symmetric on both sides, so
;    CRC-neutral when healthy.
;
; Clobbers R0.
; ---------------------------------------------------------------------------
SB_REBASE_HOOK:
        MVI     SC_CNT2, R0
        MVO     R0,     SB_CNT2_LO
        MVI     SC_CNT3, R0
        MVO     R0,     SB_CNT2_HI
        MVI     SB_PHASE, R0
        CMPI    #8,     R0
        BLE     @@rh_ok
        CLRR    R0
        MVO     R0,     SB_PHASE
@@rh_ok:
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; UPDATE_SHADOW -- feed both decoded-input shadow pairs from the live EXEC
; cells.  LOAD-BEARING on this cart: both movement ($011F/$0120) and
; action/restart ($0121/$0122) are polled directly by patched cart operands
; -- unlike Soccer, where only the movement pair needed this.
; ---------------------------------------------------------------------------
UPDATE_SHADOW:
        MVI     EXEC_IN_L, R0
        MVO     R0,     SHADOW_CTRL
        MVI     EXEC_IN_R, R0
        MVO     R0,     SHADOW_CTRL_R
        MVI     EXEC_KP_L, R0
        MVO     R0,     SHADOW_KP
        MVI     EXEC_KP_R, R0
        MVO     R0,     SHADOW_KP_R
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; SHADOW_FROM_RINGS -- feed both polled pairs from the per-seat rings at the
; current tick.  PORTING.md §7.20: this must be called from BOTH
; MASTER_TICK's virt path AND LS_PASS, or a real two-console rig sees this
; console's own idle second controller instead of the exchanged remote
; value (a bug invisible to `make det`, a single process where both "sides"
; read the same live cells regardless).
;
; ** SEAT-ABSOLUTE, NOT SEAT-RELATIVE. ** Seat 0 always feeds
; SHADOW_CTRL/SHADOW_KP (the cells the cart reads for MOB $031D) and seat 1
; always feeds SHADOW_CTRL_R/SHADOW_KP_R (MOB $0335), on BOTH consoles,
; regardless of which seat we are.
;
; Clobbers R0/R3.
; ---------------------------------------------------------------------------
SHADOW_FROM_RINGS:
        MVII    #SEAT_RING, R3          ; seat 0 movement
        ADD     TICK_LO, R3
        MVI@    R3,     R0
        MVO     R0,     SHADOW_CTRL
        MVII    #SEAT_RING + $100, R3   ; seat 1 movement
        ADD     TICK_LO, R3
        MVI@    R3,     R0
        MVO     R0,     SHADOW_CTRL_R
        MVII    #SEAT_KP, R3            ; seat 0 action/restart
        ADD     TICK_LO, R3
        MVI@    R3,     R0
        MVO     R0,     SHADOW_KP
        MVII    #SEAT_KP + $100, R3     ; seat 1 action/restart
        ADD     TICK_LO, R3
        MVI@    R3,     R0
        MVO     R0,     SHADOW_KP_R
        MOVR    R5,     R7
