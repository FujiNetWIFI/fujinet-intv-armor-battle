; Netcode hook segment.
;
; The cart header's timer-table pointer ($5002) is patched to NEW_TIMER_TBL.
; Entry 0 must stay the EXEC music note timer verbatim: the music system
; re-arms "the first table entry" through the header pointer with per-note
; durations (countdown slot $0125, EXEC-managed real-frame timing) -- it is
; presentation-only and deliberately NOT drawn into sim-tick space.
; Entry 1 is our master dispatcher, every pass.  Football's original table
; had TWO game entries -- $56EF every 15 (the game clock) listed FIRST,
; then $5034 every pass (the 20 Hz tick) -- so the dispatcher steps the
; virtualized /15 countdown (SLOW_CNT, sim state) BEFORE firing the fast
; tick, preserving the EXEC's table walk order on passes where both fire,
; and a lockstep stall freezes both cadences atomically.

        ORG     $6000

NEW_TIMER_TBL:
        DECLE   X_MUSIC_TICK AND $FF, X_MUSIC_TICK SHR 8
        DECLE   $01, $80                ; interval $8001: stopped, one-shot
        DECLE   MASTER_TICK AND $FF, MASTER_TICK SHR 8
        DECLE   $01, $00                ; every pass, always armed
        DECLE   $00, $00                ; terminator

; ---------------------------------------------------------------------------
; NET_START -- patched start-of-game vector ($5004).  Runs before the EXEC
; main loop starts (the EXEC jumps here with R5 = $108F), so netcode RAM is
; initialized before the first MASTER_TICK.  Falls through to the original
; start routine, preserving R5.
; ---------------------------------------------------------------------------
NET_START:
        PSHR    R5                      ; EXEC main-loop return -- JSRs below
                                        ; clobber R5, and FB_START returns
                                        ; through it into the main loop
        MVII    #NET_RAM, R4
        MVII    #NET_RAM_SIZE, R1
        CLRR    R0
@@zero: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@zero
        MVII    #SPIKE_DELAY, R0        ; virt-dispatch delay depth (spike knob)
        MVO     R0,     DELAY_EN
        MVII    #15,    R0              ; slow-tick countdown, as the EXEC
        MVO     R0,     SLOW_CNT        ;  would arm entry 1's interval
        ; canonical game RNG seed -- in netplay this comes from START;
        ; fixed for now so identical runs are identical by construction
        MVII    #$34,   R0
        MVO     R0,     RNG_LO
        MVII    #$12,   R0
        MVO     R0,     RNG_HI
        MVII    #$77,   R0              ; scripted-input PRNG seed (spike c)
        MVO     R0,     SLF_LO
        MVII    #$C3,   R0
        MVO     R0,     SLF_HI
        MVII    #$34,   R0              ; prev-RNG breadcrumb baseline
        MVO     R0,     RNGP_LO
        MVII    #$12,   R0
        MVO     R0,     RNGP_HI
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
        J       FB_START

; NET_NULL_TBL: handed to the EXEC scan (via $035D) while dispatch is
; virtualized so its event dispatch resolves null pointers and never calls
; game code from real local input.  Zeros on both sides of the base cover
; negative slot indexes.
NET_NULL_TBL:
        DECLE   0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        DECLE   0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; ---------------------------------------------------------------------------
; MASTER_TICK -- timer entry 1, dispatched by the EXEC every main-loop pass.
; Every pass is a game tick (Football's fast entry had interval 1).
; May clobber R0-R3 (the EXEC dispatch preserves R4/R5 and re-reads its walk
; state per entry).  Returns via the R5 the dispatcher handed us.
; ---------------------------------------------------------------------------
MASTER_TICK:
        PSHR    R5
    IF STALL_N <> 0
        ; Stall injector (spike c): every 64th pass, busy-spin ~STALL_N
        ; frames INSIDE the dispatch (mainline).  The ISR keeps firing but
        ; $0102 sits at 0 mid-pass, so it takes its skip path: display and
        ; PLAY_NOTE continue, object motion and the rest of the pass freeze.
        ; This is exactly how a network-wait stall behaves; a skip-dispatch
        ; stall is WRONG (object motion would run on).  Stalling here, at
        ; the tick boundary, is safe w.r.t. the game's VBLANK display dance:
        ; the dance completes inside the tick and the ISR vector is the EXEC
        ; default again by the time we run (spikes/NOTES.md, M2 finding 2).
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
        JSR     R5,     UPDATE_SHADOW   ; raw + decoded pass-through
    IF SPIKE_RECORD <> 0
        JSR     R5,     REC_CAPTURE     ; log the live cells for this tick
    ENDI
    IF SPIKE_VIRT <> 0
        ; Virtualized local dispatch: capture (or script/replay) both pads'
        ; cells for tick T+d, feed the polled shadow pair from the rings at
        ; tick T (Football POLLS as well as dispatches -- the hybrid model),
        ; run the tick with the game's real handler table installed, replay
        ; tick T's events through it, then null $035D so the real scan
        ; can't reach game code.  With d = 0 this must feel stock (gate:
        ; make run-virt).
        JSR     R5,     VIRT_CAPTURE
        JSR     R5,     SHADOW_FROM_RINGS
        JSR     R5,     LS_TBL_ADOPT
        MVI     GAME_TBL_HI, R1
        SWAP    R1,     1
        ADD     GAME_TBL_LO, R1
        BEQ     @@mt_no_tbl
        MVO     R1,     $35D
@@mt_no_tbl:
    ENDI
        JSR     R5,     FB_SLOW_STEP    ; slow entry is FIRST in the table
        JSR     R5,     FB_TICK_FAST
    IF SPIKE_VIRT <> 0
        CLRR    R0
        MVO     R0,     VD_SIDE
        JSR     R5,     LS_VDISPATCH    ; side 0 = left pad
        MVII    #1,     R0
        MVO     R0,     VD_SIDE
        JSR     R5,     LS_VDISPATCH    ; side 1 = right pad
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

; FB_SLOW_STEP -- the virtualized slow game entry (original table entry 1:
; $56EF, the game clock, every 15 passes).  Football's table lists it
; BEFORE the fast entry, so the dispatcher calls slow-then-fast to match
; the EXEC's walk order on the passes where both fire (the opposite of
; Auto Racing).  Shared by the local path and the lockstep path; because
; it only steps inside the dispatch, the countdown freezes coherently
; during stalls.
FB_SLOW_STEP:
        PSHR    R5
        MVI     SLOW_CNT, R0
        DECR    R0
        MVO     R0,     SLOW_CNT
        BNEQ    @@no_slow
        MVII    #15,    R0
        MVO     R0,     SLOW_CNT
        JSR     R5,     FB_TICK_SLOW
@@no_slow:
        PULR    R7

; ---------------------------------------------------------------------------
; NET_RAND1 / NET_RAND2 -- canonical-RNG wrappers for the game's own three
; RAND call sites.  The EXEC sound engine advances the shared LFSR at $035E
; from ISR context every frame while noise SFX play, so game logic must not
; read $035E directly: swap the canonical (sim-space) value in, call the
; EXEC routine with interrupts off, swap the advanced value back out.
; Preserves R1/R2 like the underlying EXEC routines; result in R0.
; ---------------------------------------------------------------------------
NET_RAND1:
        PSHR    R5
        DIS
        JSR     R5,     @@swap_in
        JSR     R5,     X_RAND1
        B       @@swap_out

NET_RAND2:
        PSHR    R5
        DIS
        JSR     R5,     @@swap_in
        JSR     R5,     X_RAND2
@@swap_out:
        PSHR    R1
        MVI     EXEC_RNG, R1
        MVO     R1,     RNG_LO
        SWAP    R1,     1
        MVO     R1,     RNG_HI
        PULR    R1
        EIS
        PULR    R7

@@swap_in:
        PSHR    R1
        PSHR    R2
        MVI     RNG_HI, R1
        SWAP    R1,     1
        MVI     RNG_LO, R2
        ADDR    R2,     R1
        MVO     R1,     EXEC_RNG
        PULR    R2
        PULR    R1
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; UPDATE_SHADOW -- feed both shadow surfaces (the hybrid model):
;  - raw-port latch cells, pass-through from the live ports in every mode.
;    The latch (L_5722, inside the fast tick) stores their complement into
;    the EXEC scan's edge cells $0123/$0124; keeping it live makes the real
;    scan behave exactly as stock, which is what gives the captured $011F
;    stream its stock fresh/held flavours.
;  - the polled decoded pair, pass-through from the live EXEC cells.  The
;    game's computed-index read at $5636 consumes these; a tick-top copy
;    hands it exactly the previous pass's scan output, which is what the
;    stock read saw (dispatch runs before the scan in each pass).  Virt and
;    lockstep modes overwrite the pair afterwards (SHADOW_FROM_RINGS / the
;    LS_PASS role feed).
; ---------------------------------------------------------------------------
UPDATE_SHADOW:
        MVI     $1FE,   R0
        MVO     R0,     SHADOW_RAW_R
        MVI     $1FF,   R0
        MVO     R0,     SHADOW_RAW_L
        MVI     EXEC_IN_L, R0
        MVO     R0,     SHADOW_CTRL
        MVI     EXEC_IN_R, R0
        MVO     R0,     SHADOW_CTRL_R
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; SHADOW_FROM_RINGS -- feed the polled shadow pair from the dispatch rings
; at the CURRENT tick (local virt modes: side 0 = LOC = left).  This is
; what makes the delayed/scripted/replayed polled stream agree with the
; dispatched event stream -- both read the same ring slot.  With d = 0 the
; slot holds this tick's live capture, so hook and virt stay bit-identical.
; Clobbers R0/R1/R3.
; ---------------------------------------------------------------------------
SHADOW_FROM_RINGS:
        MVI     TICK_LO, R1
        MOVR    R1,     R3
        ADDI    #LOC_RING, R3
        MVI@    R3,     R0
        MVO     R0,     SHADOW_CTRL
        MOVR    R1,     R3
        ADDI    #RMT_RING, R3
        MVI@    R3,     R0
        MVO     R0,     SHADOW_CTRL_R
        MOVR    R5,     R7
