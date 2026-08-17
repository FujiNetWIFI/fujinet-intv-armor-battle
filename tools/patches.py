# In-place patch map for armor.bin (word address -> as1600 expression).
# Symbols are defined in src/hook.asm / src/ram.asm.  Every site confirmed in
# build/armor.dis (see spikes/NOTES.md, M2).  Building with
# tools/dump_rom.py and NO patch file must stay byte-identical to the
# original (make verify-org).
{
    # --- Cart header ---
    # $5002/$5003: EXEC timer table pointer -> relocated table in $6000 seg.
    0x5002: "NEW_TIMER_TBL AND $FF",
    0x5003: "NEW_TIMER_TBL SHR 8",
    # $5004/$5005: start-of-game vector -> netcode init shim (falls through
    # to the original $505A).  The in-game restart is `J L_5061` at $5E2F,
    # which bypasses the header vector, so the session/lobby runs exactly
    # once at cold boot.
    0x5004: "NET_START AND $FF",
    0x5005: "NET_START SHR 8",

    # --- EXEC timer-API call sites -> virtualized-tick shims ---
    # All three sites pass R1 = $5054, the ABSOLUTE address of the original
    # table's entry 1 (the game's 20 Hz tick).  X_TIMER_STOP/START convert
    # that address to a countdown-slot pointer relative to the header table
    # pointer and write interval|$8000 / interval&$7FFF there; with the
    # table relocated the arithmetic lands on a garbage slot, and pointing
    # R1 at the new table would let the game stop MASTER_TICK itself.  The
    # shims flip the sim-state flag AB_TICK_EN instead; MASTER_TICK gates
    # its AB_TICK call on it.  The SDBD/MVII #$5054,R1 prefixes stay (the
    # shims ignore R1).  Entry 0 (EXEC music timer) keeps slot 0 in the
    # relocated table, so the music system's own header-relative re-arms
    # stay correct without any shim.
    0x50BD: "((AB_STOP_SHIM SHR 10) SHL 2) OR $0100",   # JSR R5 @ $50BC (boot screen)
    0x50BE: "AB_STOP_SHIM AND $3FF",
    0x5288: "((AB_START_SHIM SHR 10) SHL 2) OR $0100",  # JSR R5 @ $5287 (battle start)
    0x5289: "AB_START_SHIM AND $3FF",
    0x5ED4: "((AB_STOP_SHIM SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5ED3 (battle end)
    0x5ED5: "AB_STOP_SHIM AND $3FF",

    # --- Game RNG call sites -> canonical-RNG wrappers ---
    # The EXEC sound engine calls X_RAND1 every frame while noise SFX play
    # (caller $1CCE), advancing the shared LFSR at $035E in real-frame time.
    # The game's nine CONSUMER call sites are routed through wrappers that
    # swap the canonical (sim-space) RNG in and out around the call.
    # The tenth site, JSR X_RAND1 at $52DF, is the battle loop's per-pass
    # STIR (R0=1, result discarded) -- the cart-resident clone of the EXEC
    # main loop's own stir.  It stays UNPATCHED so it keeps churning the
    # volatile $035E exactly like the EXEC loop's stir does during menus.
    0x5D20: "((NET_RAND1 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5D1F
    0x5D21: "NET_RAND1 AND $3FF",
    0x5194: "((NET_RAND2 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5193 (map select)
    0x5195: "NET_RAND2 AND $3FF",
    0x5686: "((NET_RAND2 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5685
    0x5687: "NET_RAND2 AND $3FF",
    0x5691: "((NET_RAND2 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5690
    0x5692: "NET_RAND2 AND $3FF",
    0x5CD8: "((NET_RAND2 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5CD7
    0x5CD9: "NET_RAND2 AND $3FF",
    0x5CF5: "((NET_RAND2 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5CF4
    0x5CF6: "NET_RAND2 AND $3FF",
    0x5D6D: "((NET_RAND2 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5D6C (mine gen)
    0x5D6E: "NET_RAND2 AND $3FF",
    0x5D74: "((NET_RAND2 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5D73 (mine gen)
    0x5D75: "NET_RAND2 AND $3FF",
    0x5D94: "((NET_RAND2 SHR 10) SHL 2) OR $0100",   # JSR R5 @ $5D93
    0x5D95: "NET_RAND2 AND $3FF",

    # --- Polled decoded-input read (inside the game tick at $554E) ---
    # MVII #$011F,R3 operand at $5569; the tick adds the player index (R0 =
    # 0 left, 1 right) and does MVI@, so this one site reads BOTH seats.
    # SHADOW_CTRL/SHADOW_CTRL_R must therefore be consecutive cells in
    # left,right order, exactly like the EXEC pair.  Armor Battle is the
    # Baseball hybrid model: it polls AND dispatches.
    0x5569: "SHADOW_CTRL",                           # was MVII #$011F @ $5568

    # --- Raw-port latch reads (inside the battle main-loop clone L_52B5) ---
    # MVI $01FE/$01FF operands at the top of the cart's own main loop (the
    # battle abandons the EXEC loop entirely: SP is reset to $02F1 at $52B3
    # and the cart runs its own phase-wait/latch/$11FA/$14F1/$17D5/$1AAD
    # pass).  Values are guarded (skip when port reads $BE), complemented,
    # and stored to the EXEC edge cells $0123/$0124.  Redirected to the
    # shadow pair so no live-port read remains in game code.  Note right
    # port first, then left.
    0x52C0: "SHADOW_RAW_R",                          # was MVI $01FE @ $52BF
    0x52C9: "SHADOW_RAW_L",                          # was MVI $01FF @ $52C8
}
