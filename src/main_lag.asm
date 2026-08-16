; Interception proof build: identical to main_hook but inputs are delayed by
; 30 game ticks (~1 second).  If the game visibly responds one second late,
; the shadow-input interception and the delay-queue machinery both work.
SPIKE_DELAY     EQU     20
SPIKE_SCRIPT    EQU     0
SPIKE_TRACE     EQU     0
STALL_N         EQU     0
SPIKE_ECHO      EQU     0
SPIKE_RECORD    EQU     0
SPIKE_REPLAY    EQU     0
NET_SESSION     EQU     0
AUTO_JOIN       EQU     0
NET_FUZZ        EQU     0
NET_HUD         EQU     0
SPIKE_VIRT      EQU     1
        INCLUDE "src/core.asm"
