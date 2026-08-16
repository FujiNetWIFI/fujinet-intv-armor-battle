#!/bin/sh
# Lobby-select test: one interactive console (football_net.bin, AUTO_JOIN=0)
# against a lobby that already holds three players, the first two of them
# already matched with each other.  Drives the menu from the debugger and
# decodes console 1's BACKTAB -- text AND colour -- at each step.
#
# Pass criteria:
#   * the prompt row survives the first lobby refresh (it used to sit inside
#     the band SES_RENDER clears, so it vanished and left no way to know that
#     anything but ENTER did something)
#   * players already in a match render dimmed and refuse ENTER out loud
#   * the disc moves the cursor, not just keypad 2/8
#   * ENTER joins the *selected* entry
set -e
BUILD=build
RIG="$BUILD/rig"
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"

[ -d "$RIG/fn1" ] || { echo "run 'make rig' once first (creates fn1/fn2)"; exit 1; }

if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_lobby.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild with"
    echo "  make SRV_HOST=127.0.0.1 build/football_net.bin"
    exit 1
fi

# Stale rig fujinet instances hold the BOIP ports and make every later
# launch a silent no-op (the fresh copy fails to bind and dies).
pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
( cd "$RIG/fn1" && exec ./fujinet -u 127.0.0.1:18081 ) > "$RIG/lb_fn1.log" 2>&1 &
FN1=$!
python3 server/intv_relay_server.py --port 9102 > "$RIG/lb_server.log" 2>&1 &
SRV=$!
trap 'kill $FN1 $SRV $IDLERS 2>/dev/null || true' EXIT
sleep 1.5
python3 test/lobby_idlers.py ALPHA BRAVO CHARLIE --pair > "$RIG/lb_idlers.log" 2>&1 &
IDLERS=$!
sleep 0.5

# A keypress is injected by breaking on the instruction right after the menu's
# `MVI $1FF,R0 / XORI #$FF,R0` and forcing R0 to the value the port would have
# produced; poking $01FF itself does not reach the emulated pad.
MENU_RD=$(awk '/CMP  *MENU_PREV, R0/ {print $1; exit}' "$BUILD/football_net.lst")
[ -n "$MENU_RD" ] || { echo "run_lobby.sh: cannot find MENU_PREV compare in the listing"; exit 1; }
echo "menu read site: \$$MENU_RD"
KEY8=44         # keypad 8   = down
KEYE=28         # ENTER
DISC_S=01       # disc south = down
DISC_N=04       # disc north = up

press() {       # $1 = raw value: stop at the read, force it, resume
    printf 'b %s\nr 10000000\ng 0 %s\nn %s\nr 100000\n' "$MENU_RD" "$1" "$MENU_RD"
}

{
    printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'
    # `m 200 F0` opens a snapshot, so every other dump for a step must follow it
    printf 'r 4000000\nm 200 F0\nm 815A 4\n'            # lobby up
    press "$KEYE"; printf 'm 200 F0\nm 815A 4\n'        # ENTER on a busy entry
    press "$DISC_S"; printf 'm 200 F0\nm 815A 4\n'      # disc down -> BRAVO
    press "$DISC_N"; printf 'm 200 F0\nm 815A 4\n'      # disc up   -> ALPHA
    press "$KEY8"; press "$KEY8"                        # keypad down x2 -> CHARLIE
    printf 'm 200 F0\nm 815A 4\n'
    press "$KEYE"; printf 'r 800000\n'                  # ENTER on the idle one
    printf 'm 200 F0\nm 8160 4\nm 8170 9\n'
    printf 'q\n'
} > "$RIG/lb1.scr"

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 240 "$JZINTV" -d --script="$RIG/lb1.scr" \
    --fujinet=localhost:19851 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/football_net.bin" > "$RIG/lb1.out" 2>&1 || true

python3 - "$RIG" <<'EOF'
import re, sys
rig = sys.argv[1]
text = open(f"{rig}/lb1.out").read()

# Walk every dump line in order.  A block covering $0200 ends the previous
# screen snapshot; MENU_SEL is recorded each time a block covers $815A, so the
# cursor's whole path shows up even for steps that dump no screen.
snaps, sels, cur, seen = [], [], {}, False
for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#", text, re.M):
    a = int(m.group(1), 16)
    words = [int(w.rstrip("*"), 16) for w in m.group(2).split()]
    if a <= 0x815A < a + len(words):
        sels.append(words[0x815A - a])
    if a <= 0x200 < a + len(words) and seen:
        snaps.append(cur)
        cur = {}
    if a <= 0x200 < a + len(words):
        seen = True
    for i, w in enumerate(words):
        cur[a + i] = w
snaps.append(cur)

COLNAME = {0: "black", 1: "BLUE", 2: "RED", 6: "yellow", 7: "white",
           8: "GREY", 9: "cyan"}

def row_text_and_colour(mem, r, from_col=0):
    # Card word: bits 3-10 = GROM card, bits 0-2 + bit 13 = foreground colour.
    # The card index must be masked to 8 bits or colours >= 8 (which set bit
    # 13) push it out of the printable range and read back as blanks.
    s, cols = "", set()
    for c in range(20):
        w = mem.get(0x200 + r * 20 + c, 0)
        ch = ((w >> 3) & 0xFF) + 32
        s += chr(ch) if 32 <= ch < 127 else " "
        if ch != 32 and c >= from_col:      # blanks carry no colour
            cols.add((w & 7) | (((w >> 13) & 1) << 3))
    return s.rstrip(), cols

def show(mem, label):
    print(f"--- {label}")
    for r in range(12):
        s, cols = row_text_and_colour(mem, r)
        if not s:
            continue
        tag = "/".join(COLNAME.get(c, str(c)) for c in sorted(cols))
        print(f"  {r:2d} |{s:<20}|  {tag}")
    print(f"     MENU_SEL={mem.get(0x815A)} LOBBY_CNT={mem.get(0x815C)}")

labels = ["lobby up", "ENTER on busy ALPHA", "disc down -> BRAVO",
          "disc up -> ALPHA", "keypad down x2 -> CHARLIE",
          "ENTER on idle CHARLIE"]
for i, mem in enumerate(snaps):
    show(mem, labels[i] if i < len(labels) else str(i))
    if 0x8170 in mem:
        opp = "".join(chr(mem.get(0x8170 + j, 0)) for j in range(8)).rstrip("\0")
        print(f"     NET_ROLE={mem.get(0x8160)} NET_ACTIVE={mem.get(0x8162)} opp={opp!r}")

print(f"--- MENU_SEL over time: {sels}")

ok = True
def check(cond, msg):
    global ok
    ok &= bool(cond)
    print(("  PASS  " if cond else "  FAIL  ") + msg)

print("--- checks")
first = snaps[0]
prompt, _ = row_text_and_colour(first, 3)
check("ENTER" in prompt and "DISC" in prompt,
      f"prompt survives the lobby refresh (row 3 = {prompt!r})")
# names start at column 2; column 0 is the yellow cursor
t_alpha, c_alpha = row_text_and_colour(first, 4, from_col=2)
t_charlie, c_charlie = row_text_and_colour(first, 6, from_col=2)
check(c_alpha == {0} and "ALPHA" in t_alpha,
      f"ALPHA (in a match) renders dimmed: {t_alpha!r} {sorted(c_alpha)}")
check(c_charlie == {7} and "CHARLIE" in t_charlie,
      f"CHARLIE (idle) renders white: {t_charlie!r} {sorted(c_charlie)}")
busy, _ = row_text_and_colour(snaps[1], 3)
check("ALREADY" in busy, f"ENTER on a busy player says so (row 3 = {busy!r})")
check(sels[:5] == [0, 0, 1, 0, 2],
      f"disc down/up and keypad down move the cursor, got {sels[:5]}")
last = snaps[-1]
opp = "".join(chr(last.get(0x8170 + j, 0)) for j in range(8)).rstrip("\0")
check(last.get(0x8162) == 1 and opp == "CHARLIE",
      f"ENTER joined the selected entry (active={last.get(0x8162)} opp={opp!r})")
t_you, c_you = row_text_and_colour(last, 5)
t_them, c_them = row_text_and_colour(last, 6)
role = last.get(0x8160)
me = "VISITOR" if role else "HOME"
them = "HOME" if role else "VISITOR"
check(me in t_you and c_you == {6},
      f"role {role}: 'YOU ARE {me}' in yellow: {t_you!r} {sorted(c_you)}")
check(them in t_them and c_them == {7},
      f"role {role}: 'THEY ARE {them}' in white: {t_them!r} {sorted(c_them)}")

print("LOBBY PASS" if ok else "LOBBY FAIL")
sys.exit(0 if ok else 1)
EOF

# ---- role 0 -------------------------------------------------------------
# The run above only ever makes the console a guest.  Do it again with an
# idler that hunts the console down and JOINs it, so the host branch of the
# matched screen (player 1, first car pick) is exercised too.
kill $IDLERS 2>/dev/null || true

# Console first: fujinet-pc holds the previous run's TCP session open for a
# while, so the server still has a stale GUEST47.  The new HELLO evicts it --
# start the hunter only after that has happened, or it JOINs the ghost.
HOLD=$(sed -n 's/^0x\([0-9A-F]*\) *SES_HOLD:.*/\1/p' "$BUILD/football_net.lst" | head -1)
[ -n "$HOLD" ] || { echo "run_lobby.sh: cannot find SES_HOLD in the listing"; exit 1; }
echo "matched-screen hold: \$$HOLD"
# Break where the matched screen is fully painted, dump it, then let the game
# start and dump again -- the game's own scoreboard screen proves the
# handover reached stock code.
printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\nb %s\nr 10000000\nn %s\nm 200 F0\nm 8160 4\nm 8170 9\nr 2000000\nm 200 F0\nq\n' \
    "$HOLD" "$HOLD" > "$RIG/lb2.scr"
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 180 "$JZINTV" -d --script="$RIG/lb2.scr" \
    --fujinet=localhost:19851 -e rom/exec.bin -g rom/grom.bin \
    "$BUILD/football_net.bin" > "$RIG/lb2.out" 2>&1 &
C2=$!
sleep 12
python3 test/lobby_idlers.py DELTA --join-guest GUEST > "$RIG/lb_idlers2.log" 2>&1 &
IDLERS=$!
wait $C2 || true

python3 - "$RIG" <<'EOF'
import re, sys
rig = sys.argv[1]
snaps, cur, seen = [], {}, False
for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                     open(f"{rig}/lb2.out").read(), re.M):
    a = int(m.group(1), 16)
    words = [int(w.rstrip("*"), 16) for w in m.group(2).split()]
    if a <= 0x200 < a + len(words):
        if seen:
            snaps.append(cur)
            cur = {}
        seen = True
    for i, w in enumerate(words):
        cur[a + i] = w
snaps.append(cur)

def row(mem, r):
    s, cols = "", set()
    cell = {}
    for c in range(20):
        w = mem.get(0x200 + r * 20 + c, 0)
        ch = ((w >> 3) & 0xFF) + 32
        s += chr(ch) if 32 <= ch < 127 else " "
        if ch != 32:
            col = (w & 7) | (((w >> 13) & 1) << 3)
            cols.add(col)
            cell[c] = col
    return s.rstrip(), cols, cell

ok = True
def check(cond, msg):
    global ok
    ok &= bool(cond)
    print(("  PASS  " if cond else "  FAIL  ") + msg)

mem = snaps[0]
print("--- console joined BY a peer (expect role 0 = visitors)")
for r in range(12):
    s, cols, _ = row(mem, r)
    if s:
        print(f"  {r:2d} |{s:<20}|  {sorted(cols)}")
role = mem.get(0x8160)
opp = "".join(chr(mem.get(0x8170 + j, 0)) for j in range(8)).rstrip("\0")
t_you, c_you, _ = row(mem, 5)
t_them, c_them, _ = row(mem, 6)
print(f"  NET_ROLE={role} NET_ACTIVE={mem.get(0x8162)} opp={opp!r}")
check(role == 0 and mem.get(0x8162) == 1 and opp == "DELTA",
      f"console is the host (role={role} opp={opp!r})")
check("HOME" in t_you and c_you == {6},
      f"host is told it is HOME, in yellow: {t_you!r} {sorted(c_you)}")
check("VISITOR" in t_them and c_them == {7},
      f"peer is named VISITOR, in white: {t_them!r} {sorted(c_them)}")

# Cross-check against the game itself: after the handover the stock game
# must be running -- its own scoreboard ("Home ... Visitor") is the proof.
game = snaps[-1]
rows = [row(game, r)[0] for r in range(12)]
print(f"--- game screen after handover: {[r for r in rows if r]!r}")
check(any(("Home" in r and "Visitor" in r) or "1st and" in r for r in rows),
      "game reached its own scoreboard screen after the handover")
print("ROLE0 PASS" if ok else "ROLE0 FAIL")
sys.exit(0 if ok else 1)
EOF

echo "--- server log"
cat "$RIG/lb_server.log"
