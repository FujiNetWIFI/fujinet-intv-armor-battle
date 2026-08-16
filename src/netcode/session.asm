; Pre-game netplay session: FujiNet check, Lobby-username appkey, server
; connect, HELLO, lobby list / opponent select, START.  Runs from NET_START
; (EXEC main loop not started; ISR alive; direct BACKTAB + raw port I/O).
; Returns with NET_ACTIVE=1 (netplay armed) or 0 (fall through to the stock
; local game -- no FujiNet / no server).

FUJI_DEVICEID   EQU     $70
CMD_OPEN_APPKEY EQU     $DC
CMD_CLOSE_APPKEY EQU    $DB
CMD_READ_APPKEY EQU     $DD

; Raw left-controller values (port read XOR $FF).  Keypad codes always carry
; one column bit ($20/$40/$80) plus one row bit, so anything below $20 is the
; direction disc: bit 2 = the northern arc (ENE..NW), bit 0 = the southern arc
; (WSW..SE).  Those two arcs are disjoint, so the test needs no exact codes.
KEY_UP          EQU     $41             ; keypad 2
KEY_DOWN        EQU     $44             ; keypad 8
KEY_ENTER       EQU     $28
DISC_MAX        EQU     $20             ; raw < this = disc, not keypad
DISC_N          EQU     $04             ; northern arc bit
DISC_S          EQU     $01             ; southern arc bit

; Lobby screen rows.  The prompt sits ABOVE the list: SES_RENDER clears rows
; 4-11 on every refresh, so anything inside that band is wiped the moment the
; first LOBBY frame lands.
ROW_PROMPT      EQU     20*3
ROW_LIST        EQU     4

SES_MAIN:
        PSHR    R5
        ; Take over the display: the EXEC main loop hasn't started, so the
        ; ISR is still running the boot/title phase machine off $0102 and
        ; keeps repainting/blanking BACKTAB over our screens.  Freeze it
        ; (0 = ISR skip path: video-enable + sound only); restored at every
        ; session exit so the game then boots exactly like the hook build.
        DIS
        MVI     $102,   R0
        MVO     R0,     SES_SAVE102
        CLRR    R0
        MVO     R0,     $102
        EIS
        ; This cart boots with border extension $500D = $03 (top row + left
        ; column cropped).  Clear it for the session screens; SES_EXIT puts
        ; the header value back so the game starts pixel-stock.
        CLRR    R0
        MVO     R0,     $0032
        JSR     R5,     UI_CLS
        CLRR    R0
        MVII    #STR_TITLE, R1
        JSR     R5,     UI_PRINT
        ; ---- FujiNet present?
        JSR     R5,     MB_WAIT_MAGIC
        MVI     MB_OK,  R0
        TSTR    R0
        BNEQ    @@ses_mb
        MVII    #40,    R0
        MVII    #STR_NOFN, R1
        JSR     R5,     UI_PRINT
        JSR     R5,     SES_PAUSE
        B       SES_EXIT                ; -> local stock game
@@ses_mb:
        ; ---- username
        JSR     R5,     SES_GETNAME
        MVII    #40,    R0
        MVII    #STR_HELLO, R1
        JSR     R5,     UI_PRINT
        MVII    #46,    R0
        MVII    #NAME_BUF, R1
        JSR     R5,     UI_PRINT
        ; ---- connect to server
        MVII    #SRV_SPEC, R4
        MVII    #FN_TX, R5
        MVII    #SRV_SPEC_LEN, R1
@@ses_cp:
        MVI@    R4,     R0
        MVO@    R0,     R5
        DECR    R1
        BNEQ    @@ses_cp
        MVII    #SRV_SPEC_LEN, R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_OPEN
        MVI     MB_OK,  R0
        TSTR    R0
        BNEQ    @@ses_conn
        MVII    #60,    R0
        MVII    #STR_NOSRV, R1
        JSR     R5,     UI_PRINT
        MVI     MB_ERR, R0
        MVII    #75,    R1
        JSR     R5,     UI_HEX2
        JSR     R5,     SES_PAUSE
        B       SES_EXIT                ; -> local stock game
@@ses_conn:
        ; ---- HELLO: len = 2 + name_len
        MVII    #FN_TX, R5
        MVI     NAME_LEN, R2
        MOVR    R2,     R0
        ADDI    #2,     R0
        MVO@    R0,     R5              ; frame len
        MVII    #FT_HELLO, R0
        MVO@    R0,     R5
        MVII    #1,     R0
        MVO@    R0,     R5              ; protocol version
        MVII    #NAME_BUF, R4
@@ses_hn:
        MVI@    R4,     R0
        MVO@    R0,     R5
        DECR    R2
        BNEQ    @@ses_hn
        MVI     NAME_LEN, R0
        ADDI    #3,     R0              ; len byte + type + ver + name
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        MVII    #ROW_PROMPT, R0
        MVII    #STR_PICK, R1
        JSR     R5,     UI_PRINT
        ; ---- lobby loop
@@ses_lobby:
        JSR     R5,     SES_PUMP
        MVI     NET_ACTIVE, R0
        TSTR    R0
        BNEQ    @@ses_go
        ; menu input: local left controller, edge-detected
        MVI     $1FF,   R0
        XORI    #$FF,   R0
        CMP     MENU_PREV, R0
        BEQ     @@ses_pace
        MVO     R0,     MENU_PREV
        TSTR    R0
        BEQ     @@ses_pace
        CMPI    #DISC_MAX, R0
        BGE     @@ses_kp
        ; disc: players reach for it before the keypad, so it moves the cursor
        MOVR    R0,     R1
        ANDI    #DISC_N, R1
        BNEQ    @@ses_up
        MOVR    R0,     R1
        ANDI    #DISC_S, R1
        BNEQ    @@ses_dn
        B       @@ses_pace
@@ses_kp:
        CMPI    #KEY_UP, R0
        BEQ     @@ses_up
        CMPI    #KEY_DOWN, R0
        BEQ     @@ses_dn
        CMPI    #KEY_ENTER, R0
        BEQ     @@ses_join
        B       @@ses_pace
@@ses_up:
        MVI     MENU_SEL, R0
        TSTR    R0
        BEQ     @@ses_rr
        DECR    R0
        MVO     R0,     MENU_SEL
        B       @@ses_rr
@@ses_dn:
        MVI     MENU_SEL, R0
        INCR    R0
        CMP     LOBBY_CNT, R0
        BGE     @@ses_rr
        MVO     R0,     MENU_SEL
@@ses_rr:
        JSR     R5,     SES_RENDER
        B       @@ses_pace
@@ses_join:
        MVI     LOBBY_CNT, R0
        TSTR    R0
        BEQ     @@ses_pace
        ; JOIN with the selected cached name (8 bytes, may be NUL padded)
        MVI     MENU_SEL, R0
        MOVR    R0,     R2
        SLL     R2,     2
        SLL     R2,     1
        ADDR    R0,     R2              ; sel * 9
        ADDI    #LOBBY_CACHE+1, R2      ; entry name
        ; The status byte follows the 8 name bytes: 0 = idle, 1 = already in a
        ; match.  The server just drops a JOIN aimed at a busy player and
        ; answers with a fresh LOBBY, which on screen looks like a dead button.
        MOVR    R2,     R4
        ADDI    #8,     R4
        MVI@    R4,     R0
        TSTR    R0
        BEQ     @@ses_jok
        MVII    #ROW_PROMPT, R0
        MVII    #STR_BUSY, R1
        JSR     R5,     UI_PRINT
        JSR     R5,     SES_PAUSE
        JSR     R5,     SES_PAUSE
        JSR     R5,     SES_RENDER      ; puts the prompt back
        B       @@ses_pace
@@ses_jok:
        MVII    #FN_TX, R5
        MVII    #9,     R0
        MVO@    R0,     R5              ; len = type + 8 name bytes
        MVII    #FT_JOIN, R0
        MVO@    R0,     R5
        MVII    #8,     R1
        MOVR    R2,     R4
@@ses_jn:
        MVI@    R4,     R0
        MVO@    R0,     R5
        DECR    R1
        BNEQ    @@ses_jn
        MVII    #10,    R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        MVII    #ROW_PROMPT, R0
        MVII    #STR_JOINING, R1
        JSR     R5,     UI_PRINT
@@ses_pace:
        ; refresh the list every 256 loop iterations (~ seconds)
        MVI     SES_TMR_LO, R0
        INCR    R0
        MVO     R0,     SES_TMR_LO
        CMPI    #$100,  R0
        BNEQ    @@ses_lobby
    IF AUTO_JOIN <> 0
        ; test rigs: join the first lobby entry as soon as one exists
        MVI     LOBBY_CNT, R0
        TSTR    R0
        BNEQ    @@ses_join
    ENDI
        MVII    #FN_TX, R5
        MVII    #1,     R0
        MVO@    R0,     R5
        MVII    #FT_LIST, R0
        MVO@    R0,     R5
        MVII    #2,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        B       @@ses_lobby
@@ses_go:
        ; ---- matched: who is who ------------------------------------------
        ; The server's role is a seat at the game's controller ports, and the
        ; 1978 manual (p.4) says what those seats mean: the RIGHT controller is
        ; the home team, so role 0 (host, the game's LEFT controller) is the
        ; Seats (spikes/NOTES.md M7): host = left seat = HOME (defense at
        ; boot), guest = right seat = VISITOR (first possession -- picks
        ; the play, snaps, runs).  Scoreboard row 0/1: Home = left column
        ; ($017D), Visitor = right ($017C).  Both consoles feed their own
        ; player from their own left controller.
        JSR     R5,     UI_CLS
        CLRR    R0
        MVII    #STR_TITLE, R1
        JSR     R5,     UI_PRINT
        MVII    #20*2,  R0
        MVII    #STR_VS, R1
        JSR     R5,     UI_PRINT
        MVII    #20*2+3, R0
        MVII    #OPP_NAME, R1
        JSR     R5,     UI_PRINT
        MVI     NET_ROLE, R0
        TSTR    R0
        BNEQ    @@sg_p2
        MVII    #C_YELLOW, R0
        MVO     R0,     UI_COLOR
        MVII    #20*5+2, R0
        MVII    #STR_YOUP1, R1
        JSR     R5,     UI_PRINT
        MVII    #C_WHITE, R0
        MVO     R0,     UI_COLOR
        MVII    #20*6+2, R0
        MVII    #STR_OPPP2, R1
        JSR     R5,     UI_PRINT
        B       @@sg_tail
@@sg_p2:
        MVII    #C_YELLOW, R0
        MVO     R0,     UI_COLOR
        MVII    #20*5+2, R0
        MVII    #STR_YOUP2, R1
        JSR     R5,     UI_PRINT
        MVII    #C_WHITE, R0
        MVO     R0,     UI_COLOR
        MVII    #20*6+2, R0
        MVII    #STR_OPPP1, R1
        JSR     R5,     UI_PRINT
@@sg_tail:
        MVII    #C_WHITE, R0
        MVO     R0,     UI_COLOR
        MVII    #20*8+1, R0
        MVII    #STR_PICKS, R1
        JSR     R5,     UI_PRINT
        MVII    #20*10, R0
        MVII    #STR_USELEFT, R1
        JSR     R5,     UI_PRINT
        JSR     R5,     SES_HOLD
SES_EXIT:
        ; hand the display machinery back to the EXEC boot flow
        MVI     $500D,  R0
        MVO     R0,     $0032           ; border extension back to stock
        DIS
        MVI     SES_SAVE102, R0
        MVO     R0,     $102
        EIS
        PULR    R7

; ---------------------------------------------------------------------------
; SES_GETNAME -- Lobby username appkey (creator=1, app=1, key=0), one retry,
; A-Z0-9 validation; fallback GUESTnn from the boot-entropy LFSR.
; ---------------------------------------------------------------------------
SES_GETNAME:
        PSHR    R5
        MVII    #2,     R0
        MVO     R0,     PP_TMP          ; tries
@@gn_try:
        ; OPEN: 6-byte payload creator_lo/hi, app, key, mode(0=read), rsvd
        MVII    #FN_TX, R5
        MVII    #1,     R0
        MVO@    R0,     R5              ; creator lo = 1
        CLRR    R0
        MVO@    R0,     R5              ; creator hi
        MVII    #1,     R0
        MVO@    R0,     R5              ; app = 1
        CLRR    R0
        MVO@    R0,     R5              ; key = 0 (username)
        MVO@    R0,     R5              ; mode = read
        MVO@    R0,     R5              ; reserved
        MVII    #FUJI_DEVICEID, R0
        MVO     R0,     MB_DEV
        MVII    #CMD_OPEN_APPKEY, R0
        MVO     R0,     MB_CMD
        CLRR    R0
        MVO     R0,     MB_NPARAM
        MVO     R0,     MB_TXLEN_HI
        MVII    #6,     R0
        MVO     R0,     MB_TXLEN_LO
        JSR     R5,     MB_TRANSACT
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@gn_retry
        ; READ
        MVII    #CMD_READ_APPKEY, R0
        MVO     R0,     MB_CMD
        CLRR    R0
        MVO     R0,     MB_TXLEN_LO
        JSR     R5,     MB_TRANSACT
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@gn_retry
        ; rs232 transport prepends a 2-byte LE length; copy + validate
        MVI     FN_RX,  R2              ; length lo (hi ignored; clamp 8)
        CMPI    #8,     R2
        BLT     @@gn_l
        MVII    #8,     R2
@@gn_l: CMPI    #2,     R2
        BLT     @@gn_close_bad
        MVII    #FN_RX+2, R4
        MVII    #NAME_BUF, R5
        MVO     R2,     NAME_LEN
        MOVR    R2,     R1
@@gn_c: MVI@    R4,     R0
        CMPI    #'0',   R0
        BLT     @@gn_close_bad
        CMPI    #'9',   R0
        BLE     @@gn_okc
        CMPI    #'A',   R0
        BLT     @@gn_close_bad
        CMPI    #'Z',   R0
        BGT     @@gn_close_bad
@@gn_okc:
        MVO@    R0,     R5
        DECR    R1
        BNEQ    @@gn_c
        CLRR    R0
        MVO@    R0,     R5              ; NUL
        JSR     R5,     SES_AK_CLOSE
        PULR    R7
@@gn_close_bad:
        JSR     R5,     SES_AK_CLOSE
        B       @@gn_fallback
@@gn_retry:
        JSR     R5,     SES_AK_CLOSE
        MVI     PP_TMP, R0
        DECR    R0
        MVO     R0,     PP_TMP
        BNEQ    @@gn_try
@@gn_fallback:
        ; GUESTnn, nn from the boot-entropy LFSR at $035E
        MVII    #STR_GUEST, R4
        MVII    #NAME_BUF, R5
        MVII    #5,     R1
@@gn_g: MVI@    R4,     R0
        MVO@    R0,     R5
        DECR    R1
        BNEQ    @@gn_g
        MVI     EXEC_RNG, R0
        ANDI    #$0F,   R0
        CMPI    #10,    R0
        BLT     @@gn_d1
        SUBI    #10,    R0
@@gn_d1:
        ADDI    #'0',   R0
        MVO@    R0,     R5
        MVI     EXEC_RNG, R0
        SWAP    R0,     1
        ANDI    #$0F,   R0
        CMPI    #10,    R0
        BLT     @@gn_d2
        SUBI    #10,    R0
@@gn_d2:
        ADDI    #'0',   R0
        MVO@    R0,     R5
        CLRR    R0
        MVO@    R0,     R5
        MVII    #7,     R0
        MVO     R0,     NAME_LEN
        PULR    R7

SES_AK_CLOSE:
        PSHR    R5
        MVII    #FUJI_DEVICEID, R0
        MVO     R0,     MB_DEV
        MVII    #CMD_CLOSE_APPKEY, R0
        MVO     R0,     MB_CMD
        CLRR    R0
        MVO     R0,     MB_NPARAM
        MVO     R0,     MB_TXLEN_LO
        MVO     R0,     MB_TXLEN_HI
        JSR     R5,     MB_TRANSACT
        PULR    R7

; ---------------------------------------------------------------------------
; SES_PUMP -- one STATUS, one bounded READ, accumulate into the circular
; stream buffer, extract and dispatch complete frames.
; ---------------------------------------------------------------------------
SES_PUMP:
        PSHR    R5
        JSR     R5,     NET_STATUS
        MVI     MB_OK,  R0
        TSTR    R0
        BEQ     @@pp_parse
        MVI     NAVAIL_HI, R0
        TSTR    R0
        BNEQ    @@pp_clamp
        MVI     NAVAIL_LO, R0
        TSTR    R0
        BEQ     @@pp_parse
        CMPI    #64,    R0
        BLT     @@pp_rd
@@pp_clamp:
        MVII    #64,    R0
@@pp_rd:
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_READ
        MVI     NGOT_LO, R2
        TSTR    R2
        BEQ     @@pp_parse
        MVII    #FN_RX, R4
@@pp_cp:
        MVI@    R4,     R0
        MVI     RX_WR,  R1
        MOVR    R1,     R3
        ADDI    #RXACC, R3
        MVO@    R0,     R3
        INCR    R1
        ANDI    #$FF,   R1
        MVO     R1,     RX_WR
        DECR    R2
        BNEQ    @@pp_cp
@@pp_parse:
        ; buffered bytes = (wr - rd) & $FF
        MVI     RX_WR,  R0
        SUB     RX_RD,  R0
        ANDI    #$FF,   R0              ; R0 = buffered, kept to the end
        CMPI    #2,     R0
        BLT     @@pp_done               ; need len + type to validate
        ; ---- framing check.  This is a bare length-prefixed stream with no
        ; sync marker, so a single byte lost or duplicated on the read path
        ; (a timed-out NET_READ the peripheral completes anyway) misframes
        ; EVERYTHING after it -- and the wire is full of bytes that read as a
        ; frame type ($08 = STATE is also disc-south and a common tick byte).
        ; Validate (type, len) against what the server can actually emit, and
        ; on a mismatch drop one byte and rescan until the stream re-aligns.
        MVI     RX_RD,  R1
        MOVR    R1,     R4
        ADDI    #RXACC, R4
        MVI@    R4,     R2              ; R2 = len (body bytes)
        MVI     RX_RD,  R1
        INCR    R1
        ANDI    #$FF,   R1              ; type byte, wrapping the ring
        ADDI    #RXACC, R1
        MOVR    R1,     R4
        MVI@    R4,     R1              ; R1 = type
        CMPI    #$10,   R1
        BGE     @@pp_slip
        ADDI    #SES_FLEN, R1
        MOVR    R1,     R4
        MVI@    R4,     R1              ; R1 = max SHL 8 OR min
        TSTR    R1
        BEQ     @@pp_slip               ; type never arrives inbound
        MOVR    R1,     R3
        ANDI    #$FF,   R3
        CMPR    R3,     R2
        BLT     @@pp_slip               ; len below this type's minimum
        SWAP    R1,     1
        ANDI    #$FF,   R1
        CMPR    R1,     R2
        BGT     @@pp_slip               ; len above this type's maximum
        INCR    R2                      ; total incl len byte
        CMPR    R2,     R0
        BLT     @@pp_done               ; incomplete
        ; extract into FRMBUF
        MVII    #FRMBUF, R5
@@pp_x: MVI     RX_RD,  R1
        MOVR    R1,     R3
        ADDI    #RXACC, R3
        MVI@    R3,     R0
        MVO@    R0,     R5
        INCR    R1
        ANDI    #$FF,   R1
        MVO     R1,     RX_RD
        DECR    R2
        BNEQ    @@pp_x
        JSR     R5,     SES_ONFRAME
        B       @@pp_parse
@@pp_slip:
        MVI     RX_RD,  R0
        INCR    R0
        ANDI    #$FF,   R0
        MVO     R0,     RX_RD           ; discard one byte, try again
        MVII    #DIAG_SLIP, R4
        JSR     R5,     DIAG_BUMP
        B       @@pp_parse
@@pp_done:
        PULR    R7

; ---------------------------------------------------------------------------
; SES_ONFRAME -- dispatch FRMBUF = [len][type][payload].
; ---------------------------------------------------------------------------
SES_ONFRAME:
        PSHR    R5
        MVI     FRMBUF+1, R0
        CMPI    #FT_INPUT, R0
        BEQ     @@of_input
        CMPI    #FT_LOBBY, R0
        BEQ     @@of_lobby
        CMPI    #FT_START, R0
        BEQ     @@of_start
        CMPI    #FT_PEER_LEFT, R0
        BEQ     @@of_pl
        CMPI    #FT_CRC, R0
        BEQ     @@of_crc
        CMPI    #FT_STATE, R0
        BEQ     @@of_state
        CMPI    #FT_RESYNC, R0
        BEQ     @@of_rsq
        PULR    R7                      ; ignore others (PONG...)
@@of_crc:
        JSR     R5,     RS_ON_CRC
        PULR    R7
@@of_state:
        JSR     R5,     RS_ON_STATE
        PULR    R7
@@of_rsq:
        JSR     R5,     RS_ON_REQ
        PULR    R7
@@of_input:
        ; payload: tick_lo, tick_hi, input.  The watermark only moves
        ; forward: stale frames (pre-resync leftovers) are dropped.
        MVI     FRMBUF, R0
        CMPI    #5,     R0
        BLT     @@of_iold               ; short frame: +2..+5 would be stale
        MVI     FRMBUF+3, R1
        SWAP    R1,     1
        ADD     FRMBUF+2, R1
        MVI     RMT_WM_HI, R0
        SWAP    R0,     1
        ADD     RMT_WM_LO, R0
        SUBR    R0,     R1              ; frame tick - WM (wrap-safe delta)
        BMI     @@of_iold
        BEQ     @@of_iold
        MVI     FRMBUF+2, R1
        MOVR    R1,     R3
        ADDI    #RMT_RING, R3
        MVI     FRMBUF+4, R0
        MVO@    R0,     R3
        ADDI    #RMT_KP-RMT_RING, R3
        MVI     FRMBUF+5, R0
        MVO@    R0,     R3
        MVI     FRMBUF+2, R0
        MVO     R0,     RMT_WM_LO
        MVI     FRMBUF+3, R0
        MVO     R0,     RMT_WM_HI
@@of_iold:
        PULR    R7
@@of_lobby:
        MVI     NET_ACTIVE, R0
        TSTR    R0
        BNEQ    @@of_ign
        MVI     FRMBUF, R0
        CMPI    #2,     R0
        BLT     @@of_ign                ; no count byte
        ; copy count + 9*count into LOBBY_CACHE (clamped to 8 entries)
        MVI     FRMBUF+2, R2
        CMPI    #8,     R2
        BLT     @@of_lc
        MVII    #8,     R2
@@of_lc:
        ; the frame must really carry 9 bytes per entry we are about to
        ; copy, else the copy drags in stale FRMBUF tail bytes
        MOVR    R2,     R1
        SLL     R1,     2
        SLL     R1,     1
        ADDR    R2,     R1              ; 9 * count
        ADDI    #2,     R1
        CMP     FRMBUF, R1
        BGT     @@of_ign
        SUBI    #2,     R1              ; back to 9 * count
        MVO     R2,     LOBBY_CNT
        MVI     MENU_SEL, R0
        CMPR    R2,     R0
        BLT     @@of_selok
        CLRR    R0
        MVO     R0,     MENU_SEL
@@of_selok:
        MVII    #FRMBUF+2, R4
        MVII    #LOBBY_CACHE, R5
        INCR    R1                      ; + count byte
@@of_cc:
        MVI@    R4,     R0
        MVO@    R0,     R5
        DECR    R1
        BNEQ    @@of_cc
        JSR     R5,     SES_RENDER
@@of_ign:
        PULR    R7
@@of_start:
        ; payload: role, seed_lo, seed_hi, delay, opp[8]
        MVI     FRMBUF, R0
        CMPI    #13,    R0
        BLT     @@of_ign                ; short frame: opp name would be stale
        MVI     FRMBUF+2, R0
        MVO     R0,     NET_ROLE
        MVI     FRMBUF+3, R0
        MVO     R0,     RNG_LO
        MVI     FRMBUF+4, R0
        MVO     R0,     RNG_HI
        MVI     FRMBUF+5, R0
        MVO     R0,     NET_DELAY
        MVII    #FRMBUF+6, R4
        MVII    #OPP_NAME, R5
        MVII    #8,     R1
@@of_on:
        MVI@    R4,     R0
        MVO@    R0,     R5
        DECR    R1
        BNEQ    @@of_on
        CLRR    R0
        MVO@    R0,     R5
        JSR     R5,     LS_RING_INIT    ; idle-fill all four input rings
        JSR     R5,     RS_CLR_CRC      ; ring lives outside the zeroed block:
                                        ;  a reset leaves the last match's
                                        ;  records in it, and those alias the
                                        ;  new match's ticks exactly
        MVI     NET_DELAY, R0
        DECR    R0
        MVO     R0,     RMT_WM_LO
        CLRR    R0
        MVO     R0,     RMT_WM_HI
        MVO     R0,     TICK_LO
        MVO     R0,     TICK_HI
    IF NET_FUZZ <> 0
        ; per-console fuzz seed from boot entropy (title-wait RNG stir)
        MVI     EXEC_RNG, R0
        MVO     R0,     SLF_LO
        SWAP    R0,     1
        MVO     R0,     SLF_HI
    ENDI
        MVII    #1,     R0
        MVO     R0,     NET_ACTIVE
        PULR    R7
@@of_pl:
        MVII    #1,     R0
        MVO     R0,     PEER_WHY        ; the server saw the peer go, cleanly
        MVO     R0,     NET_DROPPED
        JSR     R5,     LS_IDLE_RMT
        PULR    R7

; ---------------------------------------------------------------------------
; SES_RENDER -- lobby list rows from LOBBY_CACHE + cursor.
; ---------------------------------------------------------------------------
SES_RENDER:
        PSHR    R5
        ; Redraw the prompt every time: it also restores the row after a
        ; transient "joining"/"already in a game" notice has used it.
        MVII    #C_WHITE, R0
        MVO     R0,     UI_COLOR
        MVII    #ROW_PROMPT, R0
        MVII    #STR_PICK, R1
        JSR     R5,     UI_PRINT
        ; clear rows 4-11
        MVII    #$200+20*ROW_LIST, R4
        MVII    #160,   R1
        CLRR    R0
@@sr_c: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@sr_c
        MVI     LOBBY_CNT, R2
        TSTR    R2
        BEQ     @@sr_done
        CLRR    R3                      ; entry index
@@sr_row:
        ; offset = 20*(ROW_LIST+i) + 2
        MOVR    R3,     R0
        ADDI    #ROW_LIST, R0
        MOVR    R0,     R1
        SLL     R1,     2
        ADDR    R0,     R1              ; *5
        SLL     R1,     2               ; *20
        ADDI    #2,     R1
        MVO     R1,     PP_TMP
        ; name ptr = LOBBY_CACHE + 1 + 9*i
        MOVR    R3,     R2
        SLL     R2,     2
        SLL     R2,     1
        ADDR    R3,     R2
        ADDI    #LOBBY_CACHE+1, R2
        ; status byte after the name: grey out anyone already in a match, so
        ; the unselectable entries look unselectable
        MOVR    R2,     R4
        ADDI    #8,     R4
        MVI@    R4,     R0
        MVII    #C_WHITE, R1
        TSTR    R0
        BEQ     @@sr_idle
        MVII    #C_BLACK, R1
@@sr_idle:
        MVO     R1,     UI_COLOR
        MVI     PP_TMP, R0
        MOVR    R2,     R1
        MVII    #8,     R2
        JSR     R5,     UI_PRINTN
        ; cursor
        MVI     MENU_SEL, R0
        CMPR    R3,     R0
        BNEQ    @@sr_nc
        MVI     PP_TMP, R0
        DECR    R0
        DECR    R0
        ADDI    #$200,  R0
        MOVR    R0,     R4
        MVII    #(62-32) SHL 3 OR C_YELLOW, R0    ; '>'
        MVO@    R0,     R4
@@sr_nc:
        INCR    R3
        CMP     LOBBY_CNT, R3
        BLT     @@sr_row
@@sr_done:
        MVII    #C_WHITE, R0
        MVO     R0,     UI_COLOR
        PULR    R7

; SES_PAUSE -- ~2 seconds of busy wait.
SES_PAUSE:
        PSHR    R5
        MVII    #120,   R2
@@sp_o: MVII    #$0400, R1
@@sp_i: DECR    R1
        BNEQ    @@sp_i
        DECR    R2
        BNEQ    @@sp_o
        PULR    R7

; SES_HOLD -- hold the matched screen up long enough to read (~5 s), pumping
; the socket throughout.  A plain busy wait would be simpler but both consoles
; are already NET_ACTIVE here, so whichever one starts ticking first is
; sending INPUT frames at us the whole time; draining them keeps the FujiNet
; read buffer from overflowing and hands LS_PASS a warm watermark.
SES_HOLD:
        PSHR    R5
        MVII    #150,   R0
        MVO     R0,     SES_TMR_LO
@@sh_o: JSR     R5,     SES_PUMP
        MVII    #$1400, R1              ; ~30k cycles: pace it at ~30 pumps/s
@@sh_i: DECR    R1
        BNEQ    @@sh_i
        MVI     SES_TMR_LO, R0
        DECR    R0
        MVO     R0,     SES_TMR_LO
        BNEQ    @@sh_o
        PULR    R7

; SES_FLEN -- body-length bounds for every frame type the console can
; legitimately RECEIVE, indexed by type ($00-$0F): low byte = min, high byte
; = max, $0000 = a type that only ever travels outbound.  Bounds mirror
; server/bbnet_server.py: LOBBY is capped at 8 entries (2 + 9*8), STATE is
; 3 (END) / 5 (BEGIN) / 4..99 (a RS_CHUNK data chunk + 3 header bytes).
SES_FLEN:
        DECLE   $0000                   ; $00 --
        DECLE   $0000                   ; $01 HELLO      outbound
        DECLE   $0000                   ; $02 LIST       outbound
        DECLE   $4A02                   ; $03 LOBBY      2..74
        DECLE   $0000                   ; $04 JOIN       outbound
        DECLE   $0D0D                   ; $05 START      13
        DECLE   $0505                   ; $06 INPUT      5
        DECLE   $0505                   ; $07 CRC        5
        DECLE   $6303                   ; $08 STATE      3..99
        DECLE   $0303                   ; $09 RESYNC     3
        DECLE   $0000                   ; $0A BYE        outbound
        DECLE   $0101                   ; $0B PEER_LEFT  1
        DECLE   $0000                   ; $0C PING       outbound
        DECLE   $0101                   ; $0D PONG       1
        DECLE   $0000                   ; $0E --
        DECLE   $0000                   ; $0F --

STR_TITLE:      STRING  "NFL FOOTBALL NETPLAY"
                DECLE   0
STR_NOFN:       STRING  "NO FUJINET - LOCAL GAME"
                DECLE   0
STR_NOSRV:      STRING  "NO SERVER ERR "
                DECLE   0
STR_HELLO:      STRING  "NAME: "
                DECLE   0
; Prompt-row strings are padded to the full 20 columns: they overwrite each
; other in place, and a shorter one would leave the tail of the last behind.
STR_PICK:       STRING  "DISC/2/8  ENTER=PLAY"
                DECLE   0
STR_JOINING:    STRING  "JOINING...          "
                DECLE   0
STR_BUSY:       STRING  "ALREADY IN A GAME   "
                DECLE   0
STR_VS:         STRING  "VS "
                DECLE   0
STR_YOUP1:      STRING  "YOU ARE HOME"
                DECLE   0
STR_YOUP2:      STRING  "YOU ARE VISITOR"
                DECLE   0
STR_OPPP1:      STRING  "THEY ARE HOME"
                DECLE   0
STR_OPPP2:      STRING  "THEY ARE VISITOR"
                DECLE   0
STR_PICKS:      STRING  "VISITOR BALL FIRST"
                DECLE   0
STR_USELEFT:    STRING  "USE LEFT CONTROLLER"
                DECLE   0
STR_GUEST:      STRING  "GUEST"
                DECLE   0
STR_GONE:       STRING  "OPPONENT LEFT"
                DECLE   0
STR_LOST:       STRING  "CONNECTION LOST"
                DECLE   0
STR_RESET:      STRING  "PRESS RESET"
                DECLE   0
STR_DIAG:       STRING  "SLIP REJ TMO ERR"
                DECLE   0
