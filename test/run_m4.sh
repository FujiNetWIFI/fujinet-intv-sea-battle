#!/bin/sh
# M8 recovery test: the N-player rig with a fault injection -- console 2's
# game scratch cell $016D (the standing-pin mask: persistent, CRC-covered,
# game-consequential) is corrupted mid-run via the debugger.  Expected:
# CRC mismatch detected, the host pushes the state image (broadcast), ALL
# consoles re-baseline together, CRC rounds go back to matching, nobody
# drops.  PLAYERS=2..4 (default 2).
set -e
. "$(dirname "$0")/serverlib.sh"
BUILD=build
RIG="$BUILD/rig"
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
RUN_SECS="${RUN_SECS:-100}"
PLAYERS="${PLAYERS:-2}"

i=1
while [ "$i" -le "$PLAYERS" ]; do
    [ -d "$RIG/fn$i" ] || { echo "run 'make rig PLAYERS=$PLAYERS' once first"; exit 1; }
    i=$((i+1))
done

# Same guard as run_rig.sh: never point fuzz clients at production.
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_m4.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild first"
    exit 1
fi

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
    > "$RIG/m4_server.log" 2>&1 &
SRV=$!
trap 'kill $FNS $SRV 2>/dev/null || true' EXIT
sleep 1.5

# The debugger's `r N` counts INSTRUCTIONS (~4.6 cycles each on average),
# so ~200000 instructions per emulated second.  Console 2 gets the fault
# poke at ~40s (well past matchmaking at any player count); every console
# gets the stagger-compensated run length so all quit together.
CONS=""
i=1
while [ "$i" -le "$PLAYERS" ]; do
    SECS=$(( RUN_SECS - 2 * (i - 1) ))
    {
        printf 'b 14D5\nr 10000000\n'
        j=1
        while [ "$j" -lt "$i" ]; do
            printf 'n 14D5\nr %d\nb 14D5\nr 10000000\n' $((0x49BF0 + i * 4369))
            j=$((j+1))
        done
        printf 'g 7 14D7\nn 14D5\n'
        if [ "$i" = 1 ] && [ -n "$QUIESCE" ]; then
            # QUIESCE=1: 2 s after the fault lands, force the HOST's phase
            # cell to the kickoff hold ($02, a SC_PHASE_DEAD bit) so
            # RS_PENDING's quiescent branch is exercised instead of the cap.
            # Under fuzz the ball is otherwise never dead -- no goals are
            # scored, so $0179 sits at $04 for the whole run and the gate
            # code would never execute in any automated test.
            printf 'r 8400000\ne 179 2\nr %d\n' $(( (SECS - 42) * 200000 ))
        elif [ "$i" = 2 ]; then
            # Fault: rewrite console 2's OWN SCORE ($0177).  It is inside
            # the CRC range $015D-$01EF, it is unambiguously game state
            # rather than scratch, and a divergence in it is exactly the
            # kind a player would notice -- so recovery here is meaningful.
            printf 'r 8000000\ne 177 5\nr %d\n' $(( (SECS - 40) * 200000 ))
        else
            printf 'r %d\n' $(( SECS * 200000 ))
        fi
        printf 'm 8100 20\nm 8150 60\nm 80C0 2\nm 8180 10\nm 8090 10\nm 0170 10\nq\n'
    } > "$RIG/m4c$i.scr"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/m4c$i.scr" \
        --fujinet=localhost:1985$i -e rom/exec.bin -g rom/grom.bin \
        "$BUILD/seabattle_net$i.bin" > "$RIG/m4c$i.out" 2>&1 &
    CONS="$CONS $!"
    sleep 2
    i=$((i+1))
done
wait $CONS || true

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
for n in range(1, players + 1):
    m = cells(f"{rig}/m4c{n}.out")
    tick = m.get(0x8108, 0) | (m.get(0x8109, 0) << 8)
    active, dropped, hold = m.get(0x8162, 0), m.get(0x8163, 0), m.get(0x8090, 9)
    diag = [m.get(0x8180 + i, 0) for i in range(4)]
    pend, waited = m.get(0x8187, 0), m.get(0x8189, 0)
    seat = m.get(0x8160, 9)
    why = m.get(0x818A, 0)
    gtbl = m.get(0x80C0, 0) | (m.get(0x80C1, 0) << 8)
    gate = "n/a (guest)" if seat else {
        0: "never pushed",
        1: f"QUIESCENT (dead ball, $0179 AND $7B) after {waited} ticks",
        2: f"cap expired at {waited} ticks (pushed mid-motion)"}.get(why, "?")
    print(f"console {n}: seat={seat} active={active} dropped={dropped} "
          f"hold={hold} tick={tick} diag(slip,rej,tmo,err)={diag}")
    print(f"           resync gate: pending={pend} GAME_TBL=${gtbl:04X} -> {gate}")
    ok &= (active == 1 and dropped == 0 and hold == 0 and tick > 400
           and diag == [0, 0, 0, 0])
    # Destination-phase assertion (§7.25).  GAME_TBL is a constant on this
    # cart, so the check comes from game state -- same traps as the rig.
    phase, clk = m.get(0x179, 0), (m.get(0x174), m.get(0x175))
    print(f"           phase=${phase:02X} clock={clk[0]:02X}:{clk[1]:02X}")
    if phase == 0x40:
        print(f"console {n}: PARKED AT PERIOD OVER ($0179=$40) (§7.25)")
        ok = False
    if clk == (0x2D, 0x00):
        print(f"console {n}: match clock never left 45:00 -- play never went live")
        ok = False

# QUIESCE=1 exists to prove the quiescent branch works at all; require it.
if os.environ.get("QUIESCE"):
    host_why = cells(f"{rig}/m4c1.out").get(0x818A, 0)
    if host_why != 1:
        print(f"QUIESCE run: host RS_GATE={host_why}, expected 1 (quiescent) "
              f"-- the dead-ball branch of RS_PENDING did not fire")
        ok = False
    else:
        print("QUIESCE run: the dead-ball branch of RS_PENDING fired as intended")

lines = open(f"{rig}/m4_server.log").read().splitlines()
mm = [i for i, l in enumerate(lines) if "CRC MISMATCH" in l]
oks = [i for i, l in enumerate(lines) if "crc ok" in l]
recovered = bool(mm) and bool(oks) and max(oks) > max(mm)
print(f"server: mismatches={len(mm)} crc-ok-lines={len(oks)} "
      f"recovered-after-fault={recovered}")
ok &= recovered
print(f"M4 PASS ({players} players)" if ok else "M4 FAIL")
sys.exit(0 if ok else 1)
EOF
