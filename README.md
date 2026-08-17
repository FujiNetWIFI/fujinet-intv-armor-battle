# Armor Battle — FujiNet two-player netplay

Mattel Intellivision Armor Battle (©1979), patched for two-console
lockstep netplay over FujiNet. Fourth port of the engine, after Baseball
(`~/Workspace/intv-baseball-experiment`), Auto Racing
(`~/Workspace/fujinet-intv-auto-racing`) and NFL Football
(`~/Workspace/fujinet-intv-football`). Procedure and lessons: `PORTING.md`
(the living copy, updated here); Armor-Battle-specific engineering log:
`spikes/NOTES.md`.

## Architecture

Both consoles run the whole original game, patched at 33 words (header
vectors, 9 consumer RNG call sites, 3 timer-API shims, the polled-input
operand, 2 raw-latch operands, the battle loop's scan call), in delay
lockstep: one 6-byte INPUT frame per player per 50 ms game tick, relayed
by `server/intv_relay_server.py` (port 9104), CRC compared every 64 ticks,
desync repaired by a host state push gated on the non-battle handler
table (mid-battle falls to a 2 s cap, AR-style). Input is the Baseball
hybrid: one polled computed-index read serves BOTH seats (`[$011F +
player]`, shadow pair) plus the `$035D` event dispatch (nulled for the
real scan, replayed in sim space BEFORE the game tick — this cart's
battle loop scans before it dispatches, see PORTING.md §5.7).

The cart is unusual: after the first battle starts it abandons the EXEC
main loop entirely and runs its own clone (SP reset to `$02F1`, scan
before dispatch, cart-side per-pass RNG stir), keeps real game state at
`$0315-$031B` above its stack base, and stops/starts its own 20 Hz tick
through the EXEC timer APIs (virtualized as `AB_TICK_EN`). All covered in
PORTING.md §7.15 and `spikes/NOTES.md` M2/M3.

Seats: host = left seat = **BLUE** tanks, guest = right seat = **BLACK**.
Each player uses their own left controller.

## Status (2026-08-16)

All emulated gates pass:

- `make verify-org` — byte-identical rebuild of the original ROM
- `make verify-patch` — 33/33 declared patch sites, no undeclared diffs
- cadence + `make run-hook` — exact 3.000-frame pass (44,802 cycles), shims
  verified: tick stopped on the boot screen, running in battle
- virt == hook — state bit-identical through a scripted battle (documented
  one-tick counter skid per battle entry, PORTING.md §7.15)
- `make run-lag` — both input surfaces lag exactly d = 20 (in-ROM script:
  battle-start milestone 30→50, shadow drive value 90→110)
- `make det` — A/B determinism with stall injection, 1024 ticks, incl. the
  scripted boot → battle → drive → fire sequence, then masked fuzz
- `make echo-test` — 100/100 transport rounds, 39.4 ms avg
- `make rig` — two consoles auto-matched: 2,248 ticks, 36 CRC pairs, 0
  mismatches, DIAG all zero
- `make lobby` — 12/12 UI checks, both roles (BLUE/BLACK), handover to the
  stock tank-count screen
- `make m4` — injected desync ($015D, the Blue tank count) detected and
  repaired; the full 777-byte image applies chunk-clean (the run also
  caught a hardcoded bounds guard — PORTING.md §7.16)
- `make peerleft` — both branches (OPPONENT LEFT / CONNECTION LOST)

Not yet done: real-hardware validation on two PiRTO IIs
(`build/armor_net.rom` release, `build/armor_nethud.rom` bring-up with the
HUD row; endpoint `fujinet.online:9104` baked in via
`make rom SRV_HOST=... SRV_PORT=...`), and a record-and-replay determinism
pass over live human play (`make run-rec`).

## Build / test

Targets mirror the sibling ports: `verify-org`, `verify-patch`, `hook`,
`virt`, `lag`, `det`, `echo-test`, `rig`, `m4`, `peerleft`, `lobby`,
`rom`, `rom-hud`, `dis`, `recon`. Automated network tests always force the
127.0.0.1 relay on port 9104 (echo probe: 9105). Toolchain: as1600 /
dis1600 / bin2rom, jzIntv at `~/Workspace/jzintv-20200712-src/bin/jzintv`
(headless via SDL dummy drivers), fujinet-pc-rs232 dist at
`~/Workspace/fujinet-pc-rs232/build/dist`.

## FujiNet Lobby registration

Production runs register this server as a room on the FujiNet Lobby
(https://lobby.fujinet.online) so it shows up in the Intellivision Lobby
client (`/view?platform=intv`):

    server/run_production.sh        # relay on :9104, --lobby-enabled

Room name = game name ("Armor Battle"), appkey 13, client ROM
`TNFS://apps.irata.online/Intellivision/Games/Armor_Battle.rom` (upload the built
.rom there when releasing).  The publisher re-POSTs every 5 minutes (the
Lobby drops entries by stale lastping) and POSTs status "offline" on
shutdown.  Local rigs never register: `--lobby-enabled` is opt-in and the
rig targets force 127.0.0.1.  Contract test: `python3 tools/test_lobby_pub.py`.
