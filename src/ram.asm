; Netcode RAM layout -- PiRTO II cart RAM, 8-bit cells.
; Declare only $8000-$9BFF in the cfg: $9C00-$9FFF is the FujiNet mailbox,
; and claiming it breaks jzIntv's --fujinet peripheral (AND-ed bus reads).
;
; IMPORTANT -- $8000-$807F is a STIC decode alias and must stay UNUSED:
; the STIC only partially decodes its address, so its control registers
; also respond at $4000, $8000 and $C000 (jzIntv registers "STIC (alias)"
; at $8000-$803F, and $8040-$807F is the GROM visibility window).  A write
; to a cell there programs a real STIC register: e.g. a NET_READ byte
; count stored at $8032 set the top-border-extension bit ($0032), which
; painted border over BACKTAB row 0 and hid the VSTR/HOME scoreboard
; whenever netplay traffic flowed.  Nothing may live below $8080.

NET_RAM         EQU     $8080   ; base of netcode state (zeroed by NET_START)
NET_RAM_SIZE    EQU     $0180   ; $8080-$81FF zeroed at start

SLOW_CNT        EQU     $8102   ; virtualized slow-tick countdown (timer entry
                                ;  2, interval 15) -- sim state, freezes with
                                ;  everything else during a stall
RS_SPARE        EQU     $8103   ; resync image tail padding (always 0)
DELAY_EN        EQU     $8105   ; virt-dispatch delay depth in game ticks
                                ;  (0 = same-tick dispatch, stock feel)
RNG_LO          EQU     $8106   ; canonical game RNG (mirrors $035E across
RNG_HI          EQU     $8107   ;  sim ticks; the EXEC's per-frame stir of
                                ;  $035E between ticks becomes irrelevant)
TICK_LO         EQU     $8108   ; 16-bit sim (game) tick counter
TICK_HI         EQU     $8109
SLF_LO          EQU     $810A   ; scripted-input PRNG state (spike c)
SLF_HI          EQU     $810B
FRM_CTR         EQU     $810C   ; frame counter for the stall injector
SCR_IDX         EQU     $810D   ; demo-script row offset ($FF = done -> fuzz)
SCR_CNT         EQU     $810E   ; ticks consumed in the current script row
MB_DEV          EQU     $8114   ; mailbox transaction arguments
MB_CMD          EQU     $8115
MB_NPARAM       EQU     $8116
MB_TXLEN_LO     EQU     $8117
MB_TXLEN_HI     EQU     $8118
MB_OK           EQU     $8119   ; 1 = last transaction ACKed
MB_ERR          EQU     $811A   ; FN_ERR / status code (0 = timeout)
MB_PMAX_LO      EQU     $811B   ; worst-case ACKSEQ poll iterations seen
MB_PMAX_HI      EQU     $811C
NAVAIL_LO       EQU     $811D   ; NET_STATUS bytes-available
NAVAIL_HI       EQU     $811E
NREQ_LO         EQU     $8130   ; NET_READ/WRITE length argument
NREQ_HI         EQU     $8131
NGOT_LO         EQU     $8132   ; NET_READ actual byte count
NGOT_HI         EQU     $8133

FIRSTC_LO       EQU     $8110   ; (spike c) tick+1 of first game RNG use
FIRSTC_HI       EQU     $8111
RNGP_LO         EQU     $8112   ; (spike c) previous canonical RNG
RNGP_HI         EQU     $8113

RX_WR           EQU     $8134   ; net stream accumulator write index (mod 256)
RX_RD           EQU     $8135   ; read index
NAME_BUF        EQU     $8150   ; player name, 8 cells + NUL
NAME_LEN        EQU     $8159
MENU_SEL        EQU     $815A   ; lobby cursor index
MENU_PREV       EQU     $815B   ; previous raw controller value (edge detect)
LOBBY_CNT       EQU     $815C   ; entries in LOBBY_CACHE
SES_TMR_LO      EQU     $815D   ; lobby refresh pacing counter
SES_TMR_HI      EQU     $815E
NET_ROLE        EQU     $8160   ; 0 = host (left ctrl), 1 = guest (right)
NET_DELAY       EQU     $8161   ; lockstep input delay d (game ticks)
NET_ACTIVE      EQU     $8162   ; 1 = lockstep netplay engaged
NET_DROPPED     EQU     $8163   ; 1 = peer gone / timeout
RMT_WM_LO       EQU     $8164   ; highest remote input tick received
RMT_WM_HI       EQU     $8165
SES_STAT        EQU     $8166   ; session progress/error marker (UI/debug)
CRC_PH          EQU     $8167   ; crc send phase counter
LS_TMPB         EQU     $8168   ; lockstep scratch
LS_TMPB2        EQU     $8169
LS_FROZE        EQU     $816A   ; 1 = ISR phase counter currently frozen
LS_SAVE102      EQU     $816B   ; saved $0102 during a stall
LS_WAITC_LO     EQU     $816C   ; gate pump-round counter
LS_WAITC_HI     EQU     $816D
PP_TMP          EQU     $816E   ; pump scratch
SES_SAVE102     EQU     $816F   ; ISR phase counter saved across the session
RESYNC_HOLD     EQU     $8090   ; 1 = sim held for a state resync
RS_R_LO         EQU     $8091   ; agreed resume tick R
RS_R_HI         EQU     $8092
RS_TO_LO        EQU     $8093   ; hold timeout pump counter
RS_TO_HI        EQU     $8094
RS_TMP          EQU     $8095
RS_POS_LO       EQU     $8096   ; serializer/applier image position
RS_POS_HI       EQU     $8097
RS_TMP2         EQU     $8098
OWN_CRC         EQU     $8A00   ; 8 x [tick_lo, tick_hi, crc_lo, crc_hi]
RMT_KP          EQU     $8600   ; remote keypad cell ($0121-family) per tick
LOC_KP          EQU     $8700   ; local keypad cell per tick
GAME_TBL_LO     EQU     $80C0   ; game's live input-handler table ($035D),
GAME_TBL_HI     EQU     $80C1   ;  captured around each game tick
VD_TMP          EQU     $80C2   ; virtual dispatcher scratch
VD_SIDE         EQU     $80C3
VD_CUR          EQU     $80C4
VD_PREV         EQU     $80C5
VD_KP           EQU     $80C6
VD_KPPRE        EQU     $80C7
OPP_NAME        EQU     $8170   ; opponent name, 8 cells + NUL

; Field diagnostics.  A live session over real hardware leaves no log, so
; these saturating counters are the only evidence an incident produces --
; dump them with `m 8180 4` after a bad game.
DIAG_SLIP       EQU     $8180   ; parser resyncs (byte stream had slipped)
DIAG_REJ        EQU     $8181   ; STATE chunks refused by the resync guards
DIAG_TMO        EQU     $8182   ; mailbox transactions that timed out
DIAG_ERR        EQU     $8183   ; mailbox transactions that replied an error

UI_COLOR        EQU     $818B   ; current text colour, palette index 0-15
                                ;  (UI_CLS resets it to white)

; Live performance HUD (NET_HUD builds only -- see src/netcode/hud.asm).
; Everything but HUD_RSY is a per-window figure, cleared every 16 game ticks
; when the row is redrawn.
HUD_PLL         EQU     $8190   ; mailbox poll iterations this window, 16-bit
HUD_PLH         EQU     $8191   ;  (the high cell is what gets displayed)
HUD_STL         EQU     $8192   ; gate stall rounds this window (saturating)
HUD_HLD         EQU     $8193   ; resync-hold pump rounds this window
HUD_LEAD        EQU     $8194   ; smallest (remote watermark - tick) seen, 0-15
HUD_RSY         EQU     $8195   ; resyncs completed since the session started

RS_PEND         EQU     $8187   ; 1 = resync wanted, waiting for ball-dead
RS_PTMO         EQU     $8188   ; game ticks waited so far
RS_WAITED       EQU     $8189   ; ticks the last resync waited (diagnostic)
RS_GATE         EQU     $818A   ; why the last push fired: 1 = ball dead, 2 = cap

PEER_SCR        EQU     $8185   ; 1 = peer-left screen up, sim stopped for good
PEER_WHY        EQU     $8186   ; 1 = server said PEER_LEFT, 0 = we timed out

RXACC           EQU     $8200   ; 256-byte circular net stream accumulator
FRMBUF          EQU     $8300   ; current frame, linear (len,type,payload)
LOBBY_CACHE     EQU     $8380   ; last LOBBY payload (count + 9/entry)
RMT_RING        EQU     $8400   ; remote input byte per tick (mod 256)
LOC_RING        EQU     $8500   ; delayed local input byte per tick (mod 256)

TRACE_RING      EQU     $9000   ; 256 x 2-byte per-tick state checksums

; The game's patched polled-input read ($5637) lands here.  Football reads
; [$011F + (G_016B XOR k)] -- a computed index selecting EITHER controller
; -- so this pair must be consecutive cells in the EXEC's left,right order.
; Local modes feed it pass-through from the live decoded cells (stock
; behaviour: the game sees the previous pass's scan output); the lag/det
; spikes feed it from the delayed rings; LS_PASS feeds it by role from the
; lockstep rings.
SHADOW_CTRL     EQU     $8140   ; virtual $011F (left decoded input)
SHADOW_CTRL_R   EQU     $8141   ; virtual $0120 (right decoded input)

; The game's patched raw-port latch reads ($5729/$572E) land here.  The
; values feed only the EXEC scan's edge cells $0123/$0124 (never read back
; by cart code), so these are hygiene, kept pass-through from the live
; ports in every mode -- the scan then behaves exactly as stock, which is
; what gives the captured $011F stream its stock fresh/held flavours.
SHADOW_RAW_L    EQU     $8142   ; virtual $01FF (left port, active low)
SHADOW_RAW_R    EQU     $8143   ; virtual $01FE (right port)
