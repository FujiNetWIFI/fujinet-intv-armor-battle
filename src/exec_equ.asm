; EXEC ROM entry points and RAM locations used by the netcode patch.
; Derived from build/exec.dis (dis1600 of the console EXEC) -- see
; spikes/NOTES.md for the analysis behind each.

X_MUSIC_TICK    EQU     $1A71   ; music note-timer routine (timer entry 0)
X_RAND1         EQU     $167D   ; LFSR random, state at EXEC_RNG
X_RAND2         EQU     $169E

EXEC_RNG        EQU     $035E   ; 16-bit LFSR state (System RAM)
EXEC_ISR_DEF    EQU     $1126   ; the EXEC's default game-time ISR (what
                                ;  $0100/$0101 hold at every tick boundary)

; EXEC decoded per-controller input bytes, rewritten by the controller scan
; each main-loop pass.  Football is the Baseball hybrid: it POLLS the
; decoded cells (one computed-index read at $5636, patched to the shadow
; pair) AND receives events through the $035D dispatch.  It also
; pre-latches the RAW cells inside its fast tick (L_5722, gated by the
; per-phase input mask G_0182 AND 3) to force the scan's held path.
EXEC_IN_L       EQU     $011F   ; left controller decoded input
EXEC_IN_R       EQU     $0120   ; right controller decoded input
EXEC_KP_L       EQU     $0121   ; left controller keypad event cell
EXEC_KP_R       EQU     $0122
EXEC_HTBL       EQU     $035D   ; input-handler table pointer (game-managed)
EXEC_RAW_L      EQU     $0123   ; left controller raw (inverted port) value
EXEC_RAW_R      EQU     $0124

; Original game entry points we re-dispatch from the master tick.
; NOTE the original table lists SLOW before FAST -- the dispatcher must
; preserve that order on passes where both fire.
FB_TICK_SLOW    EQU     $56EF   ; game clock (was timer entry 1, interval 15)
FB_TICK_FAST    EQU     $5034   ; game tick  (was timer entry 2, interval 1)
FB_START        EQU     $5075   ; original start-of-game vector target

; Game phase cell G_016A, values 0-$B, set only via the setter at $5597
; (inline param), which also loads the per-phase input-enable mask into
; G_0182 from the table at $559D.  Phase 0 + the EXEC null handler table
; ($1906) installed = the between-plays/reset state (dead ball candidate --
; pinned live at M8).  G_016B = controller/possession selector (XOR-swapped),
; G_0181 bit 0 = game-clock hold, $016F/$0170 = the game clock itself.
FB_PHASE        EQU     $016A

; The game's VBLANK display dance (same class as Auto Racing's): the fast
; tick's display routine (L_54E8, called at $5047 EVERY tick) saves the ISR
; vector to $0163/$0164, installs the game ISR body at $5524, and the
; mainline spins on the mailbox cell $0169 until the body has shifted the
; BACKTAB rows, written hscroll $0030 from FB_HSCROLL_CELL and display
; enable $0020, and restored the saved vector.  All backing cells live in
; $015D-$01EF (CRC-covered); at tick boundaries the vector is EXEC_ISR_DEF.
FB_ISR_BODY     EQU     $5524   ; game ISR body ($0101 reads $55 mid-dance)
FB_HSCROLL_CELL EQU     $0162   ; hscroll backing cell (-> $0030 each dance)
