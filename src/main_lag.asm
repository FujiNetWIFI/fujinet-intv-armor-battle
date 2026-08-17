; Interception proof build: the deterministic demo script (SCRIPT_TBL)
; drives both pads, with every input delayed by 20 game ticks (1 second).
; Comparing state milestones (battle start, tank rotation) against the
; same script at d = 0 (make det's A build) must show a shift of exactly
; d on BOTH input surfaces.  Scripted rather than live-injected: jzIntv
; breakpoint-driven injection is not run-to-run deterministic (see
; spikes/NOTES.md, M4), so the proof is in-ROM.
SPIKE_DELAY     EQU     20
SPIKE_SCRIPT    EQU     1
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
