; Minimal BACKTAB text output for the netplay screens (pre-game context:
; EXEC main loop not running, ISR alive, color-stack mode).  GROM font,
; card = (ascii - 32) << 3 | color.
;
; UI_COLOR selects the foreground colour for the next print; UI_CLS resets it
; to white so every screen starts from a known state.
;
; Colours 0-7 ONLY -- bits 0-2 of the card word.  The upper half of the
; palette needs bits 12/13, and in this game's colour-stack setup setting
; bit 13 turns the rest of the screen into black-on-magenta (tried it:
; the whole list area went).  The game itself never leaves 0-7 either --
; its scoreboard paints VSTR red (2) and HOME blue (1).

; Colour-stack foreground is the card word's low three bits, so only the
; eight primaries are addressable as text colour.
C_BLACK         EQU     0               ; dimmed / unavailable
C_BLUE          EQU     1
C_RED           EQU     2
C_TAN           EQU     3
C_DKGREEN       EQU     4               ; the pitch colour (header $500F-$5013)
C_GREEN         EQU     5
C_YELLOW        EQU     6
C_WHITE         EQU     7

; Seat -> team colour is set at M2b from what the cart actually paints:
; L_50CD XORs $0006 into seat 0's three MOB records from $031D and $0017
; into seat 1's from $0335.  SEAT_CLR_TBL in session.asm must match what is
; on screen -- verify it there, do not infer it here.

; ---------------------------------------------------------------------------
; UI_DISPLAY_NORMALIZE -- make the screen safe for a full-screen text
; message.  Terminal and session screens ONLY.
;
; RS_DISPLAY_RESET is the wrong routine for this: it is the SCROLLING-cart
; form (§7.5) and deliberately leaves STIC $0030/$0031 alone, because during
; play the scroll is live sim state that the cart's ISR body repaints from
; $015F every tick.  It also reasserts the colour stack from the header,
; and this cart's header is $04 x5 -- the PITCH GREEN.  Using it before a
; text screen therefore leaves white text on a green field, shifted
; horizontally by whatever the last scroll value happened to be.
;
; Here the sim is dead and DANCE_SETTLE has already forced the EXEC default
; ISR back, so nothing will repaint any of it: we can zero the scroll and
; black the stack safely.  The MOB shadow is collapsed too, so the players
; and the ball do not float over the message.
;
; Clobbers R0, R1, R4.
; ---------------------------------------------------------------------------
UI_DISPLAY_NORMALIZE:
        PSHR    R5
        MVI     $500D,  R0
        MVO     R0,     $0032           ; border extension, from the header
        CLRR    R0
        MVO     R0,     $0030           ; horizontal scroll delay off
        MVO     R0,     $0031           ; vertical too, for good measure
        MVII    #$0028, R4              ; colour stack 0-3 + border -> black
        MVII    #5,     R1
@@dn_c: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@dn_c
        MVII    #$0300, R4              ; collapse the EXEC MOB shadow
        MVII    #$18,   R1
@@dn_m: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@dn_m
        PULR    R7

; UI_CLS -- blank the whole BACKTAB and reset the text colour to white.
UI_CLS:
        PSHR    R5
        MVII    #C_WHITE, R0
        MVO     R0,     UI_COLOR
        MVII    #$200,  R4
        MVII    #240,   R1
        CLRR    R0
@@ui_cl:
        MVO@    R0,     R4
        DECR    R1
        BNEQ    @@ui_cl
        PULR    R7

; UI_PRINT -- write NUL-terminated string at R1 (ROM or 8-bit RAM) to
; BACKTAB offset R0 (0-239) in UI_COLOR.  Clobbers R0,R1,R2,R4,R5.
UI_PRINT:
        PSHR    R5
        MOVR    R0,     R4
        ADDI    #$200,  R4
        MOVR    R1,     R5
        MVI     UI_COLOR, R1
        ANDI    #$07,   R1              ; R1 = the card word's colour bits
@@ui_pr:
        MVI@    R5,     R0
        TSTR    R0
        BEQ     @@ui_pd
        SUBI    #32,    R0
        SLL     R0,     2
        SLL     R0,     1
        XORR    R1,     R0
        MVO@    R0,     R4
        B       @@ui_pr
@@ui_pd:
        PULR    R7

; UI_PRINTN -- like UI_PRINT but at most R2 chars (for fixed-width RAM
; fields that may lack a NUL).  Clobbers R0,R1,R2,R4,R5.
UI_PRINTN:
        PSHR    R5
        MOVR    R0,     R4
        ADDI    #$200,  R4
        MOVR    R1,     R5
        MVI     UI_COLOR, R1
        ANDI    #$07,   R1              ; R1 = the card word's colour bits
@@ui_nl:
        TSTR    R2
        BEQ     @@ui_nd
        MVI@    R5,     R0
        TSTR    R0
        BEQ     @@ui_nd
        SUBI    #32,    R0
        SLL     R0,     2
        SLL     R0,     1
        XORR    R1,     R0
        MVO@    R0,     R4
        DECR    R2
        B       @@ui_nl
@@ui_nd:
        PULR    R7

; UI_HEX2 -- print R0 (byte) as two hex digits at BACKTAB offset R1.
; Clobbers R0,R2,R4.
UI_HEX2:
        PSHR    R5
        MOVR    R1,     R4
        ADDI    #$200,  R4
        ANDI    #$FF,   R0
        MOVR    R0,     R2
        SLR     R2,     2
        SLR     R2,     2               ; high nibble
        CMPI    #10,    R2
        BLT     @@ui_h1
        ADDI    #7,     R2
@@ui_h1:
        ADDI    #16,    R2              ; '0' - 32
        SLL     R2,     2
        SLL     R2,     1
        XORI    #C_YELLOW, R2
        MVO@    R2,     R4
        MOVR    R0,     R2
        ANDI    #$0F,   R2
        CMPI    #10,    R2
        BLT     @@ui_h2
        ADDI    #7,     R2
@@ui_h2:
        ADDI    #16,    R2
        SLL     R2,     2
        SLL     R2,     1
        XORI    #C_YELLOW, R2
        MVO@    R2,     R4
        PULR    R7
