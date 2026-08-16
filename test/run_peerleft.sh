#!/bin/sh
# Peer-left test: the 2-console rig, but console 2 quits mid-game.  Expected:
# console 1 notices (either the server's PEER_LEFT frame or its own gate
# timeout), freezes the sim and paints the terminal peer-left screen.
# Verdict decodes console 1's BACKTAB back into text and requires the notice
# to be on screen with PEER_SCR set.
set -e
BUILD=build
RIG="$BUILD/rig"
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
RUN_SECS="${RUN_SECS:-90}"
LEAVE_SECS="${LEAVE_SECS:-45}"
# clean   = kill console 2 and its FujiNet -> the relay socket closes and the
#           server sends PEER_LEFT       (expect "OPPONENT LEFT")
# timeout = kill only the emulator; fujinet-pc keeps the TCP session open, so
#           console 1 has to notice by itself ("CONNECTION LOST")
LEAVE_MODE="${LEAVE_MODE:-clean}"

[ -d "$RIG/fn1" ] || { echo "run 'make rig' once first (creates fn1/fn2)"; exit 1; }

# Same guard as run_rig.sh: never point fuzz clients at production.
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_peerleft.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild with"
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
python3 server/intv_relay_server.py --port 9102 > "$RIG/pl_server.log" 2>&1 &
SRV=$!
trap 'kill $FN1 $FN2 $SRV 2>/dev/null || true' EXIT
sleep 1.5

# Console 1 plays through and dumps BACKTAB + the netplay/peer-left/diag cells.
printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr %d\nm 200 F0\nm 8160 8\nm 8185 2\nm 8180 4\nm 100 4\nq\n' \
    $((RUN_SECS * 200000)) > "$RIG/plc1.scr"
# Console 2 gets the usual extra RNG stir for a distinct name and otherwise
# plays normally -- it is killed from the shell below, so the walk-out happens
# at a known WALL-CLOCK moment instead of an emulated-cycle count.
printf 'b 14D5\nr 10000000\nn 14D5\nr 49BF0\nb 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr %d\nq\n' \
    $((RUN_SECS * 200000)) > "$RIG/plc2.scr"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/plc1.scr" \
    --fujinet=localhost:19851 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/football_net1.bin" > "$RIG/plc1.out" 2>&1 &
C1=$!
sleep 2
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/plc2.scr" \
    --fujinet=localhost:19852 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/football_net2.bin" > "$RIG/plc2.out" 2>&1 &
C2=$!

# The walk-out: kill console 2 AND its FujiNet, so the relay's socket really
# closes and the server hands console 1 a PEER_LEFT.  Killing only the
# emulator would leave fujinet-pc holding the TCP session open and we would be
# testing the gate timeout instead.
sleep "$LEAVE_SECS"
echo "peer leaving at t+${LEAVE_SECS}s (mode: $LEAVE_MODE)"
if [ "$LEAVE_MODE" = timeout ]; then
    kill $C2 2>/dev/null || true
else
    kill $C2 $FN2 2>/dev/null || true
fi

wait $C1 || true

python3 - "$RIG" <<'EOF'
import os, re, sys
rig = sys.argv[1]

def cells(path):
    mem = {}
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[a + i] = int(w.rstrip("*"), 16)
    return mem

m = cells(f"{rig}/plc1.out")
# BACKTAB -> text: UI_PRINT writes card = (ascii - 32) << 3 | colour
rows = []
for r in range(12):
    s = ""
    for c in range(20):
        w = m.get(0x200 + r * 20 + c, 0)
        ch = (w >> 3) + 32
        s += chr(ch) if 32 <= ch < 127 else " "
    rows.append(s.rstrip())
print("console 1 screen:")
for r in rows:
    print(f"  |{r}|")

active, dropped = m.get(0x8162, 0), m.get(0x8163, 0)
print(f"NET_ACTIVE={active} NET_DROPPED={dropped}")
scr, why = m.get(0x8185, 0), m.get(0x8186, 0)
diag = [m.get(0x8180 + i, 0) for i in range(4)]
screen = "\n".join(rows)
notice = "OPPONENT LEFT" in screen or "CONNECTION LOST" in screen
print(f"PEER_SCR={scr} PEER_WHY={why} "
      f"({'server said peer left' if why else 'we timed out'}) "
      f"diag(slip,rej,tmo,err)={diag}")
want = "CONNECTION LOST" if os.environ.get("LEAVE_MODE") == "timeout" \
       else "OPPONENT LEFT"
ok = scr == 1 and notice and "PRESS RESET" in screen and want in screen
print(f"expected notice for this mode: {want!r} -> {'present' if want in screen else 'MISSING'}")
print("PEER-LEFT PASS" if ok else "PEER-LEFT FAIL")
sys.exit(0 if ok else 1)
EOF
