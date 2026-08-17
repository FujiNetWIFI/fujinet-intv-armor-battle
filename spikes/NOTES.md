# Armor Battle netplay — engineering log

Cart-specific recon, risks, and decisions for the fourth port. EXEC internals
are in the baseball repo's `spikes/NOTES.md`; second-port deltas in the Auto
Racing repo's; third-port deltas in the Football repo's. Structure mirrors the
Football notes: plan-time analysis first, then per-milestone findings, each
plan-time decode marked **[dis]** once confirmed in dis1600.

## Recon results (plan time, `tools/recon.py rom/armor.bin`)

```
armor.bin   4096 words at $5000-$5FFF    md5 7fa60b1cb4adac3088727d5ac53ec183
header:  timer table $5050   start-of-game $505A   GRAM init $5043
         $500D=$00 border ext   $500E=$00 COLOUR STACK   CS0-3 $0E/$03/$0E/$03
         border $01
timer:   entry 0: $1A71 interval $8001  [stopped/one-shot]  EXEC music, keep verbatim
         entry 1: $554E interval $0001  -> 20 Hz, 50 ms tick   ONE game entry
RNG:     10 sites (most of any cart profiled; Baseball 5, AR 4, FB 3, Boxing 8)
         X_RAND1 $52DF ($52E0/1), $5D1F ($5D20/1)
         X_RAND2 $5193 ($5194/5), $5685 ($5686/7), $5690 ($5691/2),
                 $5CD7 ($5CD8/9), $5CF4 ($5CF5/6), $5D6C ($5D6D/E),
                 $5D73 ($5D74/5), $5D93 ($5D94/5)
timer API: $50BC JSR $1838 STOP, $5ED3 JSR $1838 STOP, $5287 JSR $1844 START
cells:   $011F read $5569 (MVII base load, R3)    $0123 MVO $52D0   $0124 MVO $52C7
         $035D installs: $50C4, $50D9, $528F, $5EE8   (FOUR - phase machine)
display: 1 STIC write candidate ($508E "MVO R1,$0001"), 0 GRAM writes
EXEC calls: $169E x8, $1BBE x7, $16B2 x4, $17AE x4, $1867 x3, $1A62 x3,
            $187B x2, $1738 x2
```

Read against `PORTING.md` §3: simplest timer table of the four carts (single
game entry, interval 1 — no SLOW_CNT, no slow/fast ordering question); colour
stack (`$500E=$00`) so the Football repo's `ui/text.asm` (Baseball's
colour-stack variant) is correct as copied; effectively static display so the
§7.5 header reassert applies. Against that: the most RNG sites yet, three
timer-API calls (the hazard class only Baseball hit, once), and the biggest
`$035D` phase machine yet.

## Plan-time raw-word decodes

### Timer-API sites: all three pass the ABSOLUTE address of table entry 1

All three sites share one idiom (raw words):

```
$50B8/$5283/$5ECF:  0001            SDBD
                    02B9 0054 0050  MVII #$5054, R1     ; = old timer table + 4
$50BC:              0004 0118 0038  JSR  R5, $1838      ; X_TIMER_STOP
$5287:              0004 0118 0044  JSR  R5, $1844      ; X_TIMER_START
$5ED3:              0004 0118 0038  JSR  R5, $1838      ; X_TIMER_STOP
```

`$5054` = entry 1 of the ROM table at `$5050` = **the game's own 20 Hz tick
entry**. Exactly Baseball's `$509F` hazard (hardcoded original-table address);
after relocation the address is stale, and re-pointing it at the new table
would let the game stop/start MASTER_TICK itself — killing the netcode loop.
Plan: patch each `JSR` operand pair to a shim (`AB_STOP_SHIM` / `AB_START_SHIM`)
that sets/clears a virtualized sim-state flag `AB_TICK_EN`; MASTER_TICK gates
its `AB_TICK` call on the flag. Flag is CRC-covered and rides the resync tail.
The SDBD/MVII prefix words stay (shims ignore R1).

Apparent semantics (confirm at M2): `$50BC` STOP during game init; `$5287`
START right after the battle handler table is installed (battle begins);
`$5ED3` STOP at battle end. I.e. the game tick runs only during battle;
menu/score screens are dispatch-driven. **Open question:** does X_TIMER_START
re-arm interval/countdown state the shim must reproduce, or is entry 1's
countdown slot ($0127) presentation-only once virtualized?

### The four `$035D` installs load THREE distinct tables

```
$50BF: 0001 / 02B8 0006 0019 = MVII #$1906, R0 (SDBD)   $50C3: 0240 035D
$50D4?:0001 / 02B8 00DB 0050 = MVII #$50DB, R0 (SDBD)   $50D8: 0240 035D
$528A: 0001 / 02B8 00E4 0052 = MVII #$52E4, R0 (SDBD)   $528E: 0240 035D
$5EE4?:      02B8 0006 0019 = MVII #$1906, R0 (SDBD)    $5EE7: 0240 035D
```

Tables: **$1906 (EXEC-resident!)** installed at boot and again at battle end;
**$50DB** (cart - title/setup screen?); **$52E4** (cart - battle table,
installed immediately before X_TIMER_START). An EXEC-resident handler table is
a first for the series — census what `$1906` dispatches at M2 (likely the
EXEC's default/null or keypad-wait table). The battle-end state (table =
$1906, tick stopped) is the natural quiescent-gate candidate; a second
candidate is the pre-battle setup screen ($50DB).

### Raw-latch routine (`$52C2` region) — class-3 false positive confirmed in raw words

```
$52C6: 0240 0124   MVO R0, $0124    ; store raw RIGHT latch  <- recon hit, NOT a patch site
$52C8: 0280 01FF   MVI $01FF, R0    ; read LEFT port         <- operand $52C9 IS a patch site
$52CF: 0240 0123   MVO R0, $0123    ; store raw LEFT latch   <- recon hit, NOT a patch site
```

The matching `MVI $01FE` (right port read) must precede `$52C6` — find its
operand word at M2. Patch map: `$52C9` → `SHADOW_RAW_L`, `$xxxx` ($01FE read
operand) → `SHADOW_RAW_R`. Note the store order (right latch stored, then left
port read) differs from Football's routine — decode the whole latch subroutine
at M2 before assuming EXEC-scan-identical behaviour.

### Polled input (`$5569`)

```
$5568: 02BB 011F   MVII #$011F, R3  ; base load, computed read follows
```

Football's class (`ADDI #$011F,R2` there). Operand word `$5569` →
`SHADOW_CTRL`; the shadow pair must be consecutive left,right cells (the game
indexes off the base to pick a controller). **Open question:** recon shows ONE
`$011F` reference and ZERO `$0120` references — chase the indexed read in
dis1600 to confirm both seats really flow through this one site, and find any
`$0121/$0122` keypad-state reads.

### The lone "STIC write" is a misaligned decode (class-1 false positive)

Recon's `$508E MVO R1,$0001` parses differently from a plausible instruction
boundary: `$508E: 0001` = SDBD prefixing `$508F: 02B9 0014 0051` =
`MVII #$5114, R1` (cart address). The competing parse ($508D `0241 0001` =
`MVO R1,$0001`) requires $508C `02BC` to be an instruction start with an
implausible operand. Working hypothesis: **zero real STIC writes; display is
fully static from the header** (best case for §7.5 reassert + resync).
Confirm boundary in dis1600 at M2.

## Mandatory M2 audits (from PORTING.md, all flagged live for this cart)

1. **Sound gate (§7.8):** `$1A62 x3` in the most-called list is exactly the
   `$1A61`-class family the Auto Racing leak came from, and Armor Battle has
   heavy SFX (engines, shots, explosions — likely persistent noise channels).
   Audit every call site and every cart read of `$0149` (X_SFX_OK), `$014A/B`,
   `$0159`, `$0125/6`, `$0143/4`, `$035F`.
2. **ISR dance (§7.10):** grep the dis for `ISRVEC` AND raw `$0100/$0101`
   writes (Football's dance was nearly missed because the dis labels the
   cells, not the addresses). `$5ED2` sits next to the `$5ED3` timer stop —
   Football's game-ISR bodies also lived at `$5ED2/$5F06`; coincidence of
   addresses, but check whether Armor Battle installs ISR bodies at all.
3. **Timer-API semantics:** what X_TIMER_STOP/START at `$1838/$1844` do with
   the entry address in R1 (slot arithmetic relative to the header pointer?)
   — decides the exact shim contract.
4. **Unnamed hot EXEC routines:** identify `$1BBE` (x7), `$16B2`, `$17AE`,
   `$1867`, `$187B`, `$1738` in `build/exec.dis` — any that touch `$035E`,
   sound state, or timers changes the patch map.
5. **Live `w 35D` census** of the three tables + slot layout of `$50DB` and
   `$52E4` (disc/action/keypad slot indexes actually populated).
6. **Seat mapping:** which side is left seat/player 1 (no manual on disk —
   derive from the dis and verify on screen; Baseball's manual was
   load-bearing for this, AR managed empirically).

## M1 findings

- `make verify-org` PASS on the first build — byte-identical rebuild
  (`dump_rom.py` → as1600 → cmp), zero warnings.
- `$0103` measured = **3** with the generic title-skip recipe → pass = 3 NTSC
  frames ≈ 50 ms, 20 passes/s. Fifth cart in a row (Baseball, AR, Boxing,
  Football, now Armor Battle). Timer entry 1 interval 1 → **sim tick = every
  pass = 20 Hz**, `d=3` costs 150 ms.
- At the title screen `$0100/$0101` = `$26/$11` — EXEC default ISR `$1126`
  installed; whether the game ever swaps in its own ISR bodies is still the
  M2 dance audit.
- Wall-clock tick length (3 vs 4 real frames per pass, AR-style dance
  overhang) deferred to the M3 cadence check against the built hook ROM.

## M2 findings (dis1600) — every plan-time decode CONFIRMED

1. **[dis] Timer-API sites**: all three (`$50BC`, `$5287`, `$5ED3`) pass
   R1 = `$5054` = absolute address of original entry 1 exactly as decoded at
   plan time. `X_TIMER_STOP/START` internals (`$183A-$1852`): convert R1 to
   the countdown-slot pointer via `.EXEC.811` (header-table-relative), then
   write `interval|$8000` (STOP) / `interval&$7FFF` (START) to the slot.
   Stale R1 after relocation = garbage slot write → **all three sites
   shimmed** (`AB_STOP_SHIM`/`AB_START_SHIM` → virtualized `AB_TICK_EN`).
   Semantics: tick stopped on the boot screen, started at battle start,
   stopped at battle end. Entry 0 (music) keeps slot 0 → the music system's
   header-relative re-arms need no shim.
2. **[dis] THE HEADLINE: Armor Battle runs its own main-loop clone during
   battle** (`L_52B5`). The battle-start handler `$518B` (dispatched from the
   boot screen's `$50DB` table) generates the map, deploys tanks, **resets SP
   to `$02F1` (`$52B3`) and enters a cart-resident copy of the EXEC loop**:
   phase-wait on `$0102`/`$0103` → raw-port latch (`$01FE` @ `$52BF`, `$01FF`
   @ `$52C8`, `$BE` ghosting guard) → `$11FA` object/collision walk → `$14F1`
   scan → `$17D5` timer dispatch → `$1AAD` sound → `X_RAND1` stir (`$52DF`)
   → loop. The EXEC loop at `$108F` never runs again after the first battle.
   Consequences: (a) MASTER_TICK still fires per pass through the relocated
   table via `$17D5` — the hook works unchanged in both loops; (b) the
   stall spin inside the dispatch works unchanged (`$0102` freeze covers the
   clone's phase-wait); (c) **the scan runs BEFORE the dispatch** in battle —
   the `$035D` null written at the end of MASTER_TICK covers the *next*
   pass's scan, same invariant, order shifted; (d) the in-game restart is
   `J L_5061` (`$5E2F`), bypassing the header vector → NET_START/lobby runs
   exactly once at cold boot.
3. **[dis] RNG sites: 9 consumers + 1 stir.** `$52DF` is `X_RAND1` with
   R0=1, result discarded, at the bottom of the clone loop = the cart's copy
   of the EXEC loop's per-pass stir → left UNPATCHED (keeps churning volatile
   `$035E`, matching how the EXEC loop's own stir is treated during menus).
   The other nine (incl. `$5193` = random map select ÷ $28, `$5D6C/$5D73` =
   mine placement) are consumers → wrapped. 18 RNG patch words, not 20.
4. **[dis] Polled input**: the game tick (`$554E`) reads `[$011F + player]`
   (`MVII #$011F,R3; ADDR R0,R3; MVI@`), player index 0/1 — ONE operand word
   (`$5569`) covers BOTH seats. No other `$011F/$0120` reads in the cart. No
   `$0121/$0122` keypad-state reads at all (keypad handled purely via
   dispatch, if at all).
5. **[dis] Raw latches**: patch the `MVI` operands `$52C0` (right) and
   `$52C9` (left); the recon's `$52C7/$52D0` MVO hits are the store
   destinations (class-3 false positive, as predicted).
6. **[dis] The lone STIC-write recon hit was the class-1 misaligned decode**:
   `$508E` is `SDBD` prefixing `MVII #$5114,R1` (a print-string pointer).
   **Zero real STIC writes, zero GRAM writes** — display fully static from
   the header; §7.5 reassert applies with nothing to fight.
7. **[dis] Sound-gate audit CLEAN**: zero cart references to `$0149`,
   `$014A/B`, `$0159`, `$0125/6`, `$0143/4`, `$035F`. Sound triggers are
   fire-and-forget through `$1BBE` (play-SFX-from-inline-param, 7 sites) and
   `$1A62` (3 sites); nothing branches on sound state.
8. **[dis] No ISR dance**: the cart never writes `$0100/$0101` (grep for
   ISRVEC and the raw addresses both empty). Simpler than Football and AR:
   no DANCE_SETTLE wait needed before terminal screens (bounded settle kept
   anyway — it's harmless).
9. **[dis] Handler tables**: `$1906` is an ALL-ZERO EXEC-RESIDENT null table
   (the EXEC's own NET_NULL_TBL, also noted in the Football port's equ
   file); `$50DB` = 5 slots all → `$518B`; `$52E4` = slot0 NULL, slot1
   `$5BE3`, slot2 `$5C74`, slot3/4 `$5C2C`. Battle-end/explosion/restart
   logic runs on the **object-walk callback surface** (`$11FA`, mainline,
   per pass, input-independent) — that's why it survives the nulled `$035D`;
   it needs no virtualization, only determinism (which mainline execution
   gives).
10. **[dis] Scratch census**: game state `$015D-$0187` (well inside the
    standard `$015D-$01EF` CRC range), object table `$031D-$035C` standard,
    **plus cart globals `$0315-$031B`** — Armor Battle resets its stack to
    `$02F1` and keeps real state (terrain-map pointer `$0316` etc.) above
    it, inside the range the model previously excluded as "stack". CRC range
    and resync image must carry `$0315-$031B`. `$011A` = collision mask
    (game-written `$0022` at battle setup, EXEC-read) — deterministic
    config, stays excluded. EXEC walk scratch `$011B/$011C/$0319-$031B`
    note: `$0319-$031B` are rewritten by the walk each pass from object
    state → deterministic at tick boundaries; included with the cart
    globals for simplicity.
11. **[dis] `$0187` (battle-over flag)** is set via `MVO R6,$0187` — an
    any-nonzero idiom storing the stack pointer. Across two netplay consoles
    the call depth is identical → CRC-safe. A virt-vs-hook bit-compare
    diverges on this cell once a battle ends → the M3 window must stop
    before battle end (script does).
12. **Quiescent gate decision**: quiescent = `GAME_TBL != AB_HTBL_BATTLE`
    (boot screen, or battle-end/explosion). Mid-battle there is no dead
    moment (continuous real-time, like AR) → cap `RS_PEND_MAX = 40` ticks
    (~2 s) then accept the push with a visible jump, AR-style. The
    double-mismatch rule for the object-table CRC stays.
13. **M8 fault cell**: `$015D` (Blue tank count) — persistent, CRC-covered,
    game-consequential (battle-end decrements + winner check + boot-screen
    display).
14. **Lobby handover marker**: "Blue" at BACKTAB `$0219` (row 1) — printed
    by the boot screen (`X_PRINT_R1` from `$510C` "Blue  :" / `$5114`
    "Black :", counts via `X_PRNUM_RGT`).
15. **Seats**: `player index 0 = left = Blue` (tick processes `[$011F+0]`
    against Blue state at `$016D+0`; winner check: `$015D`==0 → "Black
    wins!"). Host = role 0 = left = **Blue**, guest = right = **Black**.
    Verify on screen at M7.

## M3 findings — hook + virtualized dispatch

1. **verify-patch OK, 33 declared sites, 33 changed** (31 from M2 + the two
   NET_SCAN_WRAP operands added during M3, see finding 5).
2. **Cadence: exactly 3.0 frames/pass** — consecutive `$17D5` stops are
   44,802 cycles apart (÷14,934 cycles/frame = 3.000) → 20.0 Hz wall tick,
   cleaner than Football's ~4-frame dance overhang.  1 tick per pass
   confirmed against the built ROM.
3. **Hook boot verified headless**: "Blue  : 50 / Black : 50" renders,
   `$035D=$50DB`, `AB_TICK_EN=0` on the boot screen (stop shim fired), RNG
   seed untouched until battle start; disc press → `$035D=$52E4`,
   `AB_TICK_EN=1` (start shim), terrain in BACKTAB, cart globals live,
   canonical RNG advanced (consumer wrappers active), SP=$02F1 in the clone
   loop.
4. **Replay order flipped vs Football — events BEFORE the tick.** First
   virt==hook attempt diverged on tank rotation (`$0161/$016D` low nibble,
   object cells): the battle clone runs its scan before the timer dispatch,
   so stock handlers fire before the same pass's game tick; Football's
   replay-after-the-tick order applied every event one tick late.  Replay-
   before-the-tick is timeline-correct for BOTH loops (on the EXEC loop the
   ring value captured at dispatch N is scan N-1's output, whose stock
   events also landed between tick N-1 and tick N).  MASTER_TICK and
   LS_PASS both reordered.
5. **The $518B abandon needs a structural fix (NET_SCAN_WRAP).** The
   battle-start handler resets SP and never returns, so the MASTER_TICK
   that virtually dispatches it dies mid-flight: its `$035D` re-null tail
   never runs and the clone's FIRST scan would see the live battle table
   (one console's real local input could reach game state once at battle
   entry).  Fixed by patching the clone's own `JSR $14F1` at `$52D4` to
   NET_SCAN_WRAP: adopt + null + tail-call the real scan (structural
   nulling; stock-behaving builds compile it to a plain jump; LS_TBL_ADOPT
   already filters the null table so the extra adopt is idempotent).
6. **Documented 1-tick counter skid at battle entry**: the abandoned
   MASTER_TICK also skips its tick++ tail once per battle start, so virt
   trails hook by exactly the number of battle entries.  Symmetric in
   netplay and det (both sides replay the same event at the same tick);
   the virt==hook verdict accepts state-identical + skid.
7. **virt == hook PASS**: with the §7.12 port-read injection (`b 1527`/
   `b 152E`, active-low, forced EVERY pass), all of `$015D-$01EF`, BACKTAB,
   `$0315-$035C`, and AB_TICK_EN are bit-identical at park after a scripted
   battle start + six-pass drive; excluded by design: `$035D` (nulled in
   virt), `$035E/$035F` + PSG + `$0159` (real-frame sound domain).
8. **Injection recipe for THIS cart**: $1532-only forcing (Football's M3
   recipe) is NOT usable here — with the raw store coming from the real
   (idle) port reads, the scan's unchanged-raw path re-marks the stale
   decode as held forever (`$44` stuck 20 passes after release, both
   builds).  Force at the PORT READS per PORTING §7.12: `b 1527` = LEFT,
   `b 152E` = RIGHT, active-low bytes (idle `$FF`, disc N `$FB`, disc W
   `$F7`), every pass unconditionally.  Two stops per pass in both loops;
   pass-aligned settling (`b 17D5` stop counting), never instruction-count
   alignment (builds differ in instruction streams).

## M4 findings — interception proof, objective form

Proof rebuilt around the deterministic demo script instead of live
injection: `main_lag` is now SPIKE_SCRIPT+SPIKE_VIRT+d=20, compared against
`main_det_a` (same script, d=0).  Milestones are state flips located by
pass-counted park-and-dump bisection (`b 17D5` × N, no other breakpoints).

- **Dispatch surface: exactly d.**  Battle start (the script's L-disc-E
  fresh event replayed through the $50DB menu table into $518B) lands at
  tick 30 with d=0 and tick 50 with d=20.
- **Polled surface: exactly d.**  The script's held-E drive value ($44)
  appears in SHADOW_CTRL at tick 90 with d=0 and tick 110 with d=20, while
  the live $011F reads idle $40 in both — SHADOW_FROM_RINGS delivers
  ring[T], proven.
- **No cell changes during the delay window** (parks through the window
  show pre-deploy state, AB_TICK_EN=0): no unpatched immediate path.
- The battle-entry tick skid (M3 finding 6) is visible in the bisections:
  the en-flip pass ends at the same TICK as its predecessor.  Milestones
  compared in tick space are unaffected (both builds skid at the same
  script time).
- **Tank rotation is rate-limited by the game** (bit $20 of a free-running
  per-tank counter gates the fresh-disc rotation step), so rotation-based
  observables quantize ±1-2 ticks — use the shadow-value milestone, not
  rotation, for exactness.

### Harness lesson (expensive): jzIntv breakpoint-force injection is NOT
run-to-run deterministic.  Two byte-identical scripts (settle + per-pass
`g 2` forces at the port-read stops) produced battle-start one pass apart
across runs — forces landing near the ISR boundary can slip a pass.  The
§7.12 recipe remains fine for EXPLORATORY poking, but any gate that needs
exact tick arithmetic must drive inputs IN-ROM (SCRIPT_TBL) and use the
debugger only for park-and-dump.  Also confirmed live here: forcing at the
shared decode entry ($1532) instead of the port reads leaves the raw latch
holding the real (idle) port value, and the scan's unchanged-raw path then
re-marks the stale decode as held forever — the M3-era "$44 stuck" trap.

## M5 findings — determinism

- `make det` **PASS first run**: A (STALL_N 0) and B (STALL_N 9) park at
  tick 1024 with all 256 CRC-ring slots identical and settled object table
  + scratch identical.  The 9-wrapper RNG quarantine (stir left volatile),
  the AB_TICK_EN shims, and the events-before-tick dispatcher all hold
  under stall injection.
- Trace ring + settled-state check extended to the `$0315-$031B` cart
  globals (TRACE_RANGES in debug.asm, crc_trace_diff.py); PASS again with
  full coverage.
- Script: boot → battle start → both tanks pulsed/driven → both fire →
  `$3F`-masked fuzz from tick ~250 to the park at 1024.
- Record-and-replay over live human play stays deferred to the hardware
  pass, as in the three previous ports.

## M6 findings — transport

- `make echo-test` PASS: `E_STAGE = $AA`, 100/100 rounds, avg inter-arrival
  39.4 ms through mailbox → fujinet-pc → TCP loopback (probe on 9105).
  Comparable to Football's measured 36.4 ms 3-transaction round.

## Decisions taken at plan time

- Relay port **9104**, echo probe **9105** (9100/01/02/03 taken by Baseball,
  AR, Football relay + probe on the shared host).
- Wire format unchanged (6-byte INPUT frame; the 5-byte body survived all
  three previous ports unmodified).
- Symbols: game prefix `AB_*`, netcode names unchanged; artifacts
  `build/armor_*`.
- ROM renamed `rom/armor.bin` (make cannot handle spaces in prerequisites).
- Engine copied verbatim from the Football repo (most refined); `ui/text.asm`
  colour-stack variant kept as-is.
- Two inherited errata fixed at copy time: `hud.asm` header re-baselined to
  20 Hz numbers; `run_rig.sh` run budget normalized to instruction units
  (`RUN_SECS * 200000`, §7.11).
- Timer-API sites get Baseball-style shims (virtualized `AB_TICK_EN` flag),
  not table re-pointing — see decode above.
