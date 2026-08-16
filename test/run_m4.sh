#!/bin/sh
# M4 recovery test: the 2-console rig with a fault injection -- console 2's
# game scratch cell $017C (the Visitor score) is corrupted mid-run via the debugger.  Expected:
# CRC mismatch detected, host pushes state, both re-baseline, CRC pairs go
# back to matching, nobody drops.
set -e
BUILD=build
RIG="$BUILD/rig"
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
RUN_SECS="${RUN_SECS:-100}"

[ -d "$RIG/fn1" ] || { echo "run 'make rig' once first (creates fn1/fn2)"; exit 1; }

# Same guard as run_rig.sh: never point fuzz clients at production.
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_m4.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild with"
    echo "  make SRV_HOST=127.0.0.1 build/football_net1.bin build/football_net2.bin"
    exit 1
fi

# Stale rig fujinet instances hold the BOIP ports and make every later
# launch a silent no-op (the fresh copy fails to bind and dies).
pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
( cd "$RIG/fn1" && exec ./fujinet -u 127.0.0.1:18081 ) > "$RIG/fn1.log" 2>&1 &
FN1=$!
( cd "$RIG/fn2" && exec ./fujinet -u 127.0.0.1:18082 ) > "$RIG/fn2.log" 2>&1 &
FN2=$!
python3 server/intv_relay_server.py --port 9102 > "$RIG/m4_server.log" 2>&1 &
SRV=$!
trap 'kill $FN1 $FN2 $SRV 2>/dev/null || true' EXIT
sleep 1.5

# The debugger's `r N` counts INSTRUCTIONS (~4.6 cycles each on average,
# measured), so ~200000 instructions per emulated second.  Overshooting by
# the old cycles-based factor made console 2 blow past its dumps and die on
# `timeout` (spikes/NOTES.md, M8).
printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr %d\nm 8100 20\nm 8160 10\nm 80C0 2\nm 8180 10\nm 8090 10\nq\n' \
    $((RUN_SECS * 200000)) > "$RIG/m4c1.scr"
# console 2: extra RNG stir for a distinct name/seed, then the fault poke
# at ~35s (7M instructions), then the remainder of the run.
printf 'b 14D5\nr 10000000\nn 14D5\nr 49BF0\nb 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr 7000000\ne 17C 5\nr %d\nm 8100 20\nm 8160 10\nm 80C0 2\nm 8180 10\nm 8090 10\nq\n' \
    $(( (RUN_SECS - 35) * 200000 )) > "$RIG/m4c2.scr"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/m4c1.scr" \
    --fujinet=localhost:19851 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/football_net1.bin" > "$RIG/m4c1.out" 2>&1 &
C1=$!
sleep 2
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/m4c2.scr" \
    --fujinet=localhost:19852 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/football_net2.bin" > "$RIG/m4c2.out" 2>&1 &
C2=$!
wait $C1 $C2 || true

python3 - "$RIG" <<'EOF'
import re, sys
rig = sys.argv[1]

def cells(path):
    mem = {}
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[a + i] = int(w.rstrip("*"), 16)
    return mem

ok = True
ticks = []
for n in (1, 2):
    m = cells(f"{rig}/m4c{n}.out")
    tick = m.get(0x8108, 0) | (m.get(0x8109, 0) << 8)
    ticks.append(tick)
    active, dropped, hold = m.get(0x8162, 0), m.get(0x8163, 0), m.get(0x8090, 9)
    # A legitimate resync must not trip any of the framing/bounds guards.
    diag = [m.get(0x8180 + i, 0) for i in range(4)]
    # RS_WAITED: game ticks the host deferred its push waiting for a
    # quiescent phase (AR_PHASE bit 0 set: menus / race-screen hold).
    # RS_PEND_MAX(40) = gave up and pushed mid-race.
    pend, waited = m.get(0x8187, 0), m.get(0x8189, 0)
    role = m.get(0x8160, 0)
    why = m.get(0x818A, 0)
    gtbl = m.get(0x80C0, 0) | (m.get(0x80C1, 0) << 8)
    gate = "n/a (guest)" if role else {
        0: "never pushed", 1: f"QUIESCENT PHASE after {waited} ticks",
        2: f"cap expired at {waited} ticks (pushed mid-race)"}.get(why, "?")
    print(f"console {n}: role={'host' if role == 0 else 'guest'} "
          f"active={active} dropped={dropped} hold={hold} "
          f"tick={tick} diag(slip,rej,tmo,err)={diag}")
    print(f"           resync gate: pending={pend} GAME_TBL=${gtbl:04X} -> {gate}")
    ok &= (active == 1 and dropped == 0 and hold == 0 and tick > 400
           and diag == [0, 0, 0, 0])

lines = open(f"{rig}/m4_server.log").read().splitlines()
mm = [i for i, l in enumerate(lines) if "CRC MISMATCH" in l]
oks = [i for i, l in enumerate(lines) if "crc ok" in l]
recovered = bool(mm) and bool(oks) and max(oks) > max(mm)
print(f"server: mismatches={len(mm)} crc-ok-lines={len(oks)} "
      f"recovered-after-fault={recovered}")
ok &= recovered
print("M4 PASS" if ok else "M4 FAIL")
sys.exit(0 if ok else 1)
EOF
