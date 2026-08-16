# Armor Battle FujiNet netplay

Port of Mattel Intellivision Armor Battle (©1979) to two-player FujiNet
netplay — the fourth port, following Baseball
(`~/Workspace/intv-baseball-experiment`), Auto Racing
(`~/Workspace/fujinet-intv-auto-racing`) and NFL Football
(`~/Workspace/fujinet-intv-football`).

Read these before changing anything:

- **`PORTING.md`** — the porting procedure (the living copy, carried forward
  from the Football repo and updated here with this port's lessons). §8 is
  the gated milestone sequence this repo follows; §9 is the release
  checklist. Every claim in it is measured, not assumed.
- **`spikes/NOTES.md`** — Armor-Battle-specific recon, risks, and decisions.
  EXEC internals live in the baseball repo's `spikes/NOTES.md`; second-port
  deltas (vdispatch, injection recipe, rig hygiene) in the Auto Racing
  repo's; third-port deltas (ISR-dance grep, `r N` instruction units,
  PC-keyed injection) in the Football repo's.

Conventions:

- Netcode symbols keep Baseball's names (LS_/RS_/SES_/NET_/FT_/MB_*);
  game symbols are `AB_*`. Build artifacts are `build/armor_*`.
- Netcode RAM starts at `$8080` — never below (STIC decode alias), and the
  build cfg declares cart RAM only to `$9BFF` (FujiNet mailbox owns `$9C00+`).
- `make rig` / `m4` / `peerleft` / `lobby` force the 127.0.0.1 server; never
  point automated runs at a production endpoint.
- Server: `server/intv_relay_server.py`, default port 9104 (Baseball owns
  9100, Auto Racing 9101, Football 9102 with probe 9103 on a shared host).
  Echo latency probe: 9105.

Toolchain: as1600 / dis1600 / bin2rom; jzIntv at
`~/Workspace/jzintv-20200712-src/bin/jzintv` (headless: SDL dummy drivers);
fujinet-pc-rs232 dist at `~/Workspace/fujinet-pc-rs232/build/dist`.
