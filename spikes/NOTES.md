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
