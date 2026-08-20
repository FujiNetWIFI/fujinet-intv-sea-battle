; Virtual input-event dispatch engine -- seat-generalized for 2-4 players.
;
; Soccer is a HYBRID cart (spikes/NOTES.md M2 #2): input reaches game code
; BOTH through the $035D handler table AND through four polled reads of
; $011F/$0120 patched to the shadow pair.  In fact slot 0 (disc) of the
; single handler table $5869 is NULL, so no disc event dispatches anywhere
; -- movement reaches the sim ONLY via the polls, and the dispatch carries
; just the action buttons and the one keypad handler.  Both surfaces have
; to work; neither alone is sufficient.
;
; The engine is seat-indexed: each seat owns one 256-cell ring page
; (decoded at SEAT_RING + seat*$100, keypad cell at SEAT_KP + seat*$100),
; and VD_SIDE names the seat whose ring is dispatched.  There is NO turn
; arbiter here -- both seats replay every tick.  LS_VCALL passes VD_CTRL as
; the handler's controller index, and unlike Bowling that is load-bearing:
; the shared action body at $587D branches on it ($5886 TSTR R1) to pick
; $011F/MOB $031D versus $0120/MOB $0335.  VD_CTRL tracks VD_SIDE.
; LS_* names are kept verbatim from the Baseball engine.

; ---------------------------------------------------------------------------
; VIRT_CAPTURE -- fill the per-tick input rings for tick T+d (d = DELAY_EN).
; Local modes: left pad -> seat 0, right pad -> seat 1 (NET_COUNT = 2);
; seats 2/3 stay at their idle fill.  Sources: live EXEC cells, or the
; deterministic script+fuzz (SPIKE_SCRIPT), or the recorded table
; (SPIKE_REPLAY).
; ---------------------------------------------------------------------------
VIRT_CAPTURE:
        PSHR    R5
        MVI     TICK_HI, R1
        SWAP    R1,     1
        ADD     TICK_LO, R1
        ADD     DELAY_EN, R1            ; R1 = T + d
    IF SPIKE_REPLAY <> 0
        ; rings fed from the recorded stream, 4 cells per tick; idle once
        ; the table is exhausted
        MOVR    R1,     R2
        ANDI    #$FF,   R1              ; ring slot
        CMPI    #REPLAY_LEN, R2
        BLT     @@vr_tbl
        MVII    #$40,   R0              ; idle decoded, no keypad
        MOVR    R1,     R3
        ADDI    #SEAT_RING, R3
        MVO@    R0,     R3
        ADDI    #$100,  R3
        DECR    R3
        MVO@    R0,     R3
        CLRR    R0
        MOVR    R1,     R3
        ADDI    #SEAT_KP, R3
        MVO@    R0,     R3
        ADDI    #$100,  R3
        DECR    R3
        MVO@    R0,     R3
        PULR    R7
@@vr_tbl:
        SLL     R2,     2
        ADDI    #REPLAY_TBL, R2
        MOVR    R2,     R4
        MVI@    R4,     R0              ; seat 0 decoded
        MOVR    R1,     R3
        ADDI    #SEAT_RING, R3
        MVO@    R0,     R3
        MVI@    R4,     R0              ; seat 1 decoded
        MOVR    R1,     R3
        ADDI    #SEAT_RING + $100, R3
        MVO@    R0,     R3
        MVI@    R4,     R0              ; seat 0 keypad
        MOVR    R1,     R3
        ADDI    #SEAT_KP, R3
        MVO@    R0,     R3
        MVI@    R4,     R0              ; seat 1 keypad
        MOVR    R1,     R3
        ADDI    #SEAT_KP + $100, R3
        MVO@    R0,     R3
        PULR    R7
    ENDI
    IF (SPIKE_REPLAY = 0) AND (SPIKE_SCRIPT <> 0)
        ; Scripted demo first: kick off, run both teams, work the action
        ; buttons and answer the period-over key-3 prompt -- then hand over
        ; to the masked fuzz.  Fuzz alone cannot start this cart: it sits
        ; in the kickoff hold until a fresh disc event arrives, and it can
        ; NEVER leave period-over, whose only exit is a keypad 3 that a
        ; $3F-masked disc stream cannot produce (§7.25).
        PSHR    R1
        JSR     R5,     SCR_STEP        ; R2 = row addr, 0 when done
        PULR    R1
        ANDI    #$FF,   R1              ; ring slot
        TSTR    R2
        BEQ     @@vf_fz
        MOVR    R2,     R4
        INCR    R4                      ; row: nticks, dec0, dec1, kp0, kp1
        MOVR    R1,     R3
        ADDI    #SEAT_RING, R3
        MVI@    R4,     R0
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_RING + $100, R3
        MVI@    R4,     R0
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_KP, R3
        MVI@    R4,     R0
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_KP + $100, R3
        MVI@    R4,     R0
        MVO@    R0,     R3
        PULR    R7
@@vf_fz:
        ; deterministic fuzz: advance the PRNG every 8th tick, write the
        ; held pair every tick (the rings must be filled per tick)
        MVI     TICK_LO, R0
        ANDI    #7,     R0
        BNEQ    @@vf_hold
        MVI     SLF_HI, R0
        SWAP    R0,     1
        ADD     SLF_LO, R0
        SLLC    R0,     1
        ADCR    R0                      ; 16-bit rotate left
        ADDI    #$6D2B, R0
        MVO     R0,     SLF_LO
        SWAP    R0,     1
        MVO     R0,     SLF_HI
@@vf_hold:
        ; dec values masked to $3F: disc-space chaos only (PORTING.md
        ; §5.5).  Keypad/menu paths are covered by the deterministic
        ; script above, where they are reproducible.
        MOVR    R1,     R3
        ADDI    #SEAT_RING, R3
        MVI     SLF_LO, R0
        ANDI    #$3F,   R0
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_RING + $100, R3
        MVI     SLF_HI, R0
        ANDI    #$3F,   R0
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_KP, R3
        CLRR    R0                      ; fuzz has no keypad stream
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_KP + $100, R3
        MVO@    R0,     R3
        PULR    R7
    ENDI
    IF (SPIKE_REPLAY = 0) AND (SPIKE_SCRIPT = 0)
        ; live pads: left -> seat 0, right -> seat 1
        ANDI    #$FF,   R1              ; ring slot
        MOVR    R1,     R3
        ADDI    #SEAT_RING, R3
        MVI     EXEC_IN_L, R0
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_RING + $100, R3
        MVI     EXEC_IN_R, R0
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_KP, R3
        MVI     EXEC_KP_L, R0
        MVO@    R0,     R3
        MOVR    R1,     R3
        ADDI    #SEAT_KP + $100, R3
        MVI     EXEC_KP_R, R0
        MVO@    R0,     R3
        PULR    R7
    ENDI

; ---------------------------------------------------------------------------
; SCR_STEP -- demo-script sequencer, one call per tick.  Returns R2 = the
; current row address (points at its nticks word), or 0 once the script is
; exhausted.  Clobbers R0/R1/R4.  Shared by VIRT_CAPTURE (local spikes) and
; the NET_FUZZ rig path in lockstep.asm.
; ---------------------------------------------------------------------------
    IF (SPIKE_SCRIPT <> 0) OR (NET_FUZZ <> 0)
SCR_STEP:
        MVI     SCR_IDX, R2
        CMPI    #$FF,   R2
        BEQ     @@ss_done
        ADDI    #SCRIPT_TBL, R2
        MOVR    R2,     R4
        MVI@    R4,     R0              ; nticks for this row
        MVI     SCR_CNT, R1
        INCR    R1
        CMPR    R0,     R1
        BLT     @@ss_st
        CLRR    R1
        MVI     SCR_IDX, R0
        ADDI    #5,     R0
        MVO     R0,     SCR_IDX
        ADDI    #SCRIPT_TBL, R0
        MOVR    R0,     R4
        MVI@    R4,     R0              ; peek next row; 0 = script done
        TSTR    R0
        BNEQ    @@ss_st
        MVII    #$FF,   R0
        MVO     R0,     SCR_IDX
@@ss_st:
        MVO     R1,     SCR_CNT
        MOVR    R5,     R7
@@ss_done:
        CLRR    R2
        MOVR    R5,     R7

; Demo script for Sea Battle.  Column dec0/kp0 = seat 0 (left pad, $011F/
; $0121, MOB $031D); dec1/kp1 = seat 1 (right pad, $0120/$0122, MOB $0335).
; Both columns are live every tick -- L_539B is called with R1=0 then R1=1
; unconditionally, no turn arbiter (spikes/NOTES.md M2 #6).
;
; ** MEASURED AT THE LIVE SCAN (M4), not extrapolated -- PORTING.md §5.5. **
; Forced raw ACTIVE-LOW bytes at `b 1527`/`b 152E`, held 6 scans then
; released, on the hook build (SPIKE_VIRT=0, real dispatch), and confirmed
; the full launch sequence end to end via live memory dumps:
;
;   raw $7E key 1 -> decoded $011F/$0120 = $81 (event value 1, EXEC-
;       universal keypad encoding, confirmed identical to every sibling
;       port's table)
;   raw $D7 ENTER -> decoded = $8B (event value 11)
;   idle -> $40
;
; Keypad DIGIT presses dispatch through the SAME cell/slot as disc events
; (bit 7 set = keypad, per LS_VDISPATCH's generic decode) -- NOT through
; the kp0/kp1 columns, which are reserved for the action-button class
; field ($0121/$0122, values 1-3) used only in the BATTLE phase (§ below).
;
; CONFIRMED SEQUENCE (live dumps, both seats, this session):
;   fresh key "1" while $0164==1 and the selected fleet is not at sea ->
;     $5439's handler adds one ship of type 0 to the fleet: fleet state
;     cell ($017D+4*seat+fleet) goes 0 -> 1, and the matching inventory
;     nibble in SB_INVENTORY decrements (measured: seat0 $01B5 $0011 ->
;     $0001, hi nibble; seat1 mirrors on the lo nibble)
;   fresh ENTER with >=1 ship assigned and the fleet not yet at sea ->
;     $5520's handler sets bit 2 (at sea) and writes the fleet's home-port
;     map position from L_55B7 ($105E for seat 0, $821E for seat 1,
;     confirmed by dis1600, not just observed): fleet state 1 -> 5
;
; This is the ONLY way to get real gameplay running on this cart -- the
; boot state (phase 1, MAP) is otherwise near-static, and masked $3F
; disc-only fuzz can never produce a keypad digit or ENTER (§5.5/§7.25).
;
; Coverage this script reaches, in order:
;   1. settle in the boot/map-idle state ($0164 == 1, no fleet at sea)
;   2. seat 0 launches a fleet (confirmed: SB_INVENTORY changes,
;      SB_FLEET_STATE bit 2 sets) -- the strongest destination-phase
;      signal on this cart (spikes/NOTES.md M3 §11)
;   3. seat 1 launches a fleet, symmetrically
;   4. both launched fleets driven toward each other via sustained disc
;      movement, exercising the map-phase movement path this session
;      already confirmed lands in SHADOW_CTRL/SHADOW_CTRL_R
;   5. hand over to the masked fuzz
;
; NOT YET REACHED BY THIS SCRIPT: the tactical battle phase ($0164==5),
; which needs the two fleets to actually collide on the map -- map scale
; and fleet speed were not measured this session, so the movement rows
; below are a best-effort diagonal converge, not a proven collision. If
; battle is never reached, `check_dest_phase.py`'s SB_FLEET_STATE
; assertion still passes (a fleet WAS launched); tightening further to
; require phase 5 is future work once collision is confirmed.
SCRIPT_TBL:
        DECLE   20, $40, $40, 0, 0      ; settle at boot (phase 1, map)
        ; --- seat 0: add a ship (key 1), then launch (ENTER) ---
        DECLE   3,  $81, $40, 0, 0
        DECLE   3,  $40, $40, 0, 0
        DECLE   3,  $8B, $40, 0, 0
        DECLE   4,  $40, $40, 0, 0
        ; --- seat 1: add a ship (key 1), then launch (ENTER) ---
        DECLE   3,  $40, $81, 0, 0
        DECLE   3,  $40, $40, 0, 0
        DECLE   3,  $40, $8B, 0, 0
        DECLE   4,  $40, $40, 0, 0
        ; --- both fleets launched at their home ports ($105E seat 0,
        ; $821E seat 1 -- far apart on both axes).  Drive them toward
        ; each other: seat 0 needs +X/-Y, seat 1 needs -X/+Y.  Alternate
        ; axes since this is a single selected fleet per seat, not a
        ; true diagonal disc position.
        DECLE   10, $0C, $00, 0, 0      ; seat0 east, seat1 west
        DECLE   10, $08, $04, 0, 0      ; seat0 south, seat1 north
        DECLE   10, $0C, $00, 0, 0
        DECLE   10, $08, $04, 0, 0
        DECLE   10, $0C, $00, 0, 0
        DECLE   10, $08, $04, 0, 0
        DECLE   10, $0C, $00, 0, 0
        DECLE   10, $08, $04, 0, 0
        DECLE   20, $40, $40, 0, 0      ; let AI/contact scans catch up
        DECLE   0                       ; done -> SLF fuzz from here
    ENDI

; ---------------------------------------------------------------------------
; DANCE_SETTLE -- wait out the cart's scroll ISR before taking over the
; display (PORTING.md §7.10).
;
; Soccer installs its own ISR body ($55EF, from $55DE) on every 20 Hz tick
; to shift BACKTAB rows and write the STIC scroll delay, and the body
; restores the saved EXEC vector itself at $561D.  The install site is
; single and the mainline waits for completion inside L_55B6, so the dance
; cannot nest and the wait below is short.  $0101 is $55 while the cart's
; body is installed and $11 otherwise, so the test is unambiguous.
;
; The forced restore is the belt-and-braces for a terminal freeze landing
; in that window: a stranded $55EF would shift BACKTAB rows over the
; peer-left screen every frame, forever -- Auto Racing's §7.10 failure.
; ---------------------------------------------------------------------------
DANCE_SETTLE:
        PSHR    R5
        MVII    #6000,  R1
@@ds_l: MVI     $101,   R0
        CMPI    #SC_ISR_BODY SHR 8, R0
        BNEQ    @@ds_done
        DECR    R1
        BNEQ    @@ds_l
        DIS
        MVII    #EXEC_ISR_DEF AND $FF, R0
        MVO     R0,     $100
        MVII    #EXEC_ISR_DEF SHR 8, R0
        MVO     R0,     $101
        EIS
@@ds_done:
        PULR    R7

; ---------------------------------------------------------------------------
; REC_CAPTURE -- record build: log the live EXEC cells for this tick into
; $9000 + T*4 ([L dec, R dec, L kp, R kp]); 768 ticks = 38 s at 20 Hz.
; Dump with `m 9000 C00` and feed tools/mk_replay.py.
; ---------------------------------------------------------------------------
REC_CAPTURE:
        MVI     TICK_HI, R1
        SWAP    R1,     1
        ADD     TICK_LO, R1
        CMPI    #768,   R1
        BGE     @@rec_done
        SLL     R1,     2
        ADDI    #$9000, R1
        MOVR    R1,     R4
        MVI     EXEC_IN_L, R0
        MVO@    R0,     R4
        MVI     EXEC_IN_R, R0
        MVO@    R0,     R4
        MVI     EXEC_KP_L, R0
        MVO@    R0,     R4
        MVI     EXEC_KP_R, R0
        MVO@    R0,     R4
@@rec_done:
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; LS_VDISPATCH -- virtual input-event dispatch for one SEAT (VD_SIDE =
; 0-3) at the current tick, replicating the EXEC scan's dispatch
; semantics ($15AC-$15DC) over the exchanged cell streams:
;   keypad cell k != 0 (values 1-3): call handler[k*2+2] with R0 = 1 on a
;     change, else 0 (the EXEC re-fires held keypad every scan)
;   $011F-cell fresh event (changed, bit 6 clear): value >= $80 -> keypad
;     handler [2] with R0 = k; disc (0-15) -> handler [0] with R0 = dir
; Handlers are entered like the EXEC does it: R1 = VD_CTRL (the
; controller index -- constant 0 on this cart, every handler ignores it),
; R0 = event value, return via R5.
; Fidelity note: an imperfect replication differs IDENTICALLY on every
; console (same input streams), so it can affect feel but never sync.
; ---------------------------------------------------------------------------
LS_VDISPATCH:
        PSHR    R5
        ; ring base for this seat: SEAT_RING + VD_SIDE * $100
        MVI     VD_SIDE, R2
        SWAP    R2,     1
        ADDI    #SEAT_RING, R2
        MVI     TICK_LO, R1
        MOVR    R1,     R3
        ADDR    R2,     R3
        MVI@    R3,     R0
        MVO     R0,     VD_CUR
        DECR    R3
        MVI     TICK_LO, R0
        TSTR    R0
        BNEQ    @@vd_p1
        ADDI    #256,   R3              ; tick 0: prev slot wraps
@@vd_p1:
        MVI@    R3,     R0
        MVO     R0,     VD_PREV
        ADDI    #SEAT_KP-SEAT_RING, R2  ; matching KP page (same delta/seat)
        MVI     TICK_LO, R1
        MOVR    R1,     R3
        ADDR    R2,     R3
        MVI@    R3,     R0
        MVO     R0,     VD_KP
        DECR    R3
        MVI     TICK_LO, R0
        TSTR    R0
        BNEQ    @@vd_p2
        ADDI    #256,   R3
@@vd_p2:
        MVI@    R3,     R0
        MVO     R0,     VD_KPPRE
        ; ---- action-button release (stock: slot cleared -> R0 = -1)
        MVI     VD_KPPRE, R0
        TSTR    R0
        BEQ     @@vd_kp
        CMPI    #3,     R0
        BGT     @@vd_kp
        CMP     VD_KP,  R0
        BEQ     @@vd_kp                 ; unchanged: no release
        SLL     R0,     1
        ADDI    #2,     R0
        MVO     R0,     VD_TMP
        CLRR    R0
        DECR    R0                      ; R0 = -1
        JSR     R5,     LS_VCALL
@@vd_kp:
        ; ---- action-button press / held re-fire (classes 4/6/8 =
        ; top/left/right; the $0121-family cell holds 1-3 while held)
        MVI     VD_KP,  R0
        TSTR    R0
        BEQ     @@vd_disc
        CMPI    #3,     R0
        BGT     @@vd_disc               ; sanity: stored class is 1-3
        SLL     R0,     1
        ADDI    #2,     R0              ; slot = kp*2 + 2
        MVO     R0,     VD_TMP
        MVI     VD_KP,  R0
        CMP     VD_KPPRE, R0
        BEQ     @@vd_kheld
        MVII    #1,     R0              ; fresh press
        B       @@vd_kcall
@@vd_kheld:
        CLRR    R0                      ; held re-fire
@@vd_kcall:
        JSR     R5,     LS_VCALL
@@vd_disc:
        ; ---- fresh $011F event (changed, bit 6 clear): keypad ($80|k) ->
        ; slot 2 with R0 = k; disc (0-15) -> slot 0 with R0 = direction
        MVI     VD_CUR, R0
        CMP     VD_PREV, R0
        BEQ     @@vd_done
        ANDI    #$40,   R0
        BNEQ    @@vd_settle
        MVI     VD_CUR, R0
        ANDI    #$80,   R0
        BEQ     @@vd_d0
        MVII    #2,     R0              ; keypad -> slot 2
        B       @@vd_ds
@@vd_d0:
        CLRR    R0                      ; disc -> slot 0
@@vd_ds:
        MVO     R0,     VD_TMP
        MVI     VD_CUR, R0
        ANDI    #$7F,   R0
        JSR     R5,     LS_VCALL
        B       @@vd_done
@@vd_settle:
        ; ---- disc settle: the scan's held path ($15AC) fires slot 0 with
        ; R0 = -1 exactly once, on the pass after a disc event.  Kept: it
        ; replicates the stock scan, and an unused event through a null
        ; slot is free.  Keypad release marks $C0|k (bit 7 set) and
        ; dispatches nothing -- excluded here.
        MVI     VD_CUR, R0
        ANDI    #$80,   R0
        BNEQ    @@vd_done
        CLRR    R0
        MVO     R0,     VD_TMP          ; slot 0
        CLRR    R0
        DECR    R0                      ; R0 = -1
        JSR     R5,     LS_VCALL
@@vd_done:
        PULR    R7

; LS_TBL_ADOPT -- if $035D holds anything but our null table, park it in
; GAME_TBL (an install happened since we last nulled).
LS_TBL_ADOPT:
        MVI     $35D,   R0
        CMPI    #NET_NULL_TBL+4, R0
        BEQ     @@ta_out
        MVO     R0,     GAME_TBL_LO
        SWAP    R0,     1
        MVO     R0,     GAME_TBL_HI
@@ta_out:
        MOVR    R5,     R7

; LS_VCALL -- invoke game handler [live table + VD_TMP] with event value
; R0, controller index = VD_CTRL.  No-op on a null entry.  Reads $035D
; directly so a handler-installed table applies to subsequent events in
; the same tick, exactly as the real scan would behave.
LS_VCALL:
        PSHR    R5
        PSHR    R0
        MVI     $35D,   R1
        TSTR    R1
        BEQ     @@vc_skip
        ADD     VD_TMP, R1
        MOVR    R1,     R4
        MVI@    R4,     R2
        ANDI    #$FF,   R2
        MVI@    R4,     R1
        SWAP    R1,     1
        ANDI    #$FF00, R1
        ADDR    R1,     R2              ; SDBD-equivalent pointer read
        TSTR    R2
        BEQ     @@vc_skip
        MVI     VD_CTRL, R1
        PULR    R0
        MVII    #@@vc_ret, R5
        MOVR    R2,     R7              ; enter the handler, EXEC-style
@@vc_ret:
        PULR    R7
@@vc_skip:
        PULR    R0
        PULR    R7

; LS_RING_INIT -- idle-fill all eight seat ring pages: decoded cells
; ($8400-$87FF) to $40, keypad cells ($8800-$8BFF) to 0.
LS_RING_INIT:
        PSHR    R5
        MVII    #SEAT_RING, R4
        MVII    #1024,  R1
        MVII    #$40,   R0
@@ri_a: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@ri_a
        MVII    #1024,  R1
        CLRR    R0
@@ri_b: MVO@    R0,     R4              ; R4 continues into SEAT_KP pages
        DECR    R1
        BNEQ    @@ri_b
        PULR    R7
