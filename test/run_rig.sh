#!/bin/sh
# Full local N-player rig (PLAYERS=2..4, default 2), headless:
#   Nx fujinet-pc-rs232 (isolated copies, BOIP :19851..:1985N)
#   1x intv_relay_server (:9110, --auto-go N)
#   Nx jzintv --fujinet (net1 waits; net2..netN auto-join), fuzz inputs
# Pass criteria: every console NET_ACTIVE with matching seat/count, ticks
# advance, DIAG counters zero, N-way CRC rounds verified, no mismatches.
set -e
. "$(dirname "$0")/serverlib.sh"
BUILD=build
RIG="$BUILD/rig"
PLAYERS="${PLAYERS:-2}"

# Refuse to run rig binaries built against anything but the local server:
# fuzz inputs must never reach production.
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_rig.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild with"
    echo "  make SRV_HOST=127.0.0.1 build/seabattle_net1.bin ..."
    exit 1
fi
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
FNPC_DIST="${FNPC_DIST:-$HOME/Workspace/fujinet-pc-rs232/build/dist}"
RUN_SECS="${RUN_SECS:-90}"

# ---- fujinet-pc instances -------------------------------------------------
i=1
while [ "$i" -le "$PLAYERS" ]; do
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
    i=$((i+1))
done

# Stale rig fujinet instances hold the BOIP ports and make every later
# launch a silent no-op (the fresh copy fails to bind and dies).
pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
FNS=""
i=1
while [ "$i" -le "$PLAYERS" ]; do
    ( cd "$RIG/fn$i" && exec ./fujinet -u 127.0.0.1:1808$i ) > "$RIG/fn$i.log" 2>&1 &
    FNS="$FNS $!"
    i=$((i+1))
done
( relay_server --port 9110 --auto-go "$PLAYERS" ) \
    > "$RIG/server.log" 2>&1 &
SRV=$!
trap 'kill $FNS $SRV 2>/dev/null || true' EXIT
sleep 1.5

# ---- console debugger scripts --------------------------------------------
# Console N stirs the title RNG (N-1) extra bursts so every GUESTnn name
# and fuzz seed differs (headless runs are otherwise identical).
CONS=""
i=1
while [ "$i" -le "$PLAYERS" ]; do
    {
        printf 'b 14D5\nr 10000000\n'
        j=1
        while [ "$j" -lt "$i" ]; do
            printf 'n 14D5\nr %d\nb 14D5\nr 10000000\n' $((0x49BF0 + i * 4369))
            j=$((j+1))
        done
        # Later consoles launch 2 s apart; shorten their runs so everyone
        # quits at about the same wall moment (a console outliving its
        # peers by more than the gate timeout would count a bogus drop).
        printf 'g 7 14D7\nn 14D5\nr %d\nm 8100 20\nm 8150 60\nm 81C0 30\nm 80C0 2\nm 0160 10\nq\n' \
            $(( (RUN_SECS - 2 * (i - 1)) * 200000 ))
    } > "$RIG/c$i.scr"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/c$i.scr" \
        --fujinet=localhost:1985$i -e rom/exec.bin -g rom/grom.bin \
        "$BUILD/seabattle_net$i.bin" > "$RIG/c$i.out" 2>&1 &
    CONS="$CONS $!"
    sleep 2
    i=$((i+1))
done
wait $CONS || true

# ---- verdict --------------------------------------------------------------
PLAYERS=$PLAYERS python3 - "$RIG" <<'EOF'
import os, re, sys
rig = sys.argv[1]
players = int(os.environ["PLAYERS"])

def cells(path):
    mem = {}
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[a + i] = int(w.rstrip("*"), 16)
    return mem

ok = True
seats = set()
for n in range(1, players + 1):
    m = cells(f"{rig}/c{n}.out")
    tick = m.get(0x8108, 0) | (m.get(0x8109, 0) << 8)
    name = "".join(chr(m.get(0x8150 + i, 0)) for i in range(8)).rstrip("\0")
    active, dropped = m.get(0x8162, 0), m.get(0x8163, 0)
    seat, count = m.get(0x8160, 9), m.get(0x819D, 0)
    # DIAG_SLIP/REJ/TMO/ERR: a healthy session must not resync its framing,
    # refuse a state chunk, or time out a mailbox transaction even once.
    diag = [m.get(0x8180 + i, 0) for i in range(4)]
    roster = ["".join(chr(m.get(0x81C0 + 9 * s + i, 0)) for i in range(8)).rstrip("\0")
              for s in range(count)]
    gtbl = m.get(0x80C0, 0) | (m.get(0x80C1, 0) << 8)
    phase = m.get(0x164, 0)
    print(f"console {n}: name={name!r} seat={seat} count={count} "
          f"active={active} dropped={dropped} tick={tick} "
          f"diag(slip,rej,tmo,err)={diag} $0164=${phase:02X} "
          f"roster={roster}")
    seats.add(seat)
    ok &= (active == 1 and dropped == 0 and tick > 200
           and diag == [0, 0, 0, 0] and count == players)
    # Destination-phase assertion (PORTING.md §5.5, §7.25).  Any multi-console
    # gate can park identically in a prompt exactly as a det pair can.  This
    # rig build runs masked $3F disc-only fuzz (NET_FUZZ), which can NEVER
    # produce a keypad digit or ENTER -- so it can never launch a fleet and
    # will sit in $0164==1 (map, idle) for the WHOLE run, by design (this is
    # a real limitation, not a bug: confirm the mechanism only, not gameplay
    # coverage, until this rig script is extended to inject the scripted
    # keypad sequence too).  The one real trap this cart can still hit under
    # pure disc fuzz is $0164==6 (GAME OVER, terminal) -- unreachable without
    # a launched fleet today, kept as a guard for when that changes.
    if phase == 0x06:
        print(f"console {n}: PARKED AT GAME OVER (\\$0164=$06) -- terminal, "
              f"every dump agrees trivially")
        ok = False
ok &= seats == set(range(players))
if seats != set(range(players)):
    print(f"seat coverage wrong: {sorted(seats)}")

log = open(f"{rig}/server.log").read()
mm = log.count("CRC MISMATCH")
rounds = max([int(x) for x in
              re.findall(r"\((\d+) rounds\)", log)] or [0])
print("server: match" if "match: room" in log else "server: NO MATCH",
      f"crc_mismatches={mm} crc_rounds={rounds}")
ok &= "match: room" in log and mm == 0 and rounds > 0
print(f"RIG PASS ({players} players)" if ok else "RIG FAIL")
sys.exit(0 if ok else 1)
EOF
