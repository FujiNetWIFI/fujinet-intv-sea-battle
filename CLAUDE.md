# Claude guidance for fujinet-intv-sea-battle

Ninth FujiNet netplay port (Sea Battle, Mattel 1980), scaffolded from the
Soccer tree. **Read `PORTING.md` before touching anything** — it is the
accumulated methodology of all nine ports; `spikes/NOTES.md` has this
cart's evidence trail (M0 recon, M1 hook build, M2 empirical input-code
measurement, M3 a deep second pass that caught and fixed a real bug, M4
the real keypad launch sequence + a reproducible rig-only desync).

**This port is NOT finished.** Through `make server-diff` is real,
verified, passing work — including real gameplay coverage (a scripted
fleet launch, confirmed live). `make rig` runs end-to-end for real but
**fails with a reproducible CRC mismatch** at ticks 448/576/704 (see
`spikes/NOTES.md` M4) — a real, narrow desync in the map-phase idle
bookkeeping that the resync safety net successfully recovers from every
time, but which needs root-causing before `m4`/`peerleft`/hardware are
worth attempting. Do not assume any gate passes without running it.

Sea Battle is **strictly 2-player**, simultaneous (no turn arbiter): the
per-player update `L_539B` runs for seat 0 then seat 1 unconditionally
every tick, and both the movement (`$011F`/`$0120`) and action/restart
(`$0121`/`$0122`) surfaces are POLLED directly by patched cart operands —
unlike Soccer, which never read `$0121` at all.

## The keypad launch protocol (confirmed live, M4)

The only way to get real gameplay running on this cart: digits 1-9 add a
ship of that type to the selected fleet (decrementing `SB_INVENTORY`);
ENTER launches the fleet (sets bit 2 of its `SB_FLEET_STATE` cell, writes
its home-port position) if it has ≥1 ship. Dispatched through `$5439`
(the MAP table's keypad slot), via the SAME cell/slot as disc events (bit
7 set = keypad) — not the separate action-button class field. `SCRIPT_TBL`
(`src/vdispatch.asm`) now scripts this for both seats; `make det` passes
with `SB_INVENTORY changed = True, fleet launched = True`.

Hard rules, most of them learned the expensive way elsewhere:

- Never let any segment map `$7000`: the EXEC boot EXECUTES the word there.
  `make check-7000` guards it.
- Never put netcode RAM below `$8080` (STIC alias).
- **Sea Battle has ZERO RNG.** No `X_RAND1`/`X_RAND2` calls, no `$035E`
  reference anywhere in the ROM, no cart-internal PRNG loop — confirmed by
  two independent sweeps. There are no RNG wrapper patch sites at all,
  unlike every other port in the family. (This also RULES OUT randomness
  as the cause of the M4 rig desync — `RNG_LO`/`RNG_HI` are always 0.)
- **A hardcoded-literal countdown write is a real, previously-undocumented
  hazard class.** Two sites in the ship-destroyed handler
  (`$5A80`/`$5A92`/`$5A95`) write SB_TICK2's countdown as a fixed RAM
  address, bypassing the timer API entirely — invisible to `recon.py`,
  which only looks for JSR-based timer calls. Relocating the timer table
  without also relocating (patching) these three operands would silently
  stall the whole dispatcher for up to 100 passes every time a ship is
  destroyed. Fixed by keeping SB_TICK2 at the same *relative* table
  position it always had and patching the three literal operands to match
  its new absolute address. **If you ever change `NEW_TIMER_TBL`'s slot
  order, grep the disassembly for the countdown's literal address
  (`$0125 + 2*slot`) in addition to grepping for timer-API JSRs.**
- **SB_TICK2 and SB_TICK3 are not virtualized at all.** They stay at their
  original ROM targets/intervals in the relocated table and fire NATIVELY
  via the real EXEC dispatcher (`$17D5`), because `$17D5` cannot reach
  their dispatch check until `MASTER_TICK` — table slot 1, dispatched
  first — fully returns. This is stall-safe for free and needs no
  virtualized countdown code. `SC_CNT2`/`SC_CNT3` (ram.asm) are a per-tick
  MIRROR of the real cells, computed inside `SC_GAME_TICK` (NOT
  `MASTER_TICK`'s local-only section — see below) and restored on resync
  by `SB_REBASE_HOOK` (one added line in `resync.asm`'s `RS_REBASE` — the
  file's first genuine cart-specific edit beyond the pre-existing
  `RS_CLAMP_ISR`, which establishes that "copy unchanged" was never 100%
  literal in this family).
- **`$0164` (the phase cell) indexes a raw computed jump with no bounds
  check anywhere in the cart** (`ADD@ R5,R7` at `$52C3`). It is the single
  most dangerous transported cell found in this port so far — worse than a
  code-pointer clamp, since a corrupted wire byte here jumps execution to
  an arbitrary ROM address. `SB_REBASE_HOOK` clamps it to 0-8.
- **Removing a `JSR` to reproduce a table slot natively is easy to get
  subtly wrong.** The M3 redesign correctly moved SB_TICK2/3's dispatch to
  the real EXEC, but a first draft of the simplified `SC_GAME_TICK` also
  (incorrectly) dropped the call to `SB_TICK1` — the game's own 9-phase
  dispatcher, which is NOT the same thing as `MASTER_TICK` and is not
  called by anything else once its original table slot is overwritten.
  Caught by comparing a live boot dump against the predicted state (`$0164`
  stuck at 0, `$0176` never advancing), not by any automated gate — `make
  det` passed clean on the buggy build, because the placeholder
  `SCRIPT_TBL` never drove play far enough to expose it. **Any change to
  which table slot holds what needs a live boot-dump check, not just a
  green `det`.**
- **Code that only runs from `MASTER_TICK`'s local-only branch never runs
  during real netplay at all** — `NET_ACTIVE` returns early via `LS_PASS`
  before that section is reached. Caught for the SC_CNT2/3 mirror and the
  `SB_QUIESCENT` flag (M4) before it ever reached a rig; both now live in
  `SC_GAME_TICK`, which lockstep.asm's own call order confirms runs from
  BOTH the local path and `LS_PASS`, before `LS_CKSUM`/`RS_PENDING` read
  them. **Any new per-tick computation goes in `SC_GAME_TICK`, not
  `MASTER_TICK`'s `@@mt_local` section, unless it is genuinely
  local-only.**
- **`resync.asm`/`lockstep.asm`'s `NET_SESSION`-gated content is untested
  by `hook`/`virt`/`det`/`lag`/`echo`** — only a `net`/`rig` build touches
  it, and it references more Soccer-specific symbols
  (`SC_POSSESSION`, `SC_PHASE`/`SC_PHASE_DEAD`) than the M1 pass caught.
  Assemble every build variant at least once, early, rather than assuming
  the ones you've tested cover the ones you haven't.
- No `X_SCAN` self-call hazard (unlike Soccer): the cart never calls the
  controller scan itself.
- No cart ISR, no scroll, zero STIC/GRAM writes: display is fully static,
  the Baseball-form header-reassert (`RS_DISPLAY_RESET`, unchanged) is
  correct as inherited.
- `r N` in jzIntv scripts counts INSTRUCTIONS (~200k/emulated second);
  breakpoint-forced injection is exploration-only (§7.17). Don't try to
  time-align two independently-launched live jzIntv debugger sessions via
  wall-clock breakpoint hit counts for a diagnostic — real matchmaking/
  network timing varies too much between a waiting host and an
  auto-joining guest (learned the hard way in M4, chasing the rig desync).
  An in-ROM per-tick trace ring, dumped independently from each console's
  own end-of-run memory dump, is the robust version of that diagnostic —
  not yet built.
- Rig scripts `pkill -f 'fujinet -u 127.0.0.1:1808'` — never type that
  pattern in an interactive shell (it matches your own shell and kills it).

Two false-PASS traps specific to this cart:

- `$0164 == 6` (GAME OVER) is TERMINAL — flashes `$0177 ^= $0165` forever
  with no path back. Every dump is stable there.
- Phase 1 with no fleet ever launched (what a `$3F`-masked disc-only fuzz
  run would sit in for its entire duration, if it were the only input
  source — the rig build's `NET_FUZZ` path actually runs `SCRIPT_TBL`
  first, so real rig runs DO launch fleets) is near-static: only
  `$015F`/`$0160` (period 11) and `$0176` (period 61) advance. Neither
  proves any INPUT landed. `check_dest_phase.py` now asserts
  `SB_INVENTORY`/`SB_FLEET_STATE` (the confirmed strong signals) instead
  of the old weak `$0164 > 1` check.

Gate ladder (each must pass before the next in the intended order, but
`server-diff` doesn't depend on the game-logic gates and was run out of
order): verify-org → verify-patch → check-7000 → hook (boots, matches
every predicted boot value) → virt (assembles) → det (**256/256 ticks
deterministic under stall injection, WITH real confirmed gameplay
coverage — real, passing**) → lagcheck (**100% agreement at shift=20
ticks — real, passing**) → echo-test (**100 clean rounds — real,
passing**) → server-diff (**6/6 scenarios, `--strict` clean — real,
passing**) → rig (**runs end-to-end for real; FAILS with a reproducible
CRC mismatch, ticks 448/576/704, both runs — session mechanics and the
resync safety net are otherwise fully healthy**). `m4`, `peerleft` and
hardware images are **not yet attempted** — blocked on the rig finding.

Assignments: production port 9110, FujiNet Lobby appkey 18, maxplayers 2.
`server/intv_relay_server.py` is protocol v2 (seat-tagged, rooms), inherited
from Soccer's tree with one fix: the partial-frame guard Soccer's README
flagged as a known defect (`intv_relay_server.py:333-348` in that repo) is
restored here (`if len(client.rx) < need: return`, matching every pre-v2
sibling's server and the C relay, which already had it). `make server-diff`
and `tools/server_diff.py --strict` both **PASS cleanly, all 6 scenarios,
run for real this session** — `framing` is no longer an expected
divergence. Soccer's own tree is untouched; its README still correctly
documents the defect as unfixed there, by design (it is the C relay's
diff oracle).
