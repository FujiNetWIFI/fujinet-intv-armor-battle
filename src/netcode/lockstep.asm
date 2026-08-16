; Lockstep netplay engine.  LS_PASS replaces MASTER_TICK's local body when
; NET_ACTIVE: one transport pump per pass, delay-based input exchange at
; game-tick cadence, sim gate on the remote input watermark, spin-stall with
; the ISR phase counter frozen (see spikes/NOTES.md for why).

LS_TIMEOUT      EQU     900             ; gate pump rounds before giving up

LS_PASS:
        PSHR    R5
        ; peer gone: terminal screen, sim stopped for good
        MVI     PEER_SCR, R0
        TSTR    R0
        BNEQ    @@ls_frz
        MVI     NET_DROPPED, R0
        TSTR    R0
        BNEQ    @@ls_gone
        ; resync hold: sim frozen, keep pumping (STATE frames arrive here)
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BEQ     @@ls_go0
        MVI     LS_FROZE, R0
        TSTR    R0
        BNEQ    @@ls_hf
        MVII    #1,     R0
        MVO     R0,     LS_FROZE
        DIS
        MVI     $102,   R0
        MVO     R0,     LS_SAVE102
        CLRR    R0
        MVO     R0,     $102
        EIS
@@ls_hf:
    IF NET_HUD <> 0
        MVI     HUD_HLD, R0
        CMPI    #$FF,   R0
        BEQ     @@ls_hh
        INCR    R0
        MVO     R0,     HUD_HLD
@@ls_hh:
    ENDI
        JSR     R5,     SES_PUMP
        MVI     RS_TO_LO, R0
        INCR    R0
        MVO     R0,     RS_TO_LO
        CMPI    #$100,  R0
        BNEQ    @@ls_hd
        MVI     RS_TO_HI, R0
        INCR    R0
        MVO     R0,     RS_TO_HI
        CMPI    #RS_HOLD_TMO SHR 8, R0
        BLT     @@ls_hd
        ; peer vanished mid-resync: give up (LS_PASS paints the screen)
        CLRR    R0
        MVO     R0,     PEER_WHY        ; we timed out, no clean goodbye
        MVII    #1,     R0
        MVO     R0,     NET_DROPPED
        CLRR    R0
        MVO     R0,     RESYNC_HOLD
        JSR     R5,     LS_IDLE_RMT
@@ls_hd:
        PULR    R7
@@ls_go0:
        ; Every pass is a game tick on this cart (fast entry interval 1).
        ; Transport pump, once per game tick.
        ; Every pump is a mailbox STATUS (plus a READ when bytes are waiting),
        ; and each transaction is a bus round trip the console spins through --
        ; the dominant cost in the pass.  The pump on the odd pass only ever
        ; mattered when the console had slack in hand, and slack is exactly
        ; when nothing is waiting on the read: the moment the sim actually
        ; needs a frame it enters the gate below, which pumps every round.
        JSR     R5,     SES_PUMP
        ; ---- game tick T is due ------------------------------------------
        ; capture local input (left controller) for tick T+d, send it
        MVI     TICK_HI, R1
        SWAP    R1,     1
        ADD     TICK_LO, R1             ; R1 = T
        MVI     NET_DELAY, R2
        ADDR    R1,     R2              ; R2 = T+d
    IF NET_FUZZ <> 0
        ; Rig builds: the demo script first -- the host plays the left
        ; column (defense at boot), the guest the right (offense picks a
        ; play, snaps, runs), so the two consoles complete one play
        ; together -- then pseudo-random input seeded per console from
        ; boot entropy.
        ; SCR_STEP clobbers R1/R2 -- and R2 here is T+d, the ring slot AND
        ; the tick the INPUT frame carries.  Losing it sent every fuzz-era
        ; input as "tick 0" (dropped as stale by the peer), which is how
        ; the first rig desynced at the first post-script CRC.
        PSHR    R2
        JSR     R5,     SCR_STEP        ; R2 = row addr, 0 when done
        MOVR    R2,     R4
        PULR    R2                      ; T+d restored
        TSTR    R4
        BEQ     @@lf_fz
        INCR    R4                      ; -> Ldec column
        ADD     NET_ROLE, R4            ; role 1 reads Rdec / Rkp
        MVI@    R4,     R0
        MVO     R0,     LS_TMPB
        INCR    R4                      ; skip the other side's dec
        MVI@    R4,     R0
        MVO     R0,     LS_TMPB2
        B       @@lf_done
@@lf_fz:
        MVI     TICK_LO, R0
        ANDI    #7,     R0
        BNEQ    @@lf_hold
        MVI     SLF_HI, R0
        SWAP    R0,     1
        ADD     SLF_LO, R0
        SLLC    R0,     1
        ADCR    R0
        ADDI    #$6D2B, R0
        MVO     R0,     SLF_LO
        SWAP    R0,     1
        MVO     R0,     SLF_HI
@@lf_hold:
        MVI     SLF_LO, R0
        ANDI    #$3F,   R0              ; disc-space only (no fuzz restarts)
        MVO     R0,     LS_TMPB
        CLRR    R0
        MVO     R0,     LS_TMPB2        ; fuzz has no keypad stream
@@lf_done:
    ELSE
        MVI     EXEC_IN_L, R0
        MVO     R0,     LS_TMPB
        MVI     EXEC_KP_L, R0           ; decoded keypad cell ($0121)
        MVO     R0,     LS_TMPB2
    ENDI
        MOVR    R2,     R3
        ANDI    #$FF,   R3
        ADDI    #LOC_RING, R3
        MVI     LS_TMPB, R0
        MVO@    R0,     R3
        ADDI    #LOC_KP-LOC_RING, R3
        MVI     LS_TMPB2, R0
        MVO@    R0,     R3
        ; INPUT frame: len=5, type, tick_lo, tick_hi, in11F, inKP
        MVII    #FN_TX, R5
        MVII    #5,     R0
        MVO@    R0,     R5
        MVII    #FT_INPUT, R0
        MVO@    R0,     R5
        MVO@    R2,     R5              ; lo (8-bit cell truncates)
        SWAP    R2,     1
        MVO@    R2,     R5              ; hi
        MVI     LS_TMPB, R0
        MVO@    R0,     R5
        MVI     LS_TMPB2, R0
        MVO@    R0,     R5
        MVII    #6,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        ; ---- gate: wait until remote watermark reaches T ------------------
@@ls_gate:
        MVI     NET_DROPPED, R0
        TSTR    R0
        BNEQ    @@ls_run                ; peer gone: play on vs idle inputs
        MVI     TICK_HI, R1
        SWAP    R1,     1
        ADD     TICK_LO, R1
        MVI     RMT_WM_HI, R0
        SWAP    R0,     1
        ADD     RMT_WM_LO, R0
        SUBR    R1,     R0              ; WM - T, wrap-safe small delta
        BMI     @@ls_stall
    IF NET_HUD <> 0
        ; slack: how many ticks of remote input we had in hand.  0 means the
        ; frame we needed had only just landed (or we spun for it) -- the sim
        ; is running at the network's pace, not the console's.
        CMPI    #16,    R0
        BLT     @@ls_lc
        MVII    #15,    R0
@@ls_lc:
        CMP     HUD_LEAD, R0
        BGE     @@ls_ld
        MVO     R0,     HUD_LEAD
@@ls_ld:
    ENDI
        B       @@ls_run
@@ls_stall:
    IF NET_HUD <> 0
        CLRR    R0
        MVO     R0,     HUD_LEAD        ; starving
        MVI     HUD_STL, R0
        CMPI    #$FF,   R0
        BEQ     @@ls_sh
        INCR    R0
        MVO     R0,     HUD_STL
@@ls_sh:
    ENDI
        ; stall: freeze ISR phases once, pump, bounded retry
        MVI     LS_FROZE, R0
        TSTR    R0
        BNEQ    @@ls_wf
        MVII    #1,     R0
        MVO     R0,     LS_FROZE
        DIS
        MVI     $102,   R0
        MVO     R0,     LS_SAVE102
        CLRR    R0
        MVO     R0,     $102
        EIS
@@ls_wf:
        JSR     R5,     SES_PUMP
        MVI     LS_WAITC_LO, R0
        INCR    R0
        MVO     R0,     LS_WAITC_LO
        CMPI    #$100,  R0
        BNEQ    @@ls_gate
        MVI     LS_WAITC_HI, R0
        INCR    R0
        MVO     R0,     LS_WAITC_HI
        CMPI    #LS_TIMEOUT SHR 8, R0
        BLT     @@ls_gate
        ; timed out: mark dropped, idle-fill the remote ring
        CLRR    R0
        MVO     R0,     PEER_WHY        ; we timed out, no clean goodbye
        MVII    #1,     R0
        MVO     R0,     NET_DROPPED
        JSR     R5,     LS_IDLE_RMT
        B       @@ls_gate
@@ls_run:
        ; unfreeze phases if we stalled
        MVI     LS_FROZE, R0
        TSTR    R0
        BEQ     @@ls_nf
        CLRR    R0
        MVO     R0,     LS_FROZE
        MVO     R0,     LS_WAITC_LO
        MVO     R0,     LS_WAITC_HI
        DIS
        MVI     LS_SAVE102, R0
        MVO     R0,     $102
        EIS
@@ls_nf:
        ; ---- raw-latch shadows: live pass-through (spikes/NOTES.md M2) ----
        ; The latch cells keep the real scan behaving stock so the captured
        ; $011F stream has stock fresh/held flavours.  (UPDATE_SHADOW also
        ; pass-through-feeds the polled pair; the role feed below overwrites
        ; it with the lockstep rings' values for this tick.)
        JSR     R5,     UPDATE_SHADOW
        ; ---- feed the polled shadow pair by role (the hybrid model) ------
        ; Football POLLS the decoded pair (computed-index read at $5636,
        ; patched to SHADOW_CTRL/_R) as well as dispatching.  Feed it from
        ; the same rings LS_VDISPATCH replays, at tick T: host = left seat
        ; (local -> SHADOW_CTRL), guest = right seat (swapped).  Register
        ; audit (PORTING.md §5.6): nothing is live in R0-R3 here -- the
        ; tick block below reloads R0/R1 from memory.
        MVI     TICK_LO, R3
        MOVR    R3,     R2
        ADDI    #LOC_RING, R2
        MVI@    R2,     R1              ; local delayed input
        ADDI    #RMT_RING-LOC_RING, R2
        MVI@    R2,     R2              ; remote input
        MVI     NET_ROLE, R0
        TSTR    R0
        BNEQ    @@ls_guest
        MVO     R1,     SHADOW_CTRL     ; host: local=left, remote=right
        MVO     R2,     SHADOW_CTRL_R
        B       @@ls_tick
@@ls_guest:
        MVO     R2,     SHADOW_CTRL     ; guest: remote=left, local=right
        MVO     R1,     SHADOW_CTRL_R
@@ls_tick:
        ; Handler-table swap, non-destructive: the game (and EXEC) install
        ; new tables from tick code AND from dispatched handlers, so adopt
        ; whatever is live before overwriting, run the tick + virtual
        ; dispatch with the REAL table installed (handlers may re-install
        ; mid-dispatch, stock-style), adopt again, then null it out so the
        ; real scan's dispatch stays inert until the next tick.
        JSR     R5,     LS_TBL_ADOPT
        MVI     GAME_TBL_HI, R1
        SWAP    R1,     1
        ADD     GAME_TBL_LO, R1
        BEQ     @@ls_no_tbl
        MVO     R1,     $35D
@@ls_no_tbl:
        JSR     R5,     FB_SLOW_STEP    ; virtualized entry 1 (/15), sim state
        JSR     R5,     FB_TICK_FAST    ; slow BEFORE fast: original table order
        ; virtual dispatch: replay both sides' input events for this tick,
        ; host side first, through the game's real handlers (live $035D)
        CLRR    R0
        MVO     R0,     VD_SIDE
        JSR     R5,     LS_VDISPATCH
        MVII    #1,     R0
        MVO     R0,     VD_SIDE
        JSR     R5,     LS_VDISPATCH
        JSR     R5,     LS_TBL_ADOPT
        MVII    #NET_NULL_TBL+4, R0
        MVO     R0,     $35D
        ; CRC report every 64 ticks
        MVI     TICK_LO, R0
        ANDI    #$3F,   R0
        BNEQ    @@ls_nocrc
        ; The static display state (colour stack, border, delays) is written
        ; once at start-of-game and never refreshed, so anything that scribbles
        ; on it stays on screen forever.  Reassert it here -- a no-op when
        ; healthy -- to bound that to ~2 seconds.
        JSR     R5,     RS_DISPLAY_RESET
        JSR     R5,     LS_CKSUM        ; R0 = checksum
        MVO     R0,     LS_TMPB
        SWAP    R0,     1
        MVO     R0,     LS_TMPB2
        JSR     R5,     RS_RECORD_CRC   ; keep for peer comparison
        MVII    #FN_TX, R5
        MVII    #5,     R0
        MVO@    R0,     R5
        MVII    #FT_CRC, R0
        MVO@    R0,     R5
        MVI     TICK_LO, R0
        MVO@    R0,     R5
        MVI     TICK_HI, R0
        MVO@    R0,     R5
        MVI     LS_TMPB, R0
        MVO@    R0,     R5
        MVI     LS_TMPB2, R0
        MVO@    R0,     R5
        MVII    #6,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
@@ls_nocrc:
        ; tick++
        MVI     TICK_LO, R0
        INCR    R0
        MVO     R0,     TICK_LO
        CMPI    #$100,  R0
        BNEQ    @@ls_pend
        MVI     TICK_HI, R0
        INCR    R0
        MVO     R0,     TICK_HI
@@ls_pend:
    IF NET_HUD <> 0
        MVI     TICK_LO, R0
        ANDI    #$0F,   R0
        BNEQ    @@ls_nohud
        JSR     R5,     HUD_DRAW        ; ~2 refreshes/second at full speed
@@ls_nohud:
    ENDI
        JSR     R5,     RS_PENDING      ; deferred resync push
        PULR    R7

@@ls_frz:
        PULR    R7                      ; screen already up: do nothing, ever
@@ls_gone:
        ; Freeze the ISR phase counter for good.  $0102 = 0 is the ISR's skip
        ; path -- video enable and sound keep running, so the screen we are
        ; about to paint stays lit, but object motion and the rest of the pass
        ; never resume.  If a stall or a resync hold already froze it, leave
        ; the saved value alone.
        MVI     LS_FROZE, R0
        TSTR    R0
        BNEQ    @@pl_fz
        MVII    #1,     R0
        MVO     R0,     LS_FROZE
        DIS
        MVI     $102,   R0
        MVO     R0,     LS_SAVE102
        CLRR    R0
        MVO     R0,     $102
        EIS
@@pl_fz:
        JSR     R5,     LS_PEER_LEFT
        MVII    #1,     R0
        MVO     R0,     PEER_SCR
        ; Park HERE, forever.  Returning to the EXEC pass does not work on
        ; this cart: the scan writes its progress markers into $0102 right
        ; after our freeze, the passes resume, and the pass machinery
        ; repaints the status rows over this screen every frame.  The ISR
        ; stays live (display + sound); only RESET leaves.
@@pl_park:
        B       @@pl_park

; ---------------------------------------------------------------------------
; LS_PEER_LEFT -- paint the terminal peer-left screen.
;
; With no opponent the sim cannot advance (every tick needs the remote input
; for that tick), so there is nothing to return to: LS_PASS bails out early
; from here on and the console sits on this screen until reset.
;
; The four diagnostic counters go on screen too.  This is the one moment a
; player on real hardware can read them without a debugger attached, and a
; drop is exactly when their values matter.
; ---------------------------------------------------------------------------
LS_PEER_LEFT:
        PSHR    R5
        JSR     R5,     DANCE_SETTLE    ; let the display dance tail finish
        JSR     R5,     RS_DISPLAY_RESET ; legible even if the STIC was clobbered
        JSR     R5,     UI_CLS
        MVI     PEER_WHY, R0
        TSTR    R0
        BEQ     @@pl_lost
        MVII    #20*4+3, R0
        MVII    #STR_GONE, R1
        JSR     R5,     UI_PRINT
        B       @@pl_nm
@@pl_lost:
        MVII    #20*4+2, R0
        MVII    #STR_LOST, R1
        JSR     R5,     UI_PRINT
@@pl_nm:
        MVII    #20*6+6, R0
        MVII    #OPP_NAME, R1
        JSR     R5,     UI_PRINT
        MVII    #20*9+4, R0
        MVII    #STR_RESET, R1
        JSR     R5,     UI_PRINT
        MVII    #20*10+2, R0
        MVII    #STR_DIAG, R1
        JSR     R5,     UI_PRINT
        MVI     DIAG_SLIP, R0
        MVII    #20*11+2, R1
        JSR     R5,     UI_HEX2
        MVI     DIAG_REJ, R0
        MVII    #20*11+7, R1
        JSR     R5,     UI_HEX2
        MVI     DIAG_TMO, R0
        MVII    #20*11+11, R1
        JSR     R5,     UI_HEX2
        MVI     DIAG_ERR, R0
        MVII    #20*11+15, R1
        JSR     R5,     UI_HEX2
        PULR    R7

; LS_IDLE_RMT -- fill the remote rings with idle values and pin the
; watermark far ahead (peer gone).
LS_IDLE_RMT:
        PSHR    R5
        MVII    #RMT_RING, R4
        MVII    #256,   R1
        MVII    #$40,   R0
@@li_f: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@li_f
        MVII    #RMT_KP, R4
        MVII    #256,   R1
        CLRR    R0
@@li_k: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@li_k
        MVI     TICK_HI, R0
        ADDI    #$40,   R0              ; T + ~16k ticks ahead
        MVO     R0,     RMT_WM_HI
        MVI     TICK_LO, R0
        MVO     R0,     RMT_WM_LO
        PULR    R7

; LS_CKSUM -- rotate-add checksum over the ISR-clean game state:
; $015D-$01EF + canonical RNG + the virtualized slow-tick countdown.
LS_CKSUM:
        PSHR    R5
        CLRR    R0
        MVII    #$15D,  R4
@@lk_1: SLLC    R0,     1
        ADCR    R0
        ADD@    R4,     R0
        CMPI    #$1F0,  R4
        BLT     @@lk_1
        SLLC    R0,     1
        ADCR    R0
        ADD     RNG_LO, R0
        SLLC    R0,     1
        ADCR    R0
        ADD     RNG_HI, R0
        SLLC    R0,     1
        ADCR    R0
        ADD     SLOW_CNT, R0
        PULR    R7
