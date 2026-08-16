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

C_BLACK         EQU     0               ; dimmed / unavailable
C_BLUE          EQU     1               ; home team (1978 manual p.4, and the
C_RED           EQU     2               ;  colours the scoreboard uses)
C_YELLOW        EQU     6
C_WHITE         EQU     7

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
