; EXEC ROM entry points and RAM locations used by the netcode patch.
; Derived from build/exec.dis (dis1600 of the console EXEC) -- see
; spikes/NOTES.md for the analysis behind each.

X_MUSIC_TICK    EQU     $1A71   ; music note-timer routine (timer entry 0)
X_RAND1         EQU     $167D   ; LFSR random, state at EXEC_RNG
X_RAND2         EQU     $169E

EXEC_RNG        EQU     $035E   ; 16-bit LFSR state (System RAM)
EXEC_ISR_DEF    EQU     $1126   ; the EXEC's default game-time ISR (what
                                ;  $0100/$0101 hold at every tick boundary --
                                ;  Armor Battle never installs its own ISR)

; EXEC decoded per-controller input bytes, rewritten by the controller scan
; each main-loop pass.  Armor Battle is the Baseball hybrid: it POLLS the
; decoded cells (one computed-index read at $5568, MVII base + player index,
; patched to the shadow pair) AND receives events through the $035D
; dispatch.  It also pre-latches the RAW cells at the top of its battle
; main-loop clone (L_52B5, $BE ghosting guard) to force the scan's held
; path.
EXEC_IN_L       EQU     $011F   ; left controller decoded input
EXEC_IN_R       EQU     $0120   ; right controller decoded input
EXEC_KP_L       EQU     $0121   ; left controller keypad event cell
EXEC_KP_R       EQU     $0122
EXEC_HTBL       EQU     $035D   ; input-handler table pointer (game-managed)
EXEC_RAW_L      EQU     $0123   ; left controller raw (inverted port) value
EXEC_RAW_R      EQU     $0124

; Original game entry points we re-dispatch from the master tick.
; The original table has ONE game entry ($554E, interval 1, 20 Hz) -- no
; slow/fast ordering question.  The game stops/starts that entry through
; the EXEC timer APIs (three sites, all passing the entry's original
; absolute address $5054); the shims virtualize it as AB_TICK_EN.
AB_TICK         EQU     $554E   ; game tick (was timer entry 1, interval 1)
AB_START        EQU     $505A   ; original start-of-game vector target

; The three input handler tables the game installs in EXEC_HTBL:
;   $1906  EXEC-resident ALL-ZERO table (the EXEC's own null table) --
;          installed at boot ($50C3) and battle end ($5EE7)
;   $50DB  boot/"Push disc to play" screen: 5 slots, all -> $518B
;          (the battle-start handler: random map select + terrain render
;          + tank deploy + SP reset to $02F1 + enter the clone loop)
;   $52E4  battle: slot0 NULL, slot1 $5BE3, slot2 $5C74 (disc),
;          slot3/4 $5C2C
; Post-battle continuation (explosion end, tank-count decrement, restart
; via J L_5061 at $5E2F) runs on the OBJECT-WALK callback surface
; (.EXEC $11FA, mainline, input-independent), not the $035D dispatch.
AB_HTBL_NULL    EQU     $1906
AB_HTBL_MENU    EQU     $50DB
AB_HTBL_BATTLE  EQU     $52E4

; Game state cells (all confirmed in build/armor.dis):
;   $015D/$015E  Blue / Black tank counts (persistent across battles;
;                shown on the boot screen; the M8 fault cell is $015D)
;   $0187        battle-over flag: cleared by $518B at battle start, set
;                NONZERO at battle end via `MVO R6,$0187` (stores SP as a
;                cheap any-nonzero) -- tested TSTR-only by five handlers.
;                Value is call-depth dependent, so virt vs hook bit-compare
;                windows must end before a battle does; across two netplay
;                consoles the depth is identical and the CRC is safe.
;   $011A        collision-interaction mask, written $0022 once per battle
;                setup, read only by the EXEC object walk.  Deterministic
;                config; lives in the excluded EXEC range and needs no CRC.
;   $0315-$031B  cart globals ABOVE the reset stack base ($02F1): terrain
;                map pointer ($0316), BACKTAB/gen pointers, walk scratch.
;                Inside the range the standard model excludes as "stack" --
;                Armor Battle is the first cart to keep real state there,
;                so the CRC range and resync image carry $0315-$031B.
AB_TANKS_BLUE   EQU     $015D
AB_TANKS_BLACK  EQU     $015E
AB_BATTLE_OVER  EQU     $0187
AB_XMASK_CELL   EQU     $011A

; The battle main-loop clone (entered from $518B with SP reset to $02F1;
; the EXEC loop at $108F never runs again after the first battle starts).
; Pass order differs from the EXEC loop: raw-port latch -> $11FA object/
; collision walk -> $14F1 scan -> $17D5 timer dispatch (= MASTER_TICK,
; where the netcode gate lives) -> $1AAD sound -> X_RAND1 stir.  The scan
; therefore runs BEFORE the dispatch each pass; the $035D null installed at
; the END of MASTER_TICK covers the NEXT pass's scan, same invariant as the
; EXEC-loop games.
AB_MAIN_LOOP    EQU     $52B5
