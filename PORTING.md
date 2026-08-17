# Porting FujiNet netplay to another EXEC game

Written in the Baseball port repo (a working two-player netplay port of
Mattel Baseball (1978), validated on real PiRTO II hardware); updated by the
Auto Racing and Football ports (§2.1 caveat, §3 false-positive classes, §4
vdispatch/text-variant entries, §5.5 refinements, §5.6, §7.8-§7.13); and
updated again in this repo with the Armor Battle port's lessons (§5.7
replay-order rule, §7.15 cart main-loop clones, §7.16 bounds sweeps,
§7.17 in-ROM scripting for exact gates). Almost none of it is about any one
cart. This document separates the part that transfers — the engine, the
server, the test rig, and the expensive lessons — from the part that has to
be re-derived for each new cart, and gives the procedure for re-deriving it.

Target audience: you, six months from now, starting the fifth port.

Everything here is verified against real ROMs and live runs. Where a number
came from a measurement, the measurement is shown, because two of the worst
detours in the Baseball port came from believing a documented number instead
of measuring it.

---

## 1. The model in one page

Both consoles run the **whole original game**, lightly patched, and stay in
lockstep by exchanging one controller byte per player per sim tick.

- **Sim clock = one EXEC main-loop pass.** The EXEC's loop at `$108F` waits
  for the ISR phase counter `$0102` to go negative, reloads it from `$0103`,
  then does: RNG stir → **timer-table dispatch (all game logic)** → controller
  scan → sound. Everything the game does happens inside that dispatch.
- **The game tick** is whichever timer-table entry holds the game logic,
  divided down by that entry's interval.
- **Input** is captured at tick `T`, sent tagged for tick `T+d`, and applied
  on both consoles at `T+d`. `d` (the delay) is what hides network latency.
- **A stall** — remote input for tick `T` has not arrived — is a busy-spin
  *inside* the dispatch with `$0102` saved, forced to 0, and restored
  (DIS-wrapped). Display and sound keep running off the ISR; object motion,
  game logic, RNG and music all freeze together and coherently.
- **Desync** is detected by exchanging a state CRC every 64 ticks and repaired
  by the host pushing a full state image at a quiescent moment.

The consequence that matters for feel: **the sim advances at the rate of the
slower console, and input lag is `d` ticks**. Both of those are measured in
*ticks*, so the first thing to know about a new game is how long a tick is.

---

## 2. Know your numbers before you write any code

### 2.1 The pass is 3 frames, not 1

The EXEC main loop looks like it runs once per frame. It does not. It runs
once per `$0103` frames, and `$0103` measured **3** on every cart tested:

| cart | `$0103` |
|------|---------|
| Baseball | 3 |
| Auto Racing | 3 |
| Boxing | 3 |
| NFL Football | 3 |
| Armor Battle | 3 |

So a pass is 3 NTSC frames ≈ 50 ms, i.e. **20 passes/second**.

Measure it on your cart before trusting the table above — boot it headless and
dump the cell:

```sh
printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr 4000000\nm 100 8\nq\n' > ph.scr
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  jzintv -d --script=ph.scr -e rom/exec.bin -g rom/grom.bin "YourGame.bin"
# $0100: .... .... [$0102] [$0103] ....
```

(`b 14D5` + `g 7 14D7` is the EXEC title-skip recipe; it is generic.)

Caveat from the Auto Racing port: the pass can be **4 real frames during some
phases** — if the game runs a VBLANK display state machine that replaces the
EXEC ISR for ~1 frame per tick, `$0102` does not count those frames. Wall
tick rate is then phase-dependent; sim semantics (per-pass) are unaffected.

### 2.2 Tick rate = 20 Hz ÷ timer interval

`tools/recon.py` reads this straight out of the cart header. Baseball's game
entry has interval 2 → **10 Hz, a 100 ms tick**. That single number explains
the "quarter second of input lag" reported from live hardware play: the
default delay `d=3` is 3 × 100 ms = **300 ms**, before a single packet moves.

Confirm it against the built ROM rather than the table, by sampling your tick
counter twice — **jzIntv's debugger prints a cycle count at the end of every
register-dump line**, which is the only wall clock you need:

```
 0004 0342 575D 0000 1842 1448 02FD 145C -Z--I-i-  BNC $1468      41535976
                                                                  ^^^^^^^^
```

Baseball, `baseball_hook.bin`, tick counter at three points:

| cycles | tick | Δcycles/Δtick |
|--------|------|----------------|
| 41,535,976 | 458 | — |
| 82,810,621 | 919 | 89,533 |
| 247,904,395 | 2761 | 89,627 |

89.5k cycles = 6 NTSC frames (frame = 14,934 cycles) = **9.97 Hz**, matching
the header-derived 9.99 Hz. The timer-table notes in `spikes/NOTES.md` had
claimed 30 Hz for years; it was wrong, and it made every latency estimate
3× too optimistic.

(For calibration at the other extreme: Armor Battle, with no ISR dance,
measured consecutive `$17D5` stops exactly 44,802 cycles apart = 3.000
frames = 20.0 Hz — the cleanest cadence of the four ports. Football's wall
tick ran ~4 frames because of its dance overhang.)

### 2.3 The delay budget follows from the tick

`d` buys you jitter tolerance of `d × tick` milliseconds and costs you exactly
that much input lag. At Baseball's 10 Hz, `d=3` = 300 ms of both. At a 20 Hz
tick, `d=3` = 150 ms. Pick `d` from the measured round trip, not by habit, and
tune it live against the HUD's `L` figure (§6).

---

## 3. Recon: generate the port map

```sh
make recon ROM="$HOME/Workspace/PiRTO-II-Flash-Backup/MNO/NFL Football.bin"
```

`tools/recon.py` is a linear scan, not a flow-following disassembler, so it
reports *candidates* — confirm each in `make dis` output before patching. It
is calibrated against Baseball, whose entire hand-derived patch map
(`tools/patches.py`) it reproduces: both `$011F` reads, all five RNG call
sites, the timer-arm site, all seven phase-table installs.

It answers, per cart:

| section | what you do with it |
|---------|--------------------|
| cart header | the two hook points: timer-table pointer (relocate it) and start-of-game vector (insert `NET_START`) |
| timer table | which entry is game logic, its interval → tick rate → delay budget |
| RNG call sites | every one needs a canonical-RNG wrapper (§5.2) |
| timer arm/stop calls | `$181E`/`$1831`/`$1838`/`$1844` sites — these break when you relocate the table |
| controller/phase cells | `$011F`/`$0120` reads to redirect at a shadow pair; `$035D` writes = the game's phase machine |
| display writes | STIC/GRAM writes; **zero means display state is static** and can be repaired from the header (§7.5) |

### What recon says about the ported carts (and Boxing, the obvious next)

| | Baseball (done) | NFL Football (done) | Auto Racing (done) | Armor Battle (done) | Boxing |
|---|---|---|---|---|---|
| timer table | `$501C` | `$5026` | `$5029` | `$5050` | `$501C` |
| start-of-game | `$5034` | `$5075` | `$5037` | `$505A` | `$5053` |
| game entries / interval | `$5048` / 2 | `$5034` / 1, `$56EF` / 15 | `$511E` / 1, `$51B7` / 15 | `$554E` / 1 | `$51F0`,`$5A0F`,`$57AB` / 1, `$52F2`,`$5297` / 16 |
| **tick rate** | **10 Hz (100 ms)** | **20 Hz (50 ms)** | **20 Hz (50 ms)** | **20 Hz (50 ms)** | **20 Hz (50 ms)** |
| RNG sites to wrap | 5 | 3 | 4 | **9 (+1 stir left volatile)** | 8 |
| `$035D` phase installs | 7 | 1 | 1 | 4 (3 tables, one EXEC-resident: `$1906`) | 3 |
| `$011F`/`$0120` reads found | 2 | 1 | 0 | 1 (both seats via `[$011F+player]`) | 0 |
| timer arm/stop calls | 1 (`$181E`) | 0 | 0 | **3** (`$1838`/`$1844`, stale absolute entry addr → shims) | 5 (`$1838`/`$1844`) |
| STIC writes | **0** | 3 (incl. `$0030`) | **7** (incl. `$0030`/`$0031`) | **0** (recon's 1 hit = class-1 false positive) | 1 (`$0020`) |
| display mode (`$500E`) | 0 colour stack | 0 colour stack | **1 fg/bg** | 0 colour stack | 0 colour stack |
| main loop | EXEC | EXEC | EXEC | **cart clone during battle (§7.15)** | EXEC (verify!) |

Reading that table, before writing a line of code:

- **All three tick at 20 Hz**, twice Baseball's rate — `d=3` costs 150 ms
  instead of 300 ms, so these should *feel better* than Baseball does.
- **Football is the easiest**: fewest moving parts (three RNG sites, one phase
  install, no timer arm/stop calls), and it has genuine dead-ball moments to
  gate a resync on.
- **Every one of them runs more than one game timer entry** (Baseball ran
  exactly one, which flattered the design): each entry is game logic on its
  own cadence and the master dispatcher must reproduce all of them, in table
  order, at their own intervals — including the slow ones, which are sim state
  too (their countdowns must freeze with everything else during a stall).
- **Boxing needs the most care**: *three* entries at tick rate plus two slow
  ones, five entries in total and no music timer in the table at all. It
  also uses `X_TIMER_START`/`STOP`, which Baseball never did, at five sites —
  all of them relocation-sensitive.
- **Auto Racing breaks the static-display assumption**: seven STIC writes,
  including `$0030`/`$0031` (the scroll delays — it scrolls the track) and it
  runs in foreground/background mode, not colour stack. Do **not** copy
  Baseball's "reassert display state from the header" repair into it; the
  scroll registers are live game state and belong in the resync image instead.
- **Boxing and Auto Racing show no `$011F`/`$0120` reads.** That means they
  read input through a computed pointer the linear scan cannot see (or only
  through the `$035D` dispatch). Chase this in `dis1600` before assuming
  there is nothing to patch — the shadow-input patch is load-bearing.
  (Auto Racing's answer, found at its M2: **dispatch-only** — the port reads
  feed only the EXEC scan's edge cells, and input enters game state
  exclusively through the `$035D` handlers. That finding changed the spike
  design, not the wire format. Run the dis1600 confirmation pass *before*
  committing to a wire format or a spike design.)
- **Armor Battle's answers, for calibration**: the single `$011F` reference
  (`MVII #$011F,R3` + `ADDR player`) serves BOTH seats — one operand patch,
  shadow pair consecutive; the three timer-API calls all pass the ABSOLUTE
  address of the original table's game entry (`$5054`), stale after
  relocation → each `JSR` retargeted to a shim that flips a virtualized
  armed flag (`AB_TICK_EN`, sim state in the CRC and image tails). Decode
  WHICH entry each timer-API site targets before deciding: a music-entry
  (slot 0) call survives relocation untouched; a game-entry call must be
  shimmed, because pointing it at the new table would let the game stop
  MASTER_TICK itself. Its per-battle dead moments (boot screen, battle-end
  explosion) gate the resync; mid-battle falls to the cap, AR-style.

### Known recon false-positive classes (seen across three carts)

Recon is a linear word scan; these three patterns have each produced a bogus
candidate that hand-decoding the raw words exposed:

1. **Misaligned instruction decode** — a "STIC write" that is really the
   middle of two consecutive 3-word `JSR R5` instructions (Football `$5041`),
   or an `SDBD`-prefixed `MVII` pair (Armor Battle `$508E`: "MVO R1,$0001"
   was `SDBD / MVII #$5114,R1`). Decode the surrounding words as
   instructions from a known-good boundary.
2. **`CMPI` against a constant that happens to be a hot cell address** — a
   loop-bound compare of a pointer against `#$035D`/`#$035F`, not a read of
   the cell (Auto Racing `$520F`, Football `$5A12`).
3. **The operand you patch is the `MVI`, not the `MVO`** — at a raw-port
   latch site the *read* operand (`$01FE`/`$01FF`) is the patch target; the
   `MVO` destinations (`$0123`/`$0124`) stay (AR, Football, and Armor
   Battle — three carts in a row).

---

## 4. What you copy, and what you re-derive

**Copy unchanged** (nothing in these is Baseball-specific):

- `src/netcode/mailbox.asm` — FujiNet mailbox driver (`N:TCP://`)
- `src/netcode/session.asm` — login, lobby, matchmaking, framing + the
  per-type length table that keeps a lost byte from misframing the stream
- `src/netcode/lockstep.asm` — delay lockstep, gate, stall, virtual dispatch
- `src/netcode/resync.asm` — CRC exchange, state image, recovery
- `src/netcode/hud.asm` — the live diagnostic row (§6)
- `src/vdispatch.asm` — the shared virtual-dispatch engine (factored out of
  lockstep.asm by the Auto Racing port so the local lag/det/replay spikes and
  the netcode replay events through one code path; includes the disc-settle
  `R0 = -1` event the scan's held path emits)
- `src/ui/text.asm` — BACKTAB text. **Two variants exist**, keyed to header
  `$500E`: the Baseball original for colour-stack carts, the Auto Racing
  rewrite for foreground/background carts. Copy the one matching your cart.
- `server/bbnet_server.py` — relay + matchmaking; game-agnostic
- `tools/dump_rom.py`, `tools/check_patch.py`, `tools/recon.py`
- `test/` — the whole rig (two fujinet-pc instances + server + two jzIntv)

**Re-derive per game:**

| thing | where it lives for Baseball | how to get it |
|-------|------------------------------|----------------|
| patch map | `tools/patches.py` | `recon.py`, confirmed in `dis1600` |
| game symbols (`BB_*`) | `src/exec_equ.asm` | disassembly |
| master dispatcher body | `src/hook.asm` `MASTER_TICK` | one call per game timer entry, at its interval, **in the original table's order** (the EXEC walks entries in order; a slow entry listed before the fast one must fire first on the passes where both fire) |
| CRC range (non-volatile game scratch) | `LS_CKSUM`, `$015D-$01EF` | §5.4 |
| resync image layout | `resync.asm` `IMG_*` | §5.4 |
| quiescent point for resync | `BB_TBL_PREPITCH` (`$5335`) | §7.6 |
| controller→role mapping | `NET_ROLE` handling | the game's manual, then verify on screen |
| timer arm/stop shims | Armor Battle's `AB_STOP/START_SHIM` | decode each site's target entry first (§3); music-entry calls need nothing |
| replay order (events vs tick) | `MASTER_TICK`/`LS_PASS` call order | the cart's own scan-vs-dispatch order (§5.7) |
| scan-call wrapper | Armor Battle's `NET_SCAN_WRAP` | only if the cart runs its own main loop (§7.15) |

---

## 5. The seven things that make it deterministic

Get these wrong and the two consoles drift; everything else is plumbing.

### 5.1 Stall by spinning, never by skipping

Freeze `$0102` (save, force 0, restore, interrupts disabled around the
save/restore) and busy-spin inside the dispatch. Skipping the dispatch lets
the ISR's object motion run on while game logic is paused — instant desync.

### 5.2 Quarantine the RNG per call site

The EXEC's LFSR at `$035E` is stirred by the main loop every pass, by the
title-wait loop, and by the **sound engine from `$1CCE` whenever noise SFX
play — including mid-tick, from the ISR**. It can therefore never be sim
state. Patch each game RAND call site to a wrapper that swaps a canonical
sim-space RNG in and out of `$035E` with interrupts off. Wrapping the whole
tick is not airtight; the sound engine churns inside it.

### 5.3 Handle all three input surfaces

1. **Polled cells** `$011F`/`$0120` — repoint the game's reads at a shadow
   pair you control.
2. **Event dispatch** — the EXEC scan *jumps into game code* through the
   handler table pointed to by `$035D`. Point `$035D` at a table of zeros
   during the real scan so real local input can never reach game code, then
   replay both players' events in sim space through the game's live handlers.
   Adopt-don't-restore: handlers install new tables *from inside a dispatch*,
   so re-read `$035D` before the tick and again after the virtual dispatch.
3. **Action/keypad state cells** `$0121`/`$0122` — carry them on the wire too.

### 5.4 Checksum only what is really sim state

Excluded as volatile: `$0100-$015C` (EXEC scratch, music, ISR masks, timer
countdowns), `$01F0-$01FF` (PSG), `$0200-$02EF` (BACKTAB), `$02F0-$031C`
(stack — dead-slot noise varies with interrupt timing), `$035E`, `$035F`.
The object table `$031D-$035C` is deterministic per tick but **ISR-written**,
so a mainline capture races it: checksum it only at quiescent points, or
require two consecutive mismatches. The resync image must include the live
handler-table pointer.

### 5.5 Prove it before networking

`make det` is the gate: two builds, identical scripted inputs, one of them
stall-injected, per-tick state checksums must match exactly. Do this before
any transport work. Note the coverage hole this leaves — scripted fuzz never
reaches deep game states (in Baseball it never triggers a pitch), so a
record-and-replay pass over real gameplay is what actually exercises the
game's phase machine.

Two refinements from the Auto Racing port:

- **Write a deterministic demo script** (`SCRIPT_TBL` in `vdispatch.asm`)
  that drives the game from boot into real play — menus, confirms, the first
  seconds of the game proper — and run it before handing over to fuzz. It
  closes most of the coverage hole cheaply, and both rig consoles can share
  it (host plays the left columns, guest the right).
- **Mask automated fuzz to `$3F`** (disc space only). Unmasked keypad fuzz
  can trigger game-restart/menu paths whose determinism you have not proven
  yet (that is how AR found its sound-state leak); keypad coverage belongs to
  the script, where it is reproducible.

### 5.6 Audit helper registers against everything live in the caller

A helper that clobbers a register the caller still needs can corrupt state
**symmetrically on both consoles**, so CRCs agree and nothing looks wrong for
hundreds of ticks (AR: `SCR_STEP` clobbered R2 = the tick tag inside
`LS_PASS`; every post-script input went out tagged "tick 0" and was silently
dropped as stale). When inserting any call into `LS_PASS`/`MASTER_TICK`,
enumerate what is live in R0-R5 at that point and check the callee against
the list.

### 5.7 Replay events in the cart's own scan-vs-dispatch order

The virtual dispatch must land events on the same side of the game tick as
the real scan does. In the EXEC main loop the scan runs AFTER the timer
dispatch, so replay-after-the-tick (Baseball/AR/Football's order) is
correct there. Armor Battle's battle loop runs its scan BEFORE the
dispatch, so stock handlers fire before the same pass's game tick —
replay-after applied every event one tick late and broke virt==hook on
tank rotation. Replay-BEFORE-the-tick is timeline-correct for both loop
shapes given capture-at-dispatch ring indexing (on the EXEC loop, the
value captured at dispatch N is scan N-1's output, whose stock events also
landed in the no-mutator window between tick N-1 and tick N) — but derive
this from YOUR cart's loop, don't assume. The check is the virt==hook
bit-compare with a script that drives real play.

---

## 6. Instrument it, or you will be guessing

Netplay on real hardware leaves no log, and every failure looks identical from
the couch: "players stopped moving, sound kept playing." Two facilities exist
for this and both transfer as-is.

**Field counters** at `$8180-$8183` — `DIAG_SLIP` (stream re-framings),
`DIAG_REJ` (refused state chunks), `DIAG_TMO` (mailbox timeouts), `DIAG_ERR`
(error replies). They are printed on the peer-left screen, which is the only
way to read them on hardware without a debugger. The rig asserts all four are
zero.

**The live HUD** (`NET_HUD`, `src/netcode/hud.asm`) paints one BACKTAB row
every 16 ticks, all hex:

```
L 02   S 00   T 21   R 00   H 00
```

- `L` slack = min(remote watermark − tick). Healthy is `d-1`. `00` = the sim
  is running at the network's pace and any jitter becomes a visible stall.
- `S` gate stall rounds, `T` mailbox poll iterations ÷ 256 (transport cost),
  `R` resyncs completed, `H` resync-hold rounds.

Diagnosis: `S` high with `L 00` → network-bound, raise `d` or shorten the
round trip. `S 00` with `T` high → transport-bound, cut transactions per tick;
a bigger `d` would only add lag. `R` climbing → it is a desync, not pacing,
and no amount of tuning will fix it.

This row is what turned "pauses of a second at definite spots" from a guess
into two measured causes in one session.

---

## 7. The expensive lessons

Each of these cost real debugging time on Baseball. They are all generic.

### 7.1 Never put cart RAM in `$8000-$807F`

The STIC only partially decodes its address, so its control registers also
respond at `$4000`, `$8000` and `$C000`. A netcode variable at `$8032` is a
write to the **top-border-extension register**: it painted border over BACKTAB
row 0 and hid the scoreboard whenever network traffic flowed. Reads mostly
"work" (AND-ed bus), so sync and logic look fine and only the display betrays
it. Start netcode RAM at `$8080`.

### 7.2 A wire value must never index a memory writer

The resync applier took its image position straight off the packet. Past the
end of the position→address table it reads **ROM code words as destination
pointers**, and CP-1610 `CMPI`/`BGE` range tests are **signed**, so any
position ≥ `$8000` sails through them and splatters a contiguous run over
`$0000+` — the STIC register file. Validate a minimum length per frame type,
gate data chunks on an actually-open hold, and bounds-check both `pos` and
`pos+count`. Do this on the console even though the relay validates framing:
one lost byte on the read path misframes the stream, and the wire is full of
bytes that read as a valid frame type.

### 7.3 A length-prefixed stream needs a re-sync path

Same root cause, other half: the reassembler had no sync marker, so a single
dropped byte (a `NET_READ` the peripheral completes *after* the transaction
times out) misframed everything after it, forever. Validate `(type, len)` at
peek time against a per-type length table mirroring the server's, and on a
mismatch discard one byte and rescan.

### 7.4 An "empty" record is a valid record

`RS_ON_CRC` matched the peer's CRC against a ring slot by comparing the stored
tick — and a **zeroed** ring reads as a perfectly good record for tick 0 with
a checksum of 0. The peer's tick-0 CRC routinely arrives before this console
has ticked 0 at all, so it compared against nothing, declared a desync, and
every single match paid for a full state resync (a ~1 s freeze) while the
server's CRC log said the two consoles had agreed the whole time. Fill
invalidated records with an impossible value (`$FF`), and clear the ring at
session start — it lives outside the block `NET_START` zeroes, so on hardware
it otherwise carries the *previous* match's records across a reset.

Generalise: any cache keyed by a value whose zero is legal needs an explicit
validity marker.

### 7.5 Display state comes from the header — unless the game scrolls

1978-era carts often never write the STIC or GRAM at all (Baseball: zero
sites). The EXEC programs border extension, mode, colour stack and border
once from header words `$500D-$5013`, and GRAM from the `$5008` init sequence.
Two consequences: there is nothing to transport (both consoles are identical
by construction), and nothing refreshes it, so one stray write stays on screen
for the rest of the game. The repair is to reassert those header words
periodically — a no-op when healthy.

**Check `recon.py`'s STIC-write count first.** Auto Racing writes `$0030`/
`$0031` (scroll) and Football writes `$0030`: for those games the reassert
would fight the game every frame, and the scroll registers are sim state that
belongs in the resync image.

### 7.6 Gate the resync on a quiescent point

Pushing a state image the instant a CRC disagrees teleports everything
mid-play. Baseball's phase is readable off the handler table it installs in
`$035D` (`$5335` = pre-pitch = ball dead), so the host defers the push until
then, with a cap (120 ticks) after which a visible jump beats staying
desynced. Crucially the *guest* must keep playing while it waits — freezing it
starves the host of the inputs it needs to reach ball-dead, and the whole
thing deadlocks.

Per game, the quiescent point differs and the `$035D` installs are where to
look: Football has between-plays, Boxing has between-rounds, **Auto Racing has
none** — a continuous race, where the honest options are to push at a
lap/crash boundary or accept the jump.

### 7.7 Transport cost is per transaction, so count them

Every pump is a mailbox `STATUS` (plus a `READ` when bytes are waiting) and
every transaction is a bus round trip the console spins through. Pumping once
per *pass* rather than once per *tick* doubled that cost for nothing: the pump
on the odd pass only ever mattered when the console had slack in hand, which
is exactly when nothing is waiting. Moving it cut measured transport cost 33%
(HUD `T` 0x32 → 0x21). The gate loop and the resync hold still pump every
round, which is when it genuinely matters.

`STATUS` before `READ` is not optional: FujiNet's TCP read returns
`SOCKET_TIMEOUT` and an error if you ask for more bytes than are available.

### 7.8 The EXEC sound gate can leak real-frame state into the sim

The one determinism leak Auto Racing shipped with: game phase transitions
that call EXEC sound entries behind the SFX-busy gate (`$0149`, checked by
the X_SFX_OK idiom — return via R4 = skip vs R5 = play) can consume
**real-frame-timed** sound state at a decision point. Stall-shift the sound
state and the two consoles take different branches with identical sim state
and inputs. Audit every game call into `$1A61`-class sound entries at recon
time: if any *logic* depends on the outcome, wrap the site so the gate is
deterministic. The CRC + resync net catches what slips through, at the cost
of a sub-second freeze.

### 7.9 Terminal screens must park forever

Baseball's peer-left path returned to the EXEC pass; on Auto Racing the scan
rewrote `$0102` and the pass machinery repainted status rows over the
peer-left screen every frame. Park the mainline in a tight loop
(`B @@self`) once a terminal screen is up — nothing after it needs the pass.

### 7.10 A game ISR dance can outlive your moment

Games that install their own ISR bodies (`$0100/$0101`) for multi-frame STIC
updates can be mid-dance when you take over the display (peer-left, session
screens). Wait out the dance bounded, then force-restore the EXEC default
ISR (`$1126`) — otherwise a stranded game ISR repaints over your screen
forever (AR's `DANCE_SETTLE`). Check at recon whether the cart writes
`$0100/$0101` at all; if it never does, none of this applies.

### 7.11 The debugger's `r N` counts instructions, not cycles

jzIntv's scripted `r N` runs N *instructions* (~4.6 cycles each on
average). Every cycles-derived count in a test script is therefore ~4.6×
too long: harmless where the verdict reads whatever state the run reached,
fatal where a poke must land at a specific moment or dumps must run before
a `timeout` kill (this is how Football's m4 console 2 died and its fault
poke landed pre-session). Budget ~200,000 instructions per emulated
second, and verify any timing-sensitive constant against the cycle counter
the debugger prints on every register line.

### 7.12 Inject input at the scan's port reads, keyed by PC

Forcing values at a shared decode address and counting on stop *order* is
fragile (the order proved phase-dependent on Football and burned hours).
The EXEC scan reads the left port at `$1525` and the right port at `$152C`
— break after each `MVI` (`b 1527` / `b 152E`) and force R2 with the raw
**active-low** byte. Distinct PCs per side, unconditional every pass. Keep
the game's own latch cells consistent by poking the shadow cells at the
tick stop, and align the script to the actual stop cycle first (the first
stop after arming the breakpoints is the scan's, not the tick's).

Armor Battle added two hard caveats. First, forcing at the shared decode
entry (`$1532`) instead of the port reads leaves the raw latch holding the
real (idle) port value; the scan's unchanged-raw path then re-marks the
stale decode as held **forever** ("$44 stuck" — the decoded cells are
sticky latches by design, §15AC re-marks the old value as held on every
no-event pass). Second — see §7.17 — even the correct port-read recipe is
not run-to-run deterministic, so use it for exploration only, never for a
gate that does exact tick arithmetic.

### 7.13 Kill stale rig processes first

A stale fujinet-pc instance silently holds its BOIP port and every later
emulator launch against it becomes a no-op that *looks* like a netcode hang.
Every rig script `pkill`s its own instances before starting. Keep it that
way in new test scripts.

### 7.15 A cart may abandon the EXEC main loop entirely

Armor Battle's battle-start handler generates the map, **resets SP to
`$02F1`, and enters a cart-resident clone of the EXEC main loop**
(`L_52B5`): phase-wait on `$0102`/`$0103` → raw-port latch → `$11FA`
object/collision walk → `$14F1` scan → `$17D5` timer dispatch → `$1AAD`
sound → `X_RAND1` stir → loop. The EXEC loop at `$108F` never runs again
after the first battle. Consequences, all of which generalize:

- The hook survives **because it lives in the timer table**: any loop that
  dispatches `$17D5` with the standard `$0102` pacing runs MASTER_TICK.
  Hooking anything loop-specific would not have survived.
- **The clone's pass order can differ** (scan before dispatch here) —
  that is what forces the §5.7 replay-order derivation.
- **A cart-side per-pass RNG stir** appears as a patchable "RNG site" but
  is the clone's copy of the EXEC loop's stir: leave it on the volatile
  LFSR, wrap only consumers (recon found 10 "sites"; 9 were consumers).
- **An abandoning handler kills the netcode pass that dispatched it**: the
  vdispatch-called handler never returns, so that MASTER_TICK's tail (the
  `$035D` re-null, the tick++) is skipped once. The re-null hole is closed
  structurally by patching the clone's own scan `JSR` to a wrapper
  (`NET_SCAN_WRAP`: adopt + null + tail-call the scan; stock-behaving
  builds compile it to a plain jump). The skipped tick++ is a benign,
  symmetric one-tick counter skid per battle entry — document it and make
  the virt==hook verdict accept state-identical + skid.
- **A cart that resets its own SP may keep globals above the stack base**:
  Armor Battle stores real state at `$0315-$031B`, inside the range the
  model previously excluded as "stack". Census the `$02F0-$031C` range per
  cart; anything game-written belongs in the CRC and the image (and mind
  the shrunken stack headroom under the netcode + ISR frames — the CRC
  coverage is what catches an overflow).

### 7.16 An image layout change must sweep every bounds constant

Growing the resync image from 761 to 777 bytes tripped a quick-guard that
hardcoded `pos_hi < 3` ("nothing valid at `$300+`") in the STATE-chunk
applier: the image's final chunk — the tail with the RNG, the virtualized
timer flag and GAME_TBL — was silently refused, and recovery still LOOKED
successful because those cells happened to match. Only the m4 verdict's
`DIAG == 0` requirement exposed it. When any `IMG_*` constant changes,
grep the applier and the pusher for every numeric comparison in the same
units, and keep only symbolic bounds tight; hardcoded quick-guards get the
loosest correct value (wrap prevention), with the exact bound in one place.

### 7.17 Breakpoint-force injection is not run-to-run deterministic

Two byte-identical jzIntv scripts (title-skip + pass-counted settle +
per-pass `g 2` forces at the port-read stops) produced a battle start one
pass apart on different runs — a forced stop near the ISR boundary can
slip a pass, and the drift compounds. The emulated machine itself is
deterministic; the debugger's stop/resume interleaving is not. Any gate
that needs exact tick arithmetic (the interception proof, determinism,
anything CRC-compared) must generate its inputs **in-ROM** (`SCRIPT_TBL` +
the masked fuzz) and use the debugger only to park (`b 17D5` × N stops)
and dump. Alignment is by stop count, never by instruction count —
different builds execute different instruction streams.

### 7.18 Known, not yet acted on

- **Nagle is on for `N:TCP` sockets.** `NetworkProtocolTCP::open_client_connection`
  never calls `setNoDelay(true)` (only the modem devices do), so a
  6-byte-per-tick lockstep stream can eat tens of ms of jitter. One-line
  firmware change, but it means reflashing both consoles.
- **PAL.** Frames are 20 ms, so a PAL console's tick is 20% slower than an
  NTSC one's. The sim stays in sync (it is tick-based, not time-based) but the
  pair runs at the slower console's rate. Detect and either refuse the match
  or say so on screen.

---

## 8. Procedure

Each step has a gate that must pass before the next one is worth starting.

1. **Byte-identical rebuild.** `tools/dump_rom.py` with no patch file, then
   `make verify-org` — the source must reassemble to the original ROM exactly.
   This guards every later step against dump/toolchain drift.
2. **Recon.** `make recon ROM=…`, confirm every candidate in `make dis`
   output, write `tools/patches.py`. Gate: `make verify-patch` reports exactly
   the sites you declared.
3. **Hook.** Relocate the timer table, insert `NET_START`, reproduce every
   game timer entry in the master dispatcher. Gate: `make run-hook` must feel
   identical to stock.
4. **Interception proof.** Route input through the shadow pair with a delay
   ring. Gate: `make run-lag` — a 1-second input delay is unmistakable.
5. **Determinism.** RNG wrappers, volatile-cell map, stall injection. Gate:
   `make det` PASS. Then extend with recorded real gameplay (`make run-rec`).
6. **Transport.** Gate: `make echo-test` — 100 clean echo rounds through
   `jzintv --fujinet` → fujinet-pc.
7. **Lockstep + matchmaking.** Gate: `make rig` — two consoles, auto-matched,
   CRC pairs compared, `DIAG` counters all zero.
8. **Desync recovery.** Gate: `make m4` — fault injected, detected, repaired,
   and the report says the push fired at the quiescent point rather than the
   cap.
9. **Drop handling.** Gate: `make peerleft`, both branches.
10. **Hardware.** `make rom SRV_HOST=…`, two PiRTO IIs, HUD on. Read `L`, `S`,
    `T`, `R` during real play and tune `d` from what they say.

## 9. Checklist

```
[ ] $0103 measured (pass length in frames)
[ ] tick rate measured in the built ROM, two-point cycle sample
[ ] delay d chosen from measured RTT, not habit
[ ] every timer entry the game uses reproduced in the dispatcher
[ ] every RNG call site wrapped
[ ] every $011F/$0120 read repointed (chase indexed reads in dis1600)
[ ] $035D nulled during the real scan; virtual dispatch replays both sides
[ ] $0121/$0122 carried on the wire
[ ] volatile-cell map built; CRC covers only real sim state
[ ] resync image includes the live handler-table pointer
[ ] quiescent point identified (or its absence accepted deliberately)
[ ] display: STIC-write count checked; header reassert only if it is zero
[ ] netcode RAM starts at $8080
[ ] all wire-driven writes bounds-checked, signed compares audited
[ ] CRC ring invalidated with a non-zero marker and cleared at session start
[ ] DIAG counters wired to the peer-left screen
[ ] HUD enabled for bring-up, disabled for release
[ ] timer arm/stop sites decoded: which entry does each target? shims where needed
[ ] cart-side main loop? scan-vs-dispatch order derived; replay order matches (5.7)
[ ] $02F0-$031C censused for cart globals above the stack base (7.15)
[ ] image bounds constants swept after any IMG_* change (7.16)
[ ] exact-tick gates driven by in-ROM script, parked by stop count (7.17)
```

## 10. Where the detail lives

- `spikes/NOTES.md` (this repo) — Armor-Battle-specific recon, decodes,
  risks, and the full milestone log (the battle main-loop clone, the timer
  shims, the replay-order fix, the injection-nondeterminism forensics).
- `~/Workspace/intv-baseball-experiment/spikes/NOTES.md` — the EXEC
  reverse-engineering notes: main loop, timer table internals, controller
  decode, raw port encoding, decoded input byte format, jzIntv debugger
  facts. Read this before touching timing or input code.
- `~/Workspace/fujinet-intv-auto-racing/spikes/NOTES.md` — second-port
  deltas: the headless input-injection recipe (force all four read sites per
  pass in stop order; never add extra breakpoints to an injection run),
  event-semantics corrections (keypad digits 1-based into handlers, ENTER =
  raw `$28` → event `$B`), the VBLANK-dance analysis, the leak forensics.
- `~/Workspace/fujinet-intv-football/spikes/NOTES.md` — third-port deltas:
  the ISRVEC-labelled dance discovery, `r N` instruction units, PC-keyed
  injection, the play-system map.
- `src/netcode/hud.asm` — how to read the HUD.
- `README.md` — build targets, interactive runs, current status.
