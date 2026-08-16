#!/bin/sh
# Full local 2-player rig, headless:
#   2x fujinet-pc-rs232 (isolated copies, BOIP :19851/:19852)
#   1x intv_relay_server (:9102)
#   2x jzintv --fujinet (net1 = waits, net2 = auto-joins), fuzz local inputs
# Pass criteria: both consoles NET_ACTIVE, ticks advance, no CRC mismatches.
set -e
BUILD=build
RIG="$BUILD/rig"

# Refuse to run rig binaries built against anything but the local server:
# fuzz inputs must never reach production.
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_rig.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild with"
    echo "  make SRV_HOST=127.0.0.1 build/football_net1.bin build/football_net2.bin"
    exit 1
fi
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
FNPC_DIST="${FNPC_DIST:-$HOME/Workspace/fujinet-pc-rs232/build/dist}"
RUN_SECS="${RUN_SECS:-90}"

# ---- fujinet-pc instances -------------------------------------------------
for i in 1 2; do
    if [ ! -d "$RIG/fn$i" ]; then
        mkdir -p "$RIG/fn$i"
        cp -r "$FNPC_DIST"/. "$RIG/fn$i/"
        rm -rf "$RIG/fn$i/SD"
        mkdir -p "$RIG/fn$i/SD"
        python3 - "$RIG/fn$i/fnconfig.ini" "1985$i" <<'EOF'
import re, sys
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
s2, n = re.subn(r"(\[BOIP\][^\[]*?port=)[0-9]*", r"\g<1>" + port, s, count=1, flags=re.S)
assert n == 1, "BOIP port not patched"
open(path, "w").write(s2)
EOF
    fi
done

# Stale rig fujinet instances hold the BOIP ports and make every later
# launch a silent no-op (the fresh copy fails to bind and dies).
pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
( cd "$RIG/fn1" && exec ./fujinet -u 127.0.0.1:18081 ) > "$RIG/fn1.log" 2>&1 &
FN1=$!
( cd "$RIG/fn2" && exec ./fujinet -u 127.0.0.1:18082 ) > "$RIG/fn2.log" 2>&1 &
FN2=$!
python3 server/intv_relay_server.py --port 9102 > "$RIG/server.log" 2>&1 &
SRV=$!
trap 'kill $FN1 $FN2 $SRV 2>/dev/null || true' EXIT
sleep 1.5

# ---- console debugger scripts --------------------------------------------
# Console 2 stirs the title RNG an extra 300k cycles so its GUESTnn name and
# fuzz seed differ from console 1's (headless runs are otherwise identical).
printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr %d\nm 8100 20\nm 8150 40\nq\n' \
    $((RUN_SECS * 900000)) > "$RIG/c1.scr"
printf 'b 14D5\nr 10000000\nn 14D5\nr 49BF0\nb 14D5\nr 10000000\ng 7 14D7\nn 14D5\nr %d\nm 8100 20\nm 8150 40\nq\n' \
    $((RUN_SECS * 900000)) > "$RIG/c2.scr"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout $((RUN_SECS + 150)) "$JZINTV" -d --script="$RIG/c1.scr" \
    --fujinet=localhost:19851 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/football_net1.bin" > "$RIG/c1.out" 2>&1 &
C1=$!
sleep 2
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout $((RUN_SECS + 150)) "$JZINTV" -d --script="$RIG/c2.scr" \
    --fujinet=localhost:19852 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/football_net2.bin" > "$RIG/c2.out" 2>&1 &
C2=$!
wait $C1 $C2 || true

# ---- verdict --------------------------------------------------------------
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
for n in (1, 2):
    m = cells(f"{rig}/c{n}.out")
    tick = m.get(0x8108, 0) | (m.get(0x8109, 0) << 8)
    name = "".join(chr(m.get(0x8150 + i, 0)) for i in range(8)).rstrip("\0")
    active, dropped = m.get(0x8162, 0), m.get(0x8163, 0)
    # DIAG_SLIP/REJ/TMO/ERR: a healthy session must not resync its framing,
    # refuse a state chunk, or time out a mailbox transaction even once.
    diag = [m.get(0x8180 + i, 0) for i in range(4)]
    print(f"console {n}: name={name!r} active={active} dropped={dropped} "
          f"tick={tick} diag(slip,rej,tmo,err)={diag}")
    ok &= active == 1 and dropped == 0 and tick > 200 and diag == [0, 0, 0, 0]

log = open(f"{rig}/server.log").read()
mm = log.count("CRC MISMATCH")
pairs = max([int(x) for x in
             re.findall(r"\((\d+) pairs\)", log)] or [0])
print("server: match" if "match:" in log else "server: NO MATCH",
      f"crc_mismatches={mm} crc_pairs={pairs}")
ok &= "match:" in log and mm == 0 and pairs > 0
print("RIG PASS" if ok else "RIG FAIL")
sys.exit(0 if ok else 1)
EOF
