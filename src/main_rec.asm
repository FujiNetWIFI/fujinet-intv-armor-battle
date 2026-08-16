; Record build: pass-through inputs, captures ($011F,$0120) per game tick
; into $9000-$97FF (1024 ticks, ~34s). Play in windowed jzintv, hit F4 for
; the debugger, then: m 8100 20  /  m 9000 800  -> save log for mk_replay.py
SPIKE_DELAY     EQU     0
SPIKE_SCRIPT    EQU     0
SPIKE_TRACE     EQU     0
STALL_N         EQU     0
SPIKE_ECHO      EQU     0
SPIKE_RECORD    EQU     1
SPIKE_REPLAY    EQU     0
NET_SESSION     EQU     0
AUTO_JOIN       EQU     0
NET_FUZZ        EQU     0
NET_HUD         EQU     0
SPIKE_VIRT      EQU     0
        INCLUDE "src/core.asm"
