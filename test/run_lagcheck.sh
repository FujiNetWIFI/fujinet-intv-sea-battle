#!/bin/sh
# M4 interception proof: the same in-ROM demo script, run at d=0
# (soccer_lag0) and d=20 (soccer_lag).  The delay ring is the ONLY
# difference between the two builds, so the whole game-state timeline must
# come out shifted by exactly d.
#
# What is sampled: $0321 and $0339 -- object-record field +4 of the two
# controlled players ($031D + 4 and $0335 + 4).  Those are the cells the
# polled read at L_57E1 writes the decoded direction into, so they are
# where intercepted input actually LANDS IN GAME STATE, one step past the
# shadow pair.  (Watching the shadow pair itself would only prove the ring
# shifted, not that the cart consumed it.)
#
# The verdict cross-correlates the two series and reports the shift that
# best aligns them, rather than edge-detecting one cell.  Both records hold
# nonzero junk from initialization, and the ISR integrates motion into the
# same table, so there is no clean "first change" edge to key on -- but the
# sequence of values is highly distinctive and aligns at exactly one lag.
#
# NOT keyed on $0179: the kickoff hold releases on its own timer at tick 45
# in BOTH builds (measured -- spikes/NOTES.md M4), so the phase cell is not
# input-driven and would report a shift of 0.
#
# Pure `r N` parks, no breakpoints: deterministic per build (PORTING.md
# §7.17 bans breakpoint-forced injection for exact-tick work, not
# instruction-count parks).  Remember `r N` counts INSTRUCTIONS, ~4.6
# cycles each (§7.11), so ~7000 gives roughly one sim tick per sample.
set -e
cd "$(dirname "$0")/.."
BUILD=build
JZINTV=${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}

make -s $BUILD/soccer_lag0.bin $BUILD/soccer_lag.bin >/dev/null

probe() {  # $1 = binary, $2 = output log
    {
        printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'
        i=0
        while [ "$i" -lt 220 ]; do
            printf 'r 7000\nm 8108 2\nm 0320 2\nm 0338 2\n'
            i=$((i+1))
        done
        printf 'q\n'
    } > $BUILD/lagprobe.scr
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        timeout 300 "$JZINTV" -d --script=$BUILD/lagprobe.scr \
        -e rom/exec.bin -g rom/grom.bin "$1" > "$2" 2>&1 || true
}

probe $BUILD/soccer_lag0.bin $BUILD/lag0.log
probe $BUILD/soccer_lag.bin  $BUILD/lag20.log

python3 - $BUILD/lag0.log $BUILD/lag20.log <<'EOF'
import re, sys

def series(path):
    """tick -> (seat0 velocity field, seat1 velocity field)"""
    log = open(path).read()
    d = re.findall(r'^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#', log, re.M)
    seq = [(int(a, 16), [int(w.rstrip('*'), 16) for w in b.split()]) for a, b in d]
    out, tick, v0 = {}, None, None
    for a, w in seq:
        if a == 0x8108:
            tick = w[0] | (w[1] << 8)
        elif a == 0x320:
            v0 = w[1]                       # $0321
        elif a == 0x338 and tick is not None and v0 is not None:
            out[tick] = (v0, w[1])          # $0339
    return out

a = series(sys.argv[1])
b = series(sys.argv[2])
if len(a) < 40 or len(b) < 40:
    print(f"LAGCHECK FAIL: too few samples (d=0 {len(a)}, d=20 {len(b)})")
    sys.exit(1)

# Score each candidate shift by how many sampled ticks agree.  Only count
# ticks whose value is "interesting" (nonzero on at least one seat), so a
# long idle stretch cannot make every shift look equally good.
best = []
for s in range(0, 41):
    hit = tot = 0
    for t, va in a.items():
        vb = b.get(t + s)
        if vb is None:
            continue
        if va == (0, 0) and vb == (0, 0):
            continue
        tot += 1
        if va == vb:
            hit += 1
    if tot >= 20:
        best.append((hit / tot, hit, tot, s))
if not best:
    print("LAGCHECK FAIL: no shift had enough overlapping samples")
    sys.exit(1)
# This is a PEAK test, not an absolute-agreement test.  The sampled cells
# are integrated by the ISR within a tick and the two runs' sample instants
# do not fall at identical points inside a tick, so even a perfectly
# aligned pair agrees on well under 100% of samples.  What matters is that
# agreement has a sharp, isolated maximum at the delay depth.
by_shift = {s: sc for sc, h, t, s in best}
peak_sc, peak_hit, peak_tot, shift = max(best)
base = sorted(by_shift.values())[len(by_shift) // 2]     # median shift score
zero = by_shift.get(0)

print(f"best alignment: shift = {shift} ticks "
      f"({peak_hit}/{peak_tot} = {peak_sc:.0%} agree)")
print(f"baseline      : median shift score {base:.0%}"
      + (f", shift=0 {zero:.0%}" if zero is not None else ""))
top = sorted(best, reverse=True)[:4]
print("top shifts    : " + ", ".join(f"{s}:{sc:.0%}" for sc, h, t, s in top))

if not (17 <= shift <= 23):
    print(f"LAGCHECK FAIL: agreement peaks at shift {shift}, expected ~20")
    sys.exit(1)
if base and peak_sc < 1.25 * base:
    print(f"LAGCHECK FAIL: peak {peak_sc:.0%} is not clearly above the "
          f"{base:.0%} baseline -- no timeline shift is discernible")
    sys.exit(1)
if zero is not None and peak_sc < 1.25 * zero:
    print(f"LAGCHECK FAIL: shift {shift} ({peak_sc:.0%}) is not clearly "
          f"better than shift 0 ({zero:.0%}) -- the delay ring is inert")
    sys.exit(1)
print(f"LAGCHECK PASS: interception + delay ring proven -- input lands in "
      f"game state {shift} ticks later")
print(f"  (agreement peaks at {peak_sc:.0%} vs a {base:.0%} baseline)")
EOF
