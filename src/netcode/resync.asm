; Desync detection + recovery resync (M4).
;
; Both consoles CRC their ISR-clean game state every 64 ticks (LS_CKSUM) and
; send it; the relay forwards it to the peer.  Each console compares the
; peer's CRC against its own record for the same tick.  On mismatch:
;   guest: sends RESYNC_REQ once and keeps playing
;   host:  waits for ball-dead (RS_PENDING), then enters HOLD, pushes the full
;          game-state image + resume tick R; both re-baseline (tick := R,
;          rings idle, watermark R+d-1)
; The sim is frozen during HOLD exactly like a network stall ($0102 frozen
; by LS_PASS), so the pushed snapshot is stable and both sides resume from
; identical state.  The push is gated on a quiescent point so the swap is not
; visible -- see RS_PENDING for the ball-dead marker and the cap on waiting.
;
; State image (759 bytes, positions 0..758):
;   0..146    $015D-$01EF game scratch (bytes)
;   147..626  $0200-$02EF BACKTAB (240 words, LE byte pairs)
;   627..754  $031D-$035C object table (64 words, LE byte pairs)
;   755..760  RNG_LO, RNG_HI, SLOW_CNT, RS_SPARE, GAME_TBL_LO/HI
; STATE chunk frame: [len][08][pos_lo][pos_hi][data...]; pos_hi = $FF marks
; control: pos_lo 0 = BEGIN (payload R_lo,R_hi), 1 = END.

IMG_S1          EQU     147
IMG_S2          EQU     627
IMG_S3          EQU     755
IMG_TOTAL       EQU     761
RS_CHUNK        EQU     96
RS_HOLD_TMO     EQU     $0600           ; hold pump rounds before giving up

; ---------------------------------------------------------------------------
; RS_RECORD_CRC -- record own (tick, crc) for later peer comparison.
; Reads the crc from LS_TMPB/LS_TMPB2 (already staged by the send path).
; ---------------------------------------------------------------------------
RS_RECORD_CRC:
        PSHR    R5
        MVI     TICK_LO, R1
        SLR     R1,     2
        SLR     R1,     2
        SLR     R1,     2               ; tick >> 6
        ANDI    #7,     R1
        SLL     R1,     2               ; * 4
        ADDI    #OWN_CRC, R1
        MOVR    R1,     R4
        MVI     TICK_LO, R0
        MVO@    R0,     R4
        MVI     TICK_HI, R0
        MVO@    R0,     R4
        MVI     LS_TMPB, R0
        MVO@    R0,     R4
        MVI     LS_TMPB2, R0
        MVO@    R0,     R4
        PULR    R7

; ---------------------------------------------------------------------------
; RS_ON_CRC -- peer CRC frame in FRMBUF (+2 tick_lo +3 tick_hi +4/+5 crc).
; ---------------------------------------------------------------------------
RS_ON_CRC:
        PSHR    R5
        MVI     FRMBUF, R0
        CMPI    #5,     R0
        BLT     @@rc_out                ; short frame: +2..+5 would be stale
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BNEQ    @@rc_out                ; already recovering
        MVI     RS_PEND, R0
        TSTR    R0
        BNEQ    @@rc_out                ; resync already pending
        MVI     FRMBUF+2, R1
        SLR     R1,     2
        SLR     R1,     2
        SLR     R1,     2
        ANDI    #7,     R1
        SLL     R1,     2
        ADDI    #OWN_CRC, R1
        MOVR    R1,     R4
        MVI@    R4,     R0
        CMP     FRMBUF+2, R0
        BNEQ    @@rc_out                ; no record for that tick yet
        MVI@    R4,     R0
        CMP     FRMBUF+3, R0
        BNEQ    @@rc_out
        MVI@    R4,     R0
        CMP     FRMBUF+4, R0
        BNEQ    @@rc_bad
        MVI@    R4,     R0
        CMP     FRMBUF+5, R0
        BEQ     @@rc_out                ; CRCs agree
@@rc_bad:
        ; Mark the resync wanted, but do not act on it here.  Pushing the
        ; instant a CRC disagrees lands the state image mid-play and the ball
        ; and fielders visibly teleport; RS_PENDING holds the push until the
        ; game is ball-dead.  The guest simply keeps playing until the host's
        ; BEGIN arrives -- it must NOT freeze here, or it would sit still
        ; through the very play we are waiting to finish.
        MVII    #1,     R0
        MVO     R0,     RS_PEND
        CLRR    R0
        MVO     R0,     RS_PTMO
        MVI     NET_ROLE, R0
        TSTR    R0
        BEQ     @@rc_out                ; host: RS_PENDING drives the push
        ; guest: ask the host for one, once
        MVII    #FN_TX, R5
        MVII    #3,     R0
        MVO@    R0,     R5
        MVII    #FT_RESYNC, R0
        MVO@    R0,     R5
        MVI     FRMBUF+2, R0
        MVO@    R0,     R5
        MVI     FRMBUF+3, R0
        MVO@    R0,     R5
        MVII    #4,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
@@rc_out:
        PULR    R7

; ---------------------------------------------------------------------------
; RS_ON_REQ -- guest asked for a push (host only, once).
; ---------------------------------------------------------------------------
RS_ON_REQ:
        PSHR    R5
        MVI     NET_ROLE, R0
        TSTR    R0
        BNEQ    @@rq_out
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BNEQ    @@rq_out
        MVI     RS_PEND, R0
        TSTR    R0
        BNEQ    @@rq_out                ; already pending
        MVII    #1,     R0
        MVO     R0,     RS_PEND
        CLRR    R0
        MVO     R0,     RS_PTMO
@@rq_out:
        PULR    R7

; ---------------------------------------------------------------------------
; RS_PUSH -- host: hold, BEGIN(R), image chunks, END, re-baseline.
; ---------------------------------------------------------------------------
RS_PUSH:
        PSHR    R5
        JSR     R5,     RS_ENTER_HOLD
        ; R = current tick + 16
        MVI     TICK_HI, R1
        SWAP    R1,     1
        ADD     TICK_LO, R1
        ADDI    #16,    R1
        MVO     R1,     RS_R_LO
        SWAP    R1,     1
        MVO     R1,     RS_R_HI
        ; BEGIN frame
        MVII    #FN_TX, R3
        MVII    #5,     R0
        JSR     R5,     RS_PUTB
        MVII    #FT_STATE, R0
        JSR     R5,     RS_PUTB
        CLRR    R0
        JSR     R5,     RS_PUTB         ; pos_lo = 0 -> BEGIN
        MVII    #$FF,   R0
        JSR     R5,     RS_PUTB
        MVI     RS_R_LO, R0
        JSR     R5,     RS_PUTB
        MVI     RS_R_HI, R0
        JSR     R5,     RS_PUTB
        MVII    #6,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        ; image chunks
        CLRR    R0
        MVO     R0,     RS_POS_LO
        MVO     R0,     RS_POS_HI
@@ps_chunk:
        MVI     RS_POS_HI, R2
        SWAP    R2,     1
        ADD     RS_POS_LO, R2           ; R2 = pos
        MVII    #IMG_TOTAL, R1
        SUBR    R2,     R1              ; remaining
        BEQ     @@ps_end
        CMPI    #RS_CHUNK, R1
        BLT     @@ps_n
        MVII    #RS_CHUNK, R1
@@ps_n: MVO     R1,     RS_TMP2         ; n (chunk payload bytes)
        MVO     R1,     LS_TMPB         ; copy for NREQ later
        MVII    #FN_TX, R3
        MOVR    R1,     R0
        ADDI    #3,     R0
        JSR     R5,     RS_PUTB         ; len = n + 3
        MVII    #FT_STATE, R0
        JSR     R5,     RS_PUTB
        MOVR    R2,     R0
        JSR     R5,     RS_PUTB         ; pos_lo
        MOVR    R2,     R0
        SWAP    R0,     1
        JSR     R5,     RS_PUTB         ; pos_hi
@@ps_pl:
        MOVR    R2,     R1
        JSR     R5,     IMG_GET         ; R0 = image[pos]; preserves R2,R3
        JSR     R5,     RS_PUTB
        INCR    R2
        MVI     RS_TMP2, R0
        DECR    R0
        MVO     R0,     RS_TMP2
        BNEQ    @@ps_pl
        MVO     R2,     RS_POS_LO
        SWAP    R2,     1
        MVO     R2,     RS_POS_HI
        MVI     LS_TMPB, R0
        ADDI    #4,     R0              ; frame bytes = len byte + len
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        B       @@ps_chunk
@@ps_end:
        ; END frame
        MVII    #FN_TX, R3
        MVII    #3,     R0
        JSR     R5,     RS_PUTB
        MVII    #FT_STATE, R0
        JSR     R5,     RS_PUTB
        MVII    #1,     R0
        JSR     R5,     RS_PUTB         ; pos_lo = 1 -> END
        MVII    #$FF,   R0
        JSR     R5,     RS_PUTB
        MVII    #4,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        JSR     R5,     RS_REBASE
        PULR    R7

; RS_PUTB -- append R0 to the TX frame at R3 (manual increment).
RS_PUTB:
        MVO@    R0,     R3
        INCR    R3
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; RS_ON_STATE -- guest side: apply a STATE frame from FRMBUF.
; ---------------------------------------------------------------------------
RS_ON_STATE:
        PSHR    R5
        MVI     FRMBUF, R0
        CMPI    #3,     R0
        BLT     @@rs_bad                ; short frame: +2/+3 would be stale
        MVI     FRMBUF+3, R0
        CMPI    #$FF,   R0
        BEQ     @@rs_ctl
        ; Data chunks are only ever legitimate inside a hold that a BEGIN
        ; opened.  Outside one, a "STATE" frame is by definition a misparse
        ; (the wire carries plenty of $08 bytes), and IMG_PUT would turn its
        ; position straight into a write anywhere in the address space.
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BEQ     @@rs_bad
        ; count = len - 3
        MVI     FRMBUF, R0
        SUBI    #3,     R0
        BLE     @@rs_bad
        MVO     R0,     RS_TMP2
        ; Bounds: the chunk must lie wholly inside the image.  Without this
        ; IMG_PUT walks off the end of RS_TAILTBL and uses ROM CODE WORDS as
        ; destination pointers (STIC registers, GRAM, BACKTAB), and a
        ; position >= $8000 fails the signed range tests and splats a
        ; contiguous run over $0000+ -- the whole STIC register file.
        MVI     FRMBUF+3, R1
        CMPI    #3,     R1
        BGE     @@rs_bad                ; pos >= $300: nothing valid up there
        SWAP    R1,     1
        ADD     FRMBUF+2, R1            ; R1 = pos (0..767)
        ADDR    R0,     R1              ; + count (<= 252), no wrap possible
        CMPI    #IMG_TOTAL+1, R1
        BGE     @@rs_bad                ; chunk overruns the image: drop it
        MVI     FRMBUF+2, R0
        MVO     R0,     RS_POS_LO
        MVI     FRMBUF+3, R0
        MVO     R0,     RS_POS_HI
        MVII    #FRMBUF+4, R3
@@rs_dl:
        MVI@    R3,     R0
        INCR    R3
        MVI     RS_POS_HI, R1
        SWAP    R1,     1
        ADD     RS_POS_LO, R1
        JSR     R5,     IMG_PUT         ; preserves R3
        MVI     RS_POS_LO, R0
        INCR    R0
        MVO     R0,     RS_POS_LO
        CMPI    #$100,  R0
        BNEQ    @@rs_np
        MVI     RS_POS_HI, R0
        INCR    R0
        MVO     R0,     RS_POS_HI
@@rs_np:
        MVI     RS_TMP2, R0
        DECR    R0
        MVO     R0,     RS_TMP2
        BNEQ    @@rs_dl
        B       @@rs_out
@@rs_ctl:
        MVI     FRMBUF+2, R0
        TSTR    R0
        BNEQ    @@rs_endf
        ; BEGIN: hold + record resume tick
        MVI     FRMBUF, R1
        CMPI    #5,     R1
        BLT     @@rs_bad                ; short frame: +4/+5 would be stale
        JSR     R5,     RS_ENTER_HOLD
        MVI     FRMBUF+4, R0
        MVO     R0,     RS_R_LO
        MVI     FRMBUF+5, R0
        MVO     R0,     RS_R_HI
        B       @@rs_out
@@rs_endf:
        CMPI    #1,     R0
        BNEQ    @@rs_out
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BEQ     @@rs_out                ; no hold open: not our END
        JSR     R5,     RS_REBASE
        B       @@rs_out
@@rs_bad:
        ; a refused chunk means a misframed stream reached this far
        MVII    #DIAG_REJ, R4
        JSR     R5,     DIAG_BUMP
@@rs_out:
        PULR    R7

; ---------------------------------------------------------------------------
; RS_ENTER_HOLD / RS_REBASE
; ---------------------------------------------------------------------------
RS_ENTER_HOLD:
        PSHR    R5
        MVII    #1,     R0
        MVO     R0,     RESYNC_HOLD
        CLRR    R0
        MVO     R0,     RS_TO_LO
        MVO     R0,     RS_TO_HI
        JSR     R5,     RS_CLR_CRC
        PULR    R7

RS_REBASE:
        PSHR    R5
    IF NET_HUD <> 0
        MVI     HUD_RSY, R0
        CMPI    #$FF,   R0
        BEQ     @@rb_hd
        INCR    R0
        MVO     R0,     HUD_RSY
@@rb_hd:
    ENDI
        CLRR    R0
        MVO     R0,     RS_PEND
        MVO     R0,     RS_PTMO
        JSR     R5,     RS_DISPLAY_RESET
        MVI     RS_R_LO, R0
        MVO     R0,     TICK_LO
        MVI     RS_R_HI, R0
        MVO     R0,     TICK_HI
        JSR     R5,     LS_RING_INIT    ; all input rings back to idle
        ; watermark = R + d - 1
        MVI     RS_R_HI, R1
        SWAP    R1,     1
        ADD     RS_R_LO, R1
        MVI     NET_DELAY, R0
        ADDR    R0,     R1
        DECR    R1
        MVO     R1,     RMT_WM_LO
        SWAP    R1,     1
        MVO     R1,     RMT_WM_HI
        JSR     R5,     RS_CLR_CRC
        CLRR    R0
        MVO     R0,     RESYNC_HOLD
        MVO     R0,     RS_TO_LO
        MVO     R0,     RS_TO_HI
        MVO     R0,     LS_WAITC_LO
        MVO     R0,     LS_WAITC_HI
        PULR    R7

; ---------------------------------------------------------------------------
; RS_PENDING -- host side, once per game tick: a resync is wanted, so wait for
; a quiescent moment and then push.
;
; "Ball dead" is read straight off the phase table the game has installed:
; BB_TBL_PREPITCH means the pitcher is holding the ball with nothing in
; flight, so replacing the world underneath the players is invisible.  Waiting
; costs a few seconds of the two sims running visibly apart, which is why the
; wait is capped at RS_PEND_MAX ticks -- past that a visible jump beats
; staying desynced, and we push regardless.
;
; Taking the snapshot here rather than from inside the frame dispatcher is a
; bonus: the image is now always serialized at the same fixed point in the
; pass, after the tick and its virtual dispatch have finished.
; ---------------------------------------------------------------------------
; Football has genuine dead-ball moments: phases 0-4 (reset / post-tackle /
; play select / line up / huts), 9 (post-score) and $A (end of game) are all
; ball-dead; the ball is live only in phases 5-8 and $B (run / pass / kick /
; return).  A play rarely lasts more than a few seconds, so the cap fires
; only if the runner stays alive unusually long.
RS_PEND_MAX     EQU     60              ; game ticks (~3 s at 20 Hz)

RS_PENDING:
        PSHR    R5
        MVI     RS_PEND, R0
        TSTR    R0
        BEQ     @@rp_out
        MVI     NET_ROLE, R0
        TSTR    R0
        BNEQ    @@rp_out                ; only the host pushes
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BNEQ    @@rp_out                ; push already under way
        MVI     RS_PTMO, R0
        INCR    R0
        MVO     R0,     RS_PTMO
        ; quiescent?  dead ball = FB_PHASE <= 4, or 9/$A (post-score / end
        ; of game); live = 5-8 (run/pass/kick) and $B (kick return)
        MVI     FB_PHASE, R0
        CMPI    #5,     R0
        BLT     @@rp_go
        CMPI    #9,     R0
        BLT     @@rp_tmo                ; 5-8: ball live
        CMPI    #$0B,   R0
        BLT     @@rp_go                 ; 9/$A: dead
        B       @@rp_tmo                ; $B: kick return, live
@@rp_tmo:
        MVI     RS_PTMO, R0
        CMPI    #RS_PEND_MAX, R0
        BLT     @@rp_out                ; still waiting for the play to end
        MVII    #2,     R0              ; gave up: pushing mid-play
        B       @@rp_mark
@@rp_go:
        MVII    #1,     R0              ; quiescent phase: swap is invisible
@@rp_mark:
        MVO     R0,     RS_GATE
        MVI     RS_PTMO, R0
        MVO     R0,     RS_WAITED       ; how long this one actually waited
        JSR     R5,     RS_PUSH
@@rp_out:
        PULR    R7

; ---------------------------------------------------------------------------
; RS_DISPLAY_RESET -- reassert the static half of the display state from the
; cart header.
;
; Auto Racing is NOT Baseball here: the game scrolls the track, so the STIC
; scroll delays $0030/$0031 are live game state, rewritten every tick by the
; game's VBLANK ISR dance from cells $019E/$01A1 (which sit inside the CRC
; range and image section 1).  Zeroing them here -- as the Baseball engine
; did -- would fight the game every tick.  What IS static on this cart is
; the border extension ($0032 from $500D = $03) and the colour-stack/border
; cells $0028-$002C ($500F-$5013, all zero; unused in FG/BG mode but
; harmless to reassert).  After a resync the game's own dance repaints the
; scroll registers from the restored cells within one tick.
; ---------------------------------------------------------------------------
RS_DISPLAY_RESET:
        PSHR    R5
        MVI     $500D,  R0
        MVO     R0,     $0032           ; border extension
        MVII    #$500F, R4              ; header: CS0..CS3 then border colour
        MVII    #$0028, R5
        MVII    #5,     R2
@@dr_l: MVI@    R4,     R0
        MVO@    R0,     R5              ; $0028-$002C
        DECR    R2
        BNEQ    @@dr_l
        PULR    R7

; RS_CLR_CRC -- invalidate every record in the ring.
;
; The fill value is NOT zero.  A record is matched by its stored tick, and a
; zeroed ring reads as a perfectly good record for tick 0 with a checksum of
; 0 -- so the peer's tick-0 CRC, which routinely arrives before this console
; has ticked 0 at all (the handover hold pumps the socket while TICK is still
; 0), compared against nothing and declared a desync.  That cost a full state
; resync near the start of every single match; the server's own CRC log said
; the two consoles agreed the whole time.  CRCs are only ever recorded on a
; 64-tick boundary, so a stored tick_lo of $FF cannot collide with a real one.
RS_CLR_CRC:
        PSHR    R5
        MVII    #OWN_CRC, R4
        MVII    #32,    R1
        MVII    #$FF,   R0
@@cc_l: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@cc_l
        PULR    R7

; ---------------------------------------------------------------------------
; IMG_GET -- R0 = image byte at position R1.  Preserves R2, R3.
; IMG_PUT -- write byte R0 to image position R1.  Preserves R3.
; ---------------------------------------------------------------------------
RS_TAILTBL:
        DECLE   RNG_LO, RNG_HI, SLOW_CNT, RS_SPARE
        DECLE   GAME_TBL_LO, GAME_TBL_HI

IMG_GET:
        CMPI    #IMG_S1, R1
        BGE     @@ig_2
        ADDI    #$15D,  R1
        MOVR    R1,     R4
        MVI@    R4,     R0
        MOVR    R5,     R7
@@ig_2: CMPI    #IMG_S2, R1
        BGE     @@ig_3
        SUBI    #IMG_S1, R1
        MOVR    R1,     R0
        SLR     R0,     1
        ADDI    #$200,  R0
        MOVR    R0,     R4
        ANDI    #1,     R1
        B       @@ig_w
@@ig_3: CMPI    #IMG_S3, R1
        BGE     @@ig_t
        SUBI    #IMG_S2, R1
        MOVR    R1,     R0
        SLR     R0,     1
        ADDI    #$31D,  R0
        MOVR    R0,     R4
        ANDI    #1,     R1
@@ig_w: MVI@    R4,     R0
        TSTR    R1
        BEQ     @@ig_lo
        SWAP    R0,     1
@@ig_lo:
        ANDI    #$FF,   R0
        MOVR    R5,     R7
@@ig_t: SUBI    #IMG_S3, R1
        ADDI    #RS_TAILTBL, R1
        MOVR    R1,     R4
        MVI@    R4,     R1
        MOVR    R1,     R4
        MVI@    R4,     R0
        MOVR    R5,     R7

IMG_PUT:
        MVO     R0,     RS_TMP
        CMPI    #IMG_S1, R1
        BGE     @@ip_2
        ADDI    #$15D,  R1
        MOVR    R1,     R4
        MVI     RS_TMP, R0
        MVO@    R0,     R4
        MOVR    R5,     R7
@@ip_2: CMPI    #IMG_S2, R1
        BGE     @@ip_3
        SUBI    #IMG_S1, R1
        MOVR    R1,     R0
        SLR     R0,     1
        ADDI    #$200,  R0
        MOVR    R0,     R4
        ANDI    #1,     R1
        B       @@ip_w
@@ip_3: CMPI    #IMG_S3, R1
        BGE     @@ip_t
        SUBI    #IMG_S2, R1
        MOVR    R1,     R0
        SLR     R0,     1
        ADDI    #$31D,  R0
        MOVR    R0,     R4
        ANDI    #1,     R1
@@ip_w: ; read-modify-write the 16-bit word (chunks arrive lo byte first)
        MOVR    R4,     R2
        MVI@    R4,     R0
        TSTR    R1
        BEQ     @@ip_lo
        ANDI    #$00FF, R0
        MVI     RS_TMP, R1
        SWAP    R1,     1
        ADDR    R1,     R0
        B       @@ip_st
@@ip_lo:
        ANDI    #$FF00, R0
        ADD     RS_TMP, R0
@@ip_st:
        MOVR    R2,     R4
        MVO@    R0,     R4
        MOVR    R5,     R7
@@ip_t: SUBI    #IMG_S3, R1
        ADDI    #RS_TAILTBL, R1
        MOVR    R1,     R4
        MVI@    R4,     R1
        MOVR    R1,     R4
        MVI     RS_TMP, R0
        MVO@    R0,     R4
        MOVR    R5,     R7
