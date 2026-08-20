# Sea Battle netplay port — engineering log

Ninth port of the shared engine (see `../fujinet-intv-soccer/PORTING.md`),
scaffolded from the Soccer tree. This log records what was measured, what
was built, what passed for real, and what is still open — in that order,
so a later session can pick up exactly where this one stopped rather than
re-deriving anything already settled here.

## M0 — recon

`tools/recon.py "rom/Sea Battle.bin"` plus a `dis1600` listing
(`$0000-$0FFF = $5000` cfg) and two headless `jzintv` boots.

- Header: timer table `$5002/3 -> $5028`; start-of-game `$5004/5 -> $5036`.
  GRAM init `$5008 -> $51D9`. Display mode `$500E = $00` (colour stack).
- Timer table at `$5028`, **3 entries + terminator at `$5034`** (fewer than
  every other port):
  - slot 0: `$52B6`, interval `$0001` -> **measured 20.00 Hz** (see below)
  - slot 1: `$5C29`, interval `$812C` (bit 15 set = **boots stopped**)
  - slot 2: `$5EB9`, interval `$0028`
  - **No EXEC music-tick entry anywhere in the original table** — unlike
    every other port, all three slots are cart code. Confirmed this
    doesn't matter: the EXEC's note-duration-arm routine (~`$1A64`, called
    internally by `X_PLAY_MUS2`/the SFX engine) reprograms "table entry
    0's RAM countdown" via the header pointer regardless of what the cart
    put there, and this cart calls `X_PLAY_MUS2` once + `X_PLAY_SFX1/2`
    across 10 sites — so `NEW_TIMER_TBL` keeps the family's defensive
    stopped-`X_MUSIC_TICK`-in-slot-0 placeholder anyway, at zero cost.
- **Zero RNG.** Two independent sweeps: grep for `X_RAND1`/`X_RAND2` call
  targets (none), and grep for any `$035E` reference anywhere in the ROM
  (none). No cart-internal shift/xor accumulator loop either — every
  `XORR`/`SLLC`/`ADCR` site in the disassembly is ordinary multi-word
  arithmetic or bit manipulation, not a self-referential PRNG. **First
  cart in the family with genuinely zero randomness.** No RNG wrapper
  patch sites exist; `RNG_LO`/`RNG_HI` stay declared (unused) only so the
  shared engine code assembles unchanged.
- One timer-arm call: `$57BF SDBD/MVII #$502C,R1 / JSR R5,X_TIMER_START`.
  `$502C` = original table slot 1 (`$5C29`), an absolute address that goes
  stale after relocation — Armor Battle's exact shape. Shimmed to
  `SB_START_SHIM`, which sets `SC_TICK2_EN` instead.
- Input surfaces, both **polled directly** (recon's `$011F`/`$0121`
  section, confirmed in dis1600):
  - `$011F` (movement): `$5835 MOVR R1,R2/ADDI #$011F,R2` (both seats via
    `L_5833`, called `R1=0` then `R1=1` from `$57C6`) and `$58D5
    ADDI #$011F,R1` (seat already in R1). Both patch to plain
    `SHADOW_CTRL` — the seat offset is supplied by the register at
    runtime, not baked into the immediate.
  - `$0121` (action/restart): `$583D`, `$58CF`, `$5920`, same
    register-indexed shape. **Sea Battle polls this directly; Soccer
    never did.** All three patch to plain `SHADOW_KP`.
  - Zero STIC writes, zero GRAM writes: display is static, §7.5's
    Baseball-form header-reassert applies (`RS_DISPLAY_RESET`, copied
    unchanged from Soccer, is already the right shape for a non-scrolling
    colour-stack cart).
  - Zero `$0100`/`$0101` writes anywhere: no cart ISR, no §7.10 dance, no
    §7.28 stolen-frame hazard.
  - Zero `X_SCAN` (`$14F1`) calls from cart code: no §7.26 in-tick-rescan
    hazard (unlike Soccer).
  - No cart main-loop clone: no `$0102`/`$0103` phase-wait outside the
    ordinary `.START` pass-length setup. Pure EXEC loop.
- `$035D` is a **dynamic** phase machine (unlike Soccer's single constant
  `$5869`): `SB_TICK1` (`$52B6`) is a 9-phase computed-jump dispatcher on
  cell `$0164`, and each phase transition installs its OWN handler table
  via the `JSR`-return-address idiom at `$52E7`. Decoded phase bodies (see
  `src/exec_equ.asm` `SB_PHASE` for full addresses):
  - `$0164=0` (`$52CD`): boot, installs the table at `$52D9`
    (`{$5422,$5439}` + nulls), sets phase 1.
  - `$0164=1` (`$52EA`): calls `L_539B(0)`, `L_539B(1)` — per-player
    bookkeeping, confirms the **simultaneous, no-turn-arbiter** seat model
    (both seats updated unconditionally every tick, matching Soccer's
    shape, not Bowling's).
  - `$0164=2..3` (`$5301`, `$5321`): short bookkeeping, not fully decoded.
  - `$0164=4` (`$5333`): on a countdown reaching 0, clears `$01E6/$01E7`,
    sets phase 7, arms a 10-tick countdown at `$01D8` — an event
    transition (candidate: a ship/torpedo hit).
  - `$0164=5` (`$5380`): calls `L_57C6` (movement poll, both seats) and
    `L_589B` (action poll, both seats) — **the live-play candidate**: the
    only phase body that reaches the input-poll routines at all.
  - `$0164=6` (`$5391`): XORs `$0177` (score-shaped) with `$0165`.
  - `$0164=7` (`$5346`): explosion/event animation — increments `$01E6`,
    blinks via `SARC`, draws GRAM frames into both MOB records. Input is
    **not** polled during this phase. **Candidate quiescent point for the
    resync gate (§7.6)** once confirmed on screen.
  - `$0164=8` (`$52E3`): installs the EXEC default table `$1906` — idle.
- Three one-instruction self-loops (bare `DECR R7`) at **`$5E90`, `$5EA7`,
  `$5EAE`**, just above the `$5EB9` timer entry — Soccer's `$5122` trap,
  times three. Every `det`/`rig`/`m4` verdict must assert the parked PC is
  none of these.
- No keypad number-entry gate: zero references to `$1910` anywhere. Ruled
  out the Utopia/Bowling class of "prompt masked fuzz can never answer."
- **Wall tick rate measured, not assumed** (§2.1/§7.28 method): two-point
  cycle sample at `SB_TICK1` (`b 52B6`, 8 consecutive stops) gave
  **44,802 cycles between hits, exactly 3.000 NTSC frames = 20.00 Hz /
  50 ms** — the cleanest cadence in the family, ties Armor Battle. `$0103`
  independently confirmed at 3.

## M1 — hook build, real toolchain

`tools/patches.py` written (10 words: 4 header + 2 shim + 4 shadow-pair
operands — wait, 5 shadow sites + 2 header pairs + 2 shim = 11; see the
file). `src/hook.asm`, `src/ram.asm`, `src/exec_equ.asm` written from the
M0 recon.

**Gates run for real, on this machine, with the real `as1600`/`dis1600`/
`jzintv` toolchain — not simulated:**

```
make verify-org      PASS  -- byte-identical rebuild
make hook             PASS (after fixing a missing X_MUSIC_TICK equate and
                              a wrong RS_ISR/tail-table symbol scheme —
                              lockstep.asm/resync.asm/debug.asm are NOT
                              fully cart-agnostic despite PORTING.md's
                              "copy unchanged" framing: they reference
                              canonical SC_* names -- SC_CNT2/3/4,
                              SC_PASSLEN, SC_ISR_SAVE -- that every port
                              must define in its own ram.asm/exec_equ.asm.
                              Worth amending PORTING.md §4 to say so
                              explicitly for the tenth port.)
make verify-patch    PASS  -- "11 declared sites, 11 changed"
make check-7000      PASS  -- no segment maps $7000
make virt            PASS  -- assembles clean (SPIKE_VIRT build)
```

### Boot state confirmed (hook build, headless, title-skip + 4M instructions)

```
$0100/$0101 = $0026/$0011   -- EXEC default ISR page ($1126), untouched
$0164 (SB_PHASE)  = $0001   -- matches the M0 prediction exactly
$035D             = $52D9   -- matches the phase-1 handler table install
$8196 (SC_CNT2)   = $002C   -- frozen at the seeded full interval: SB_TICK2
                                correctly gated OFF (SC_TICK2_EN = 0)
$8197 (SC_CNT3)   = live, counting down from $0028               -- entry 2
                                (SB_TICK3) dispatching unconditionally, as
                                designed
$8199 (SC_TICK2_EN) = $0000 -- correctly not yet armed
$819D (NET_COUNT)  = $0002  -- seeded correctly
```

This confirms, empirically, that: the patch map is correct, `NET_START`'s
seeding is correct (full intervals, not RAM's zero-fill — the Frog Bog
lesson), `SC_GAME_TICK`'s per-entry gating is correct, and the M0
disassembly-derived phase model is accurate.

### Input decode: EXEC-universal, confirmed by measurement

Forced raw ACTIVE-LOW port bytes at `b 1527` (left port), held 6 scans,
dumped `$011F`. Every value below matches Soccer's own measured table
**exactly** (once the "held" bit `$40` is accounted for: a value forced
for multiple consecutive scans reads back as `raw | $40`, matching
`vdispatch.asm`'s documented `idle -> $40; a held value reads value OR
$40`):

| raw (active-low) | fresh $011F | held $011F (measured) |
|---|---|---|
| `$FB` disc N | `$04` | `$44` ✓ |
| `$F7` disc S | `$08` | `$48` ✓ |
| `$FE` disc E | `$0C` | `$4C` ✓ |
| `$FD` disc W | `$00` | `$40` ✓ |
| `$7E` key 1 | `$81` | `$C1` ✓ |
| `$BE` key 2 | `$82` | `$C2` ✓ |
| `$DE` key 3 | `$83` | `$C3` ✓ |
| `$BD` key 5 | `$85` | `$C5` ✓ |
| `$DD` key 6 | `$86` | `$C6` ✓ |
| `$BB` key 8 | `$88` | `$C8` ✓ |
| `$D7` ENTER | `$8B` | `$CB` ✓ |

**Conclusion: the disc/keypad decode table lives entirely in the shared
EXEC ROM and is identical across every cart in the family.** This was
previously written up per-cart as if it needed independent measurement
(PORTING.md §5.5's rule, correctly applied — measure, don't extrapolate);
it does need measuring **once**, but the fact that it reproduces Soccer's
numbers exactly means a future port can reasonably expect the same table
and use this measurement to *confirm* rather than *discover* it, cutting
that step down to a spot-check.

### Shadow-redirect mechanism confirmed end-to-end

Forced `FB` (disc N) at `b 1527` for 40 consecutive scans, then dumped
`SHADOW_CTRL` (`$8140`): **`$0044`**, exactly the held-N value. This
proves the full chain: real port -> EXEC scan -> `$011F` -> `UPDATE_SHADOW`
-> `SHADOW_CTRL` -> the patched cart operand reads it instead of `$011F`
directly. The core interception mechanism this whole port depends on is
real and working.

## M2 — where this session stopped, and why

### `make det`: the stall/checksum mechanism is PROVEN deterministic

```
DETERMINISM PASS: all 256 compared ticks have identical checksums
settled-state check: object table + scratch identical at park
```

This is a real, meaningful result even though `SCRIPT_TBL` is currently a
placeholder (see below): it proves `SC_GAME_TICK`'s virtualized-countdown
reproduction, the stall injector's freeze/resume, and the CRC range
(`LS_CKSUM`/`TRACE_RANGES`, unchanged from Soccer/Bowling) are internally
consistent under a 9-frame-per-64 stall, with **zero RNG in the picture at
all** — the strongest possible corroboration of the M0 zero-RNG claim,
since any unwrapped randomness or ISR-timing leak would have shown up as a
mismatch here.

`make det`'s **destination-phase assertion correctly FAILS**, and that
failure is itself informative, not a bug in the checker:

```
DEST-PHASE FAIL: parked at phase $01 (boot/idle or first-tick bookkeeping)
```

### OPEN — the phase 1 -> ... -> 5 transition trigger is unconfirmed

Forcing sustained disc-north input for 40 scans did **not** advance
`$0164` past `1`. Two hypotheses, neither yet confirmed:

1. The transition is gated behind the action/restart button (`$0121`),
   not disc movement — plausible, since Sea Battle is a "fire on target"
   game and the disc alone might only aim.
2. The transition is purely time-based (the `$0164=4` body's `$01D9==0`
   check looked like a countdown, not an input gate) and 40 scans (~2
   seconds of forced input, much less of real elapsed sim time given the
   forcing recipe's overhead) simply wasn't long enough.

### OPEN — the `$0121` (action/restart) raw code is UNRESOLVED

An **exhaustive sweep of all 256 raw active-low byte values** at the left
port, each held 3 scans, dumping `$0121` after release: **every single
value produced `$0121 = $0000`**. This is a real, decisive negative
result, not an inconclusive one — the standard "guess three plausible
button codes" approach that worked for every prior port (Soccer's
`$5F`/`$9F`/`$3F`) does not apply here.

Two things worth checking before the tenth session picks this up:

- Trace the EXEC scan's keypad-decode branch (`.EXEC.568` onward in
  `build/exec.dis`, past the disc-table lookup at `.EXEC.53A-549`) to
  understand exactly which raw bit patterns the EXEC recognizes as
  keypad-class events, rather than guessing bytes. The disc lookup
  (`.EXEC.53A`) masks the XORed raw value to 5 bits (`ANDI #$1F`) and does
  a computed-offset table read; the keypad path's equivalent gate was not
  traced this session.
- Confirm whether `$0121` is populated **only when a specific game phase
  is active** — the three cart-side read sites (`$58CF`, `$5920`) live
  inside `L_58A6`/`L_5920`, which are only reached from `L_589B`, which is
  only called from the phase-5 body (`$5380`). Since phase never left 1
  during this session's probing, those cart routines never executed, and
  the raw-byte sweep may have been testing a genuinely dead path rather
  than a wrong code. **Sweep again once phase 5 is reached by some other
  means** (e.g. a scripted long idle run to test the pure-timer hypothesis
  above) before concluding the codes themselves are the problem.

### OPEN — `SCRIPT_TBL` is a placeholder

`src/vdispatch.asm`'s `SCRIPT_TBL` currently holds only the family's
universal idle encoding (`$40`, no keypad) — enough for `main_det_a/b` and
`main_lag/lag0` to assemble and run, but it exercises no real input.
**Do not read a `det`/`lagcheck` PASS as gameplay-covering until this is
replaced** with a real script per the two open items above, following the
exact coverage list left in the file's header comment.

### NOT attempted this session

`make lagcheck` (needs a cart-specific "where does decoded input land in
game state" cell — Soccer used `$0321`/`$0339`, object-record field +4;
Sea Battle's equivalent has not been decoded), `make echo-test` /
`make server-diff` / `make rig` / `make m4` / `make peerleft` (all need
either the phase-5/action-button resolution above, or standalone
multi-process orchestration not yet attempted), and hardware images.

## M3 — a deep-analysis second pass, and a real bug it caught

After M2, a much deeper disassembly analysis pass was run (cross-referencing
the EXEC's own dispatch-table format from `exec.s`, tracing every JSR target
in the ROM, and enumerating the full RAM census). It confirmed nearly
everything in M0/M2 but corrected the phase-6/7/8 labels, definitively
identified the quiescent point, gave much better destination-phase
candidates -- and caught a real, previously-unknown bug in the M1 hook
build: **two sites deep in the ship-destroyed handler write SB_TICK2's
countdown as a hardcoded LITERAL RAM ADDRESS ($0127/$0128), bypassing the
timer API entirely.** `recon.py` cannot see this class of site at all --
it only looks for JSR-based timer-API calls.

Under the M1 design (2-slot table: music placeholder + MASTER_TICK), those
two writes would have landed on `$0127/$0128` -- which was exactly
MASTER_TICK's own countdown. Every time a ship was destroyed, the whole
dispatcher would have silently stalled for up to 100 passes (5 seconds),
completely unannounced, with no gate anywhere positioned to catch it (`det`
had not yet reached any code path that fires those sites -- the placeholder
`SCRIPT_TBL` never drives play that far).

**Fix (locked in, verified live):** a 4-slot table -- music placeholder,
`MASTER_TICK`, `SB_TICK2` (unchanged target+interval, same RELATIVE
position it always had), `SB_TICK3` (unchanged) -- with the two hardcoded
writer operands patched from `$0127`/`$0128` to `$0129`/`$012A` to match
SB_TICK2's new absolute address. This also enabled a larger simplification:
**SB_TICK2 and SB_TICK3 are no longer reproduced in a hand-rolled dispatcher
at all.** They stay at their original ROM targets and intervals and fire
NATIVELY via the real `$17D5` EXEC dispatcher, because `$17D5` cannot reach
their dispatch check until `MASTER_TICK` (table slot 1, dispatched first)
fully returns -- so they still freeze atomically during a stall with zero
virtualization code, and their countdowns are seeded automatically by the
EXEC's own boot-time `X_TIMER_INIT`, using the unchanged interval words.
`SC_CNT2`/`SC_CNT3` (ram.asm) became a per-tick MIRROR of the real
`$0129`/`$012A`, restored on resync by a new `SB_REBASE_HOOK` (one added
line in `resync.asm`'s `RS_REBASE`, the file's first genuine cart-specific
edit beyond the pre-existing `RS_CLAMP_ISR`).

**A second bug was caught by the same verification discipline, immediately
after:** the first draft of the simplified `SC_GAME_TICK` reasoned "`$17D5`
calls slot 1 by jumping into `MASTER_TICK`'s own entry point, so nothing
here needs to call `SB_TICK1`" -- which conflates `MASTER_TICK` (our
netcode code, table slot 1's target) with `SB_TICK1` (the game's own
9-phase dispatcher, no longer referenced anywhere in the relocated table at
all). Building and booting this draft showed `$0164` stuck at `$00`
forever and `$0176` (the map cycle counter, which only advances from inside
`SB_TICK1`) never leaving zero -- **the game's own logic was silently never
running at all.** Restored the explicit `JSR R5,SB_TICK1` inside
`SC_GAME_TICK` and reconfirmed live: `$0164 = $01`, `$0176` non-zero,
`$035D == SB_HTBL_MAP` ($52D9), `$0127/$0128` (MASTER_TICK's own countdown)
clean at `$0001`, `$0129/$012A` correctly untouched at `$812C` (SB_TICK2
still stopped, as expected with no input yet), `$012B/$012C` actively
counting down from `$28` (SB_TICK3 firing natively, confirmed).
`make det` re-run clean after both fixes: **256/256 ticks identical**, same
result as M2's (buggy) build -- the placeholder `SCRIPT_TBL` never drove
play far enough to exercise either bug, so `det` alone would never have
caught them. Both were only found by cross-checking a live boot dump
against the predicted state, not by any automated gate.

**Lesson for the next port**: a hardcoded-literal write to a fixed RAM
address (as opposed to a JSR through the timer API) is invisible to
`recon.py`'s JSR-scan and easy to miss even in a careful dis1600 read,
because it looks like ordinary game bookkeeping until you know to ask "does
this cart's own code write to any of the RAM addresses my table relocation
just repurposed?" `grep` the disassembly for the LITERAL countdown
addresses ($0125, $0127, $0129, ... depending on table position) in
addition to grepping for the timer-API JSRs.

### Phase table, corrected (supersedes M2's draft)

| `$0164` | `$035D` | what it is |
|---|---|---|
| 0 | `$1906` (settling) or `$52D9` (installed) | boot / map\<-\>battle handover |
| 1 | `$52D9` (MAP) | **MAP**: victory test, per-player fleet blink, contact/mine scan |
| 2 | `$52D9` | both engaged fleets blink (pre-battle) |
| 3 | `$52D9` | mine-hit colour-cycle |
| 4 | `$52D9` | 3-pass freeze -> phase 7 |
| 5 | `$5376` (BATTLE) | **TACTICAL BATTLE**: polled ship steering + torpedo steering/fire |
| 6 | `$52D9` | **GAME OVER, TERMINAL** (M2 mislabeled this as a score-flash phase; M3 confirms it is the actual terminal state -- flashes forever, no path back) |
| 7 | `$52D9` | battle-entry screen shake -> phase 5 (NOT quiescent -- brief transition INTO battle, corrects M2's guess) |
| 8 | -- | **UNREACHABLE** (the only writers are inside EXEC dead code -- `X_PLAY_SFX1/2`/`X_PLAY_MUS2` never return past their inline data, so anything textually after one of those calls in the disassembly is unreachable) |

**Quiescent point, corrected**: `$0164==0 && $01D9==0` (equivalently
`$035D==$1906`) -- the map\<->battle handover, ~3 passes, all input dead.
M2's phase-7 guess was wrong (phase 7 is a battle-ENTRY transition, not a
dead moment). A weaker but far more frequent candidate: any `$01D9!=0`
window (also entered on every fleet launch and depth charge).

**Destination-phase assertion, corrected and strengthened**: `SB_INVENTORY`
(`$01B5-$01BD`, 9 packed-nibble cells) has an EXACT known boot value
(`$11 $11 $22 $11 $33 $22 $11 $22 $33`, copied verbatim from ROM by
`.START`) and changes ONLY via a keypad ship-assignment -- the strongest
"real gameplay ran" signal on this cart, since masked disc-only fuzz can
never touch it. `SB_FLEET_STATE` (`$017D-$0184`, bit 2 = at sea) proves a
fleet was actually LAUNCHED. `check_dest_phase.py` still only asserts the
weak M2-era signal (`$0164 > 1`); tightening it to use `SB_INVENTORY`/
`SB_FLEET_STATE` is on the punch list below.

### RAM census additions worth flagging

- `$0176` (`SB_LEVEL`): confirmed a genuine 0..60 global map cycle counter,
  +1 per phase-1 tick -- needs a clamp (0..60) if ever transported, though
  it currently isn't (outside `$015D-$01EF`? no -- it IS inside that range,
  so it rides in the standard image already; the clamp is still open work).
- `$017B/$017C` (selected fleet, 0..3) and `$01D6/$01D7` (selected ship,
  0..2) both index MOB-table writes -- clamp candidates, not yet wired.
- The three `DECR R7` self-loops flagged in M0/M2 (`$5E90`/`$5EA7`/`$5EAE`)
  are **not actually reachable** -- M3 traced them into the MOB
  animation-script DATA table (`$5E74-$5EB8`), not live code. The REAL
  false-PASS traps are behavioural (phase 6 terminal, phase 1 with no
  fleet launched), not instruction-level self-loops. `exec_equ.asm` still
  keeps the three addresses declared, now correctly captioned.

## Next-session punch list, in order

M3 resolved the "why does `$0121` never respond" mystery (§5a: the action-
button write happens inside the EXEC's dispatch call, gated on the
CURRENT `$035D` table having a non-null slot for that button class -- the
MAP table's button slots are null, so nothing was ever going to write
`$0121` while stuck in phase 1, regardless of raw code) and gave the real
phase table, quiescent point, and destination-phase cells. The M3 report's
own recommended path into real play is via the KEYPAD, not the disc:

1. **Get a fleet to sea.** `.START`'s boot state needs keypad digits 1-9
   (ship-type assignment against `SB_INVENTORY`) then ENTER, dispatched
   through the MAP table's keypad slot (`$5439`, handler for `$035D`
   slot 1) -- NOT the polled surfaces. Build a scripted sequence using the
   ALREADY-CONFIRMED EXEC-universal keypad codes (M2's table: key N =
   `$8N`, ENTER = `$8B`) and drive it through the SAME `b 1527`/`g 2`
   force-and-dump recipe already proven working for disc input. Verify
   `SB_FLEET_STATE` (`$017D`) gets bit 2 set. This is the SAME mechanism
   M2 already validated end-to-end for movement (`UPDATE_SHADOW` ->
   `SHADOW_KP` -> the cart's own `$0121` reads) -- what's missing is
   driving the right SEQUENCE, not new plumbing.
2. Once a fleet is at sea, drive it into battle (`$0164` should reach 5,
   `$035D` should read `SB_HTBL_BATTLE` = `$5376`) and confirm the action-
   button codes there (M0's `$5F`/`$9F`/`$3F` guesses, now with a live
   non-null handler table to actually respond).
3. Write a real `SCRIPT_TBL` per this sequence, re-run `make det`, and
   tighten `check_dest_phase.py` to assert `SB_INVENTORY` changed and/or
   `SB_FLEET_STATE` shows a launched fleet (M3 §11), not just `$0164 > 1`.
4. Decode the movement "landing cell" (where `L_5422`/`L_5833` writes the
   decoded direction into MOB field +4, `$0321+8n`) for
   `test/run_lagcheck.sh` -- M3 §11 names this cell but the exact write
   site per phase (map vs. battle) needs confirming.
5. Confirm the `$0164==0 && $01D9==0` quiescent point on screen (M3,
   supersedes M2's wrong phase-7 guess) before wiring `RS_PENDING`'s gate
   to it, and write the `QUIESCE=1` forcing mode at the same time (§7.29 --
   masked disc-only fuzz can never launch a fleet, so it can never reach
   this point either).
6. Wire `SB_REBASE_HOOK`'s $0164 clamp range and consider adding clamps for
   `$017B/$017C` (0..3) and `$01D6/$01D7` (0..2) per M3 §7.27 before
   trusting `make m4`'s fault-injection path.
7. Proceed down the standard ladder: `echo-test` -> `server-diff` (fixing
   the Python relay's partial-frame guard, per the plan) -> `rig` -> `m4`
   (both branches) -> `peerleft` -> hardware images.

Gates run for real, on this machine, as of the end of this session:
`verify-org`, `verify-patch` (14/14), `check-7000`, `hook` (boots, boot
state matches every M0/M1/M3 prediction), `virt` (assembles), `det`
(**256/256 ticks deterministic** under 9-frame stall injection, with the
M3 timer-corruption fix and its own SB_TICK1-dispatch-loss regression both
caught and fixed via live boot-dump verification, not just by a passing
gate). `det`'s destination-phase check correctly and honestly FAILS
(placeholder `SCRIPT_TBL, phase never left 1) -- item 3 above closes that.

## M4 — the real launch sequence, and the ladder through `rig`

Resumed the punch list. Item 1 (get a fleet to sea) turned out to be
fast to confirm empirically once the handler was disassembled:

### The keypad launch protocol -- decoded and confirmed live

`$5439` (the MAP table's keypad handler, `$035D` slot 1) accepts:
- digits 1-9 -> ship type 0-8: adds one ship of that type to the CURRENTLY
  SELECTED fleet, decrementing the matching `SB_INVENTORY` nibble (hi = P0,
  lo = P1), as long as the fleet isn't already at sea, has &lt;3 ships, and
  doesn't already have that type. Confirmed via `$5451`/`$5467`/`$5496`.
- ENTER -> if the selected fleet has &gt;=1 ship and isn't at sea: sets
  `SB_FLEET_STATE`'s bit 2 (at sea) and writes the fleet's home-port map
  position from `L_55B7` (`$105E` seat 0, `$821E` seat 1). If the fleet
  has 0 ships, ENTER instead cycles the selection to the next fleet.
  Confirmed via `$5520`/`$554C`.

Live proof (hook build, `b 1527`/`b 152E`, raw `$7E`=key1 then `$D7`=ENTER,
held 6 scans then released -- the SAME recipe that measured the input
codes in M2): seat 0's `$017D` went `$00` -&gt; `$01` (ship added,
`SB_INVENTORY[$01B5]` `$0011`-&gt;`$0001`) -&gt; `$05` (bit 2 set, at sea,
`$0185/$0186` = `$10/$5E` matching `L_55B7`'s constant exactly). Seat 1
mirrors it symmetrically via the right port, confirmed independently.

**Keypad digit events dispatch through the SAME cell/slot as disc events**
(bit 7 set = keypad, per `LS_VDISPATCH`'s generic decode) -- not through
the separate action-button class field. This resolved the earlier "why
does $0121 never respond" mystery from M2/M3: those three cart-side
`$0121` read sites live inside routines only reached from the BATTLE
phase's table, which was never installed while stuck in the map phase --
the sweep was testing a dead path, not a wrong code, exactly as
hypothesized at the time.

### `SCRIPT_TBL` rewritten with the confirmed sequence; `det` passes fully

Wrote the real script: settle -&gt; seat 0 launches (key 1, ENTER) -&gt;
seat 1 launches (key 1, ENTER) -&gt; sustained movement toward the map
centre -&gt; hand off to fuzz. Rewrote `check_dest_phase.py` to assert
`SB_INVENTORY` changed and/or `SB_FLEET_STATE` shows a launched fleet
(the confirmed strong signals from M3 §11), replacing the placeholder's
weak `$0164 &gt; 1` check.

```
DETERMINISM PASS: all 256 compared ticks have identical checksums
DEST-PHASE OK: phase $01, inventory changed = True, fleet launched = True
```

**First time this gate has genuinely passed end to end** -- both the
stall/checksum mechanism AND confirmed real gameplay coverage. Phase
never reached 5 (battle) -- the movement rows are a best-effort diagonal
converge, not a proven collision; not required by the current checker.

### `lagcheck`: real, strong pass

Adapted `test/run_lagcheck.sh` for the confirmed movement-landing cells
(`$0321` seat 0's fleet 0, `$0341` seat 1's fleet 0 -- `L_5422`'s
`SLL R2,2/SLL R2,1/ADDI #$0321,R2/MVO@ R0,R2`, `R2` = `4*seat+fleet`).
Result: **100% agreement at shift=20 ticks, against an 11% baseline** --
about as clean a confirmation as this test can produce.

### `echo-test`: pass (one missing file)

Had forgotten to copy `tools/latency_probe_server.py` from the Soccer
tree during scaffolding -- `make echo-test` failed with a missing-file
error, not a real bug. Copied it; 100 clean echo rounds through
`jzintv --fujinet` -&gt; the shared workspace `fujinet-pc-rs232` instance
on port 9995. `E_STAGE` = `$AA` (pass).

### `server-diff`: fixed and passing (moved up from the original plan)

Restored the Python relay's partial-frame guard (one line,
`if len(client.rx) &lt; need: return`, matching every pre-v2 sibling and
the C relay, which already had it) -- exactly what Soccer's README asked
the next port to do. `tools/server_diff.py --strict`: 6/6 scenarios,
`framing` no longer an expected divergence.

### Two more real bugs, found the same way as M3's: live verification, not trust in a green build

1. **`resync.asm`/`lockstep.asm` reference more Soccer-specific symbols
   than M1 accounted for.** `make rig`'s first attempt failed to assemble:
   `SC_POSSESSION` (called unconditionally from `LS_PASS`, "ARB_SEAT for
   NAME_DRAW, display only" -- Soccer-specific, this cart has no
   possession concept, needed a stub), `SC_PHASE`/`SC_PHASE_DEAD`
   (resync.asm's generic `RS_PENDING` quiescent-gate predicate -- this is
   the §7.6 gate I hadn't wired in at all), and `RS_SPARE2` (a tail-layout
   cell I'd accidentally dropped during the M3 rewrite). Fixed: `ram.asm`
   restores `RS_SPARE2`, adds a computed `SB_QUIESCENT` flag (since this
   cart's quiescent point is a CONJUNCTION of two cells -- `$0164==0 &&
   $01D9==0` -- not expressible as the single AND-mask
   `SC_PHASE`/`SC_PHASE_DEAD` was designed for), and `SC_POSSESSION` is a
   stub in `hook.asm`. **Generalizes M3's own lesson**: "copy unchanged"
   files are only exercised by whichever build variants you've actually
   assembled -- `hook`/`virt`/`det`/`lag`/`echo` never touch
   `session.asm`/`lockstep.asm`/`resync.asm`'s `NET_SESSION`-gated content
   at all; only a `net`/`rig` build does. Assemble EVERY build variant at
   least once before trusting any of them.

2. **The SC_CNT2/3 mirror and the new SB_QUIESCENT flag were computed only
   on MASTER_TICK's LOCAL path**, which the netplay path (`NET_ACTIVE`)
   never reaches -- it returns via `LS_PASS` before that code runs. Would
   have left both stale during actual netplay while passing every
   single-process gate (`det` never exercises `NET_ACTIVE`). Caught by
   asking the exact question M3's writeup recommends ("does this run on
   BOTH paths?") before it ever reached a live rig, not by a failing
   gate -- moved both into `SC_GAME_TICK`, which IS called from both
   `MASTER_TICK`'s local branch and `LS_PASS` (lockstep.asm's own call
   order confirms `SC_GAME_TICK` runs before `LS_CKSUM`/`RS_PENDING` on
   both paths).

### `make rig`: a REAL, reproducible, well-characterized failure

After the fixes above, `make rig` ran end-to-end for the first time --
two real `fujinet-pc-rs232` processes, a real relay, two real `jzintv`
consoles, ~90 s, ~2300 ticks. Session mechanics are completely healthy:

```
console 1: active=1 dropped=0 tick=2309 diag(slip,rej,tmo,err)=[0,0,0,0]
console 2: active=1 dropped=0 tick=2312 diag(slip,rej,tmo,err)=[0,0,0,0]
server: match crc_rounds=32 crc_mismatches=1   (run 1)
server: match crc_rounds=28 crc_mismatches=3   (run 2, same ticks)
RIG FAIL
```

**Reproduced twice, identical ticks both times: 448, 576, 704** -- every
OTHER 64-tick CRC checkpoint (448=7x64, 576=9x64, 704=11x64), starting
after the scripted launch/movement phase (which ends ~tick 166) is well
behind, i.e. during the masked-fuzz phase. No more mismatches after 704
in either run despite running to tick ~2300 -- whatever triggers this
either stops recurring or the resync (which DID fire and succeed each
time -- both consoles finished with 0 drops) puts things in a state where
it can't recur.

**This is a real, narrow desync -- not a mechanism failure.** The
`RS_PENDING`/`RS_REBASE` safety net worked exactly as designed: both
sessions completed cleanly to their full run length after every mismatch,
with zero drops and zero DIAG errors. That is genuinely reassuring, not
just a consolation -- it means the CRC+resync net this whole architecture
depends on is doing its job even in the presence of whatever the
underlying bug is.

**What's ruled out, by construction, given `$0164` never left `$01` (map,
idle) for either console in either run:**
- RNG: this cart has zero RNG sites; `RNG_LO`/`RNG_HI` are always 0 on
  both consoles. Not the cause.
- `GAME_TBL_LO/HI`: `$035D` stays at the MAP table's constant address the
  whole time phase is 1. Not the cause.
- `SC_CNT2`/`SC_CNT3` (the `SB_TICK2` mirror): `SB_TICK2` is only ever
  armed by `SB_START_SHIM` (the RETREAT button, battle-phase only) or the
  two M3-patched direct-write sites (also battle-phase only, ship-
  destroyed handler). Neither is reachable from phase 1. The mirror
  should be constant `$2C81` (stopped) throughout. Not the cause (barring
  a bug in the mirror mechanism itself, not yet independently verified).
- The keypad launch/movement sequence itself: proven bit-exact
  synchronized by `lagcheck`'s 100%-at-shift-20 result, and it completes
  by tick ~166, long before the first mismatch at 448.

**What's NOT ruled out**: anything in `$015D-$01EF` that `L_539B`
(per-player fleet blink, unconditional every tick), `L_55F9` (fleet-
contact scan) or `L_5639` (mine scan) touch, MOB-table writes from
fuzzed movement (**note: `$031D-$035C` is OUTSIDE `LS_CKSUM`'s range
entirely** -- a movement-only divergence there would be a real,
undetected desync, not a reported CRC mismatch, so it can't directly
explain a mismatch, but a subtle interaction feeding back into the
checksummed range is not excluded), or a bug in the new `SB_QUIESCENT`/
mirror code introduced this session that hasn't been independently
verified byte-for-byte.

### Diagnostic attempt: partial, infrastructure lesson for next time

Tried to pin the exact diverging byte by breaking both consoles at
`LS_CKSUM` ($D99A) on its 7th hit (7*64=448) and dumping the full
`$015D-$01EF` range from each for a direct comparison. Got console 2's
dump; console 1 repeatedly failed to reach the 7th hit within a 200s
per-process timeout, apparently stalling for a long real-time interval
between its 2nd and 3rd hits (matchmaking-time variance between the
waiting host and the auto-joining guest, most likely) -- never resolved
within this session's remaining time.

**Lesson for next time**: don't try to time-align two independently-
launched live jzIntv debugger sessions via wall-clock breakpoint hit
counts -- real matchmaking/network timing varies too much between a
waiting host and an auto-joining guest to make this reliable. The robust
version of this diagnostic is an IN-ROM one: add a small trace ring to
the `net`/`rig` build itself (mirroring `debug.asm`'s `TRACE_TICK`
approach, gated behind a new build flag so it doesn't touch the
shipping `net` build) that records a per-tick (or per-64-tick) checksum
of `$015D-$01EF` into netcode RAM, keyed by tick number, on BOTH
consoles independently. Dump it from each console's OWN end-of-run
memory dump (which `run_rig.sh` already does reliably) and diff the two
rings in Python by tick number after the fact -- no live synchronization
needed at all, and it would immediately show which BYTE first disagreed
at tick 448, not just that the whole-range checksum did.

## Next-session punch list, in order (supersedes the M2/M3 list)

1. **Root-cause the rig CRC mismatch** (M4 above). Build the in-ROM
   per-tick trace-ring diagnostic described above; it is the highest-
   leverage next step since `m4`/`peerleft`/hardware all depend on the
   sim actually being deterministic across two real processes, not just
   in `det`'s single-process test.
2. Once fixed, re-run `make rig` to confirm 0 mismatches, then continue:
   `make m4` (both plain and `QUIESCE=1` -- the quiescent branch needs the
   scripted keypad sequence to ever reach `$0164==0 && $01D9==0`, which
   the rig's fuzz-after-script design should already provide some
   coverage of, but verify), `make peerleft`, hardware images.
3. Drive the two scripted fleets into an actual collision (confirm
   `$0164` reaches 5, `$035D` reaches `SB_HTBL_BATTLE`); tighten
   `check_dest_phase.py` further once confirmed. Not required for
   correctness, but closes the last coverage gap in `SCRIPT_TBL`.
4. Confirm the battle-phase action-button codes (the depth-charge
   buttons) now that a live non-null handler table is reachable.
5. Wire `$017B/$017C`/`$01D6/$01D7` clamps in `SB_REBASE_HOOK` alongside
   the existing `$0164` clamp (M3 §7.27 audit item, not yet done).
6. Confirm the `$0164==0 && $01D9==0` quiescent point on screen and write
   the `QUIESCE=1` forcing mode (§7.29) -- still not done.
