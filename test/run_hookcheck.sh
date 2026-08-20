#!/bin/sh
# M3 behavioral gate: drive the HOOK build (relocated timer table +
# MASTER_TICK dispatching all four game entries, no virtualization)
# through a kickoff and some live play, by forcing the EXEC scan's port
# reads (b $1527 left / $152E right, force R2 with the raw ACTIVE-LOW
# byte -- PORTING.md §7.12).  Verifies:
#   - the game runs at all (relocated table + MASTER_TICK dispatching)
#   - the phase machine advances: $0179 $02 (kickoff hold) -> $04 (live)
#   - the match clock runs -- entry 3 (interval 5) is firing
#   - all four virtualized countdowns stay inside their intervals --
#     SC_GAME_TICK's reload semantics are right (§7.24)
#   - the polled input path reaches the sim: both teams' MOB records move
#   - the ISR dance completes: $0100/$0101 back to the EXEC default $1126,
#     and the cart's saved copy at $0160/$0161 still holds it
#
# This is a smoke gate, not the human feel-test -- run `make run-hook`
# interactively for that.  Breakpoint-forced injection is not run-to-run
# deterministic (§7.17): assert coarse outcomes only, never exact ticks.
#
# Usage: run_hookcheck.sh [hook|virt]
#   hook (default): the real-dispatch build -- the M3 gate.
#   virt: the same injected presses through the RING replay path
#         (SPIKE_VIRT, d=0) -- the M5 virt==hook equivalence check.  Both
#         seats replay every tick (no turn arbiter on this cart), so the
#         same presses drive the same team in both modes.  Identical
#         outcome cells across both confirms the replay path is
#         timeline-equivalent to the real scan (PORTING.md §5.7).
set -e
cd "$(dirname "$0")/.."
BUILD=build
JZINTV=${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}
MODE=${1:-hook}
BIN=$BUILD/seabattle_$MODE.bin
make -s $BIN >/dev/null

# raw ACTIVE-LOW port bytes (port value = $FF XOR pressed-bits)
DN=FB; DS=F7; DE=FE; DW=FD              # disc north/south/east/west
BL=9F; BR=3F                            # bottom-left $60, bottom-right $C0

press() {  # $1 = active-low byte, $2 = held stops (default 6)
    n=${2:-6}
    printf 'b 1527\n'
    i=0
    while [ "$i" -lt "$n" ]; do printf 'r 60000\ng 2 %s\n' "$1"; i=$((i+1)); done
    printf 'n 1527\nr 120000\n'
}
pressR() {  # same, at the RIGHT port read ($152C -> stop at $152E)
    n=${2:-6}
    printf 'b 152E\n'
    i=0
    while [ "$i" -lt "$n" ]; do printf 'r 60000\ng 2 %s\n' "$1"; i=$((i+1)); done
    printf 'n 152E\nr 120000\n'
}
waitp() { printf 'r %d\n' $(( $1 * 15000 )); }   # ~$1 passes (4 frames each)

{
    printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'   # skip the title wait
    waitp 30
    printf 'm 0170 12\nm 0100 8\nm 015D 0A\n'         # BOOT dump
    printf 'm 035D 1\nm 8196 4\n'
    press $DN 10                                       # kick off
    waitp 20
    printf 'm 0170 12\nm 8196 4\n'                     # KICKOFF dump
    press $DE 14                                       # seat 0 runs
    pressR $DW 14                                      # seat 1 runs
    waitp 20
    printf 'm 0170 12\nm 031D 8\nm 0335 8\nm 8196 4\n' # PLAY dump 1
    press $BR 8                                        # action button
    pressR $BL 8
    waitp 40
    press $DS 14
    pressR $DN 14
    waitp 60
    printf 'm 0170 12\nm 031D 8\nm 0335 8\nm 8196 4\n' # PLAY dump 2
    printf 'm 0100 8\nm 015D 0A\nm 035D 1\n'
    printf 'q\n'
} > $BUILD/hookcheck.scr

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 300 "$JZINTV" -d --script=$BUILD/hookcheck.scr \
    -e rom/exec.bin -g rom/grom.bin "$BIN" \
    > $BUILD/hookcheck_$MODE.log 2>&1 || true

MODE="$MODE" python3 - "$BUILD/hookcheck_$MODE.log" <<'EOF'
import os, re, sys
log = open(sys.argv[1]).read()
dumps = re.findall(r'^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#', log, re.M)
seq = [(int(a, 16), [int(w.rstrip('*'), 16) for w in b.split()]) for a, b in dumps]

def rows(base):
    return [w for a, w in seq if a == base]

# `m 0170 12` prints two rows, $0170-$0177 and $0178-$017F.
r170, r178 = rows(0x170), rows(0x178)
# `m 015D 0A` / `m 0100 8` align down to $0158 / $0100.
r100 = rows(0x100)
# `m 8196 4` spans two printed rows: $8190 (holds $8196/$8197) and $8198.
r8190, r8198 = rows(0x8190), rows(0x8198)
r31d, r335 = rows(0x318), rows(0x330)

fail = []
def need(cond, msg):
    if not cond: fail.append(msg)

need(len(r178) >= 3, f"expected >=3 phase dumps, got {len(r178)}")
if len(r178) >= 3:
    boot, kick, play = r178[0][1], r178[1][1], r178[-1][1]
    need(boot == 0x02, f"boot phase $0179 != $02 (kickoff hold): ${boot:02X}")
    need(kick != 0x02 or play != 0x02,
         "phase never left the kickoff hold -- no play happened")
    need(play in (0x00, 0x04) or (play & 0x7B),
         f"final phase $0179 unrecognized: ${play:02X}")
    need(play != 0x40, "parked at PERIOD OVER ($0179 = $40) -- "
                       "masked fuzz cannot answer that prompt (§7.25)")

# The match clock is the destination-phase assertion: it only advances while
# $0179 == $0004, so "it moved" means real play actually ran.  (Measured at
# M1: the scroll accumulator does NOT move merely because a player runs, so
# it is not a usable liveness signal.)
need(len(r170) >= 3, f"expected >=3 clock dumps, got {len(r170)}")
if len(r170) >= 3:
    bmin, bsec = r170[0][4], r170[0][5]
    fmin, fsec = r170[-1][4], r170[-1][5]
    need((bmin, bsec) == (0x2D, 0x00),
         f"boot clock != 45:00: {bmin:02X}:{bsec:02X}")
    need((fmin, fsec) != (0x2D, 0x00),
         "match clock never advanced -- entry 3 (interval 5) is not firing, "
         "or play never started")

# Virtualized countdowns must stay inside their intervals every time we
# look.  A fire-on-negative reload (§7.24) shows up here as an out-of-range
# or never-changing value.
# (row, index, name, interval)
CNTS = [(r8190, 6, "SC_CNT2", 2), (r8190, 7, "SC_CNT3", 5),
        (r8198, 0, "SC_CNT4", 0x14)]
need(len(r8190) >= 3 and len(r8198) >= 3,
     f"expected >=3 countdown dumps, got {len(r8190)}/{len(r8198)}")
for rws, idx, name, iv in CNTS:
    vals = [row[idx] for row in rws]
    for v in vals:
        need(1 <= v <= iv,
             f"{name} = {v}, outside 1..{iv} -- reload semantics wrong (§7.24)")
    need(len(set(vals)) > 1 or name == "SC_CNT2",
         f"{name} never changed across the run: {sorted(set(vals))}")

# Polled input must reach the sim: both teams' MOB records must have moved.
# $031D is seat 0's controlled player, $0335 is seat 1's.
for base, rws, who in ((0x031D, r31d, "seat 0 ($031D)"),
                       (0x0335, r335, "seat 1 ($0335)")):
    need(len(rws) >= 2, f"expected >=2 MOB dumps for {who}, got {len(rws)}")
    if len(rws) >= 2:
        need(rws[0] != rws[-1],
             f"{who} MOB record never changed -- the polled input path "
             f"({'$57F1/$5884' if base == 0x031D else '$5818/$588A'}) "
             f"is not reaching the sim")

# The ISR dance must have completed and restored the EXEC default, and the
# cart's saved copy must still hold it (RS_CLAMP_ISR's invariant).
need(len(r100) >= 2, f"expected >=2 ISR dumps, got {len(r100)}")
for row in r100:
    vec = row[0] | (row[1] << 8)
    need(vec == 0x1126, f"$0100/$0101 = ${vec:04X}, not the EXEC default "
                        f"$1126 -- a game ISR is stranded (§7.10)")
    need(row[3] == 3, f"$0103 = {row[3]}, expected 3")
for row in rows(0x160):                 # $0160/$0161 lead the $0160 row
    saved = row[0] | (row[1] << 8)
    need(saved == 0x1126, f"$0160/$0161 = ${saved:04X}, not $1126 -- the "
                          f"cart's saved ISR vector is corrupt")

if fail:
    print("HOOKCHECK FAIL")
    for f in fail: print("  -", f)
    sys.exit(1)
print(f"HOOKCHECK PASS ({os.environ.get('MODE')}): kickoff -> live play,")
print("  match clock advancing, all four countdowns inside their intervals,")
print("  both teams' polled input reaching the sim, ISR dance clean")
EOF
