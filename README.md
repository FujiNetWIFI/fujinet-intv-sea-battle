# Networked Sea Battle (Intellivision) over FujiNet

Two-player head-to-head **Sea Battle** (Mattel, 1980) across the internet:
two real Intellivisions, each with a FujiNet, playing the original
cartridge in delay-based lockstep through a TCP relay.

**This port is in progress, not finished.** The core interception,
determinism, transport and matchmaking engineering is real, built, and
verified against this machine's actual toolchain, with confirmed real
gameplay coverage (a scripted keypad fleet launch). A real two-console rig
run surfaced a reproducible, well-characterized desync that still needs
root-causing before the port can go further — see *Status* below.
`spikes/NOTES.md` is the full evidence trail, including several real bugs
this session caught and fixed before they reached a later gate.

The original ROM is not modified in any interesting sense: 14 words of
`$5000-$5FFF` are rewritten (the EXEC timer-table pointer, the start-of-game
vector, one timer-arm call, two hardcoded countdown-address writes, and
five controller-read operands), and a netcode segment is linked in above
it. Everything else is the 1980 cartridge, byte for byte — `make
verify-org` proves the unpatched dump reassembles identically, and `make
verify-patch` proves only the declared words differ.

## How it works

Both consoles run the same simulation and exchange only inputs. The EXEC's
timer table is relocated so a `MASTER_TICK` of ours is dispatched every
pass, reproducing the cart's own 20 Hz phase dispatcher, replaying both
seats' inputs from delay rings, and checksumming the result. A CRC mismatch
triggers a state resync, deferred to a quiescent moment so the map does not
visibly jump.

Getting real gameplay running requires a keypad sequence: press a digit
1-9 to add a ship to the selected fleet, then ENTER to launch it to its
home port. `SCRIPT_TBL` (the in-ROM demo/fuzz script) drives this for both
seats before handing off to masked disc-only fuzz.

This is the ninth port of a shared engine — Baseball, Auto Racing, NFL
Football, Armor Battle, Utopia, Frog Bog, PBA Bowling and NASL Soccer came
first. `PORTING.md` is the accumulated methodology; `spikes/NOTES.md` is
this cart's evidence.

### What made this cart different

- **Zero randomness.** No `X_RAND1`/`X_RAND2` calls, no `$035E` reference
  anywhere in the ROM, no cart-internal PRNG loop — confirmed by two
  independent sweeps. The first cart in the family that needs no RNG
  wrapper patches at all.
- **It polls two surfaces, not one.** Both movement (`$011F`/`$0120`) and
  the action/restart button (`$0121`/`$0122`) are read directly by patched
  cart operands, register-indexed by seat. Soccer only needed this for
  movement.
- **A hardcoded-literal timer write, invisible to `recon.py`.** Two sites
  in the ship-destroyed handler write the second timer entry's countdown
  as a fixed RAM address, bypassing the timer-arm API entirely. Missing
  this would have silently stalled the whole engine for up to 5 seconds
  every time a ship was destroyed — caught by a second, deeper analysis
  pass and fixed by keeping that entry at its original relative table
  position and patching the two literal addresses to match.
- **Two of the three timer entries are not virtualized at all.** They stay
  at their original ROM targets/intervals and fire natively through the
  real EXEC dispatcher, which is provably stall-safe here because it can't
  reach them until `MASTER_TICK` (dispatched first) fully returns — no
  hand-rolled countdown code needed for either.
- **The phase cell (`$0164`) indexes a raw, unchecked computed jump.** The
  single most dangerous transported cell found in this port so far — a
  corrupted wire byte would jump execution to an arbitrary ROM address.
  Clamped on every resync.

## Build and test

Requires the jzIntv SDK (`as1600`, `dis1600`, `bin2rom`, `jzintv`) and, for
the network gates, a `fujinet-pc-rs232` dist.

```
make verify-org     # unpatched dump reassembles to the original, byte for byte
make hook           # patched build + verify-patch
make run-hook       # play it; must feel identical to stock (not yet done interactively)
make lagcheck       # input interception proof
make det            # determinism: two runs, one stalled, checksums must match
make echo-test      # transport through jzintv --fujinet -> fujinet-pc
make server-diff    # py vs c relay differential
make rig            # two consoles, auto-matched, CRC-compared
make m4             # desync injected, detected, repaired (not yet attempted --
                     #   blocked on the rig finding below)
make peerleft       # opponent walks out, both branches (not yet attempted)
make rom SRV_HOST=…  # hardware image for PiRTO II (not yet built)
```

`make recon ROM=…` prints the port map for any EXEC cart — hook points, tick
rate, sites to patch. It is how this port started.

## Server

`server/intv_relay_server.py` is a single-file, stdlib-only relay and
matchmaker, inherited from the Soccer tree with one fix applied: the
partial-frame guard that tree's README flagged as a known, deliberately-
unfixed defect (kept as the C relay's diff oracle there) is restored here,
matching every pre-v2 sibling server and the C relay (which already had
it). `make server-diff` / `tools/server_diff.py --strict` both pass
cleanly, all 6 scenarios — `framing` is no longer an expected divergence.

Assignments: relay port **9110**, Lobby appkey **18**, maxplayers **2**.

`server/c/` is the C port covering every game in the series (see Soccer's
`server/c/README.md` for its design — inherited unchanged here).

## Status

| gate | state |
|---|---|
| `verify-org` | **pass** — byte-identical rebuild |
| `verify-patch` | **pass** — 14 declared sites, 14 changed |
| `check-7000` | **pass** — no segment maps `$7000` |
| `hook` boots | **pass** — every live memory dump matches the recon-predicted boot state exactly |
| `virt` | **pass** — assembles clean |
| `det` | **pass — 256/256 ticks identical under a 9-frame-per-64 stall**, WITH confirmed real gameplay coverage (a scripted fleet launch: `SB_INVENTORY changed = True, fleet launched = True`). Two real bugs (a timer-countdown-corruption hazard, and a dropped call to the cart's own game logic) were found and fixed getting here — see `spikes/NOTES.md` M3. |
| `lagcheck` | **pass — 100% agreement at shift=20 ticks against an 11% baseline.** As clean a confirmation as this test produces. |
| `echo-test` | **pass** — 100 clean rounds through `jzintv --fujinet` |
| `server-diff` | **pass** — 6/6 scenarios, `--strict` clean |
| `rig` | **runs end-to-end for real** — two real `fujinet-pc-rs232` processes, a real relay, two real consoles, ~2300 ticks. Session mechanics are fully healthy (0 drops, 0 DIAG errors, correct seat/roster). **But FAILS**: a CRC mismatch reproduces at the identical ticks (448, 576, 704) across two independent runs. The resync safety net recovers every time — both sessions complete cleanly — but the root cause is not yet found. |
| `m4` / `peerleft` / hardware | **not attempted** — blocked on the rig finding |

### What is NOT proven, and why

1. **The rig desync's root cause is unresolved.** Reproducible, narrow,
   and non-catastrophic (the resync mechanism recovers it every time), but
   not yet root-caused. Several causes are ruled out by construction (no
   RNG on this cart, the handler table is constant while stuck in the map
   phase, the one virtualized-adjacent timer mirror is provably constant
   in this scenario) — see `spikes/NOTES.md` M4 for the full elimination
   list and the recommended next diagnostic (an in-ROM per-tick trace
   ring, since live-synchronizing two independent debugger sessions by
   wall-clock breakpoint counts proved unreliable this session).
2. **The tactical battle phase has never been reached.** Two fleets are
   launched and driven toward each other by best-effort movement, not a
   proven collision. The battle-phase action-button (depth-charge) codes
   are therefore also still unconfirmed.
3. **No hardware testing has been attempted.** The prerequisites are
   present on this machine but `m4`/`peerleft`/hardware images come after
   the rig desync is fixed.

See `spikes/NOTES.md` for the full, ordered punch list for continuing this
port.
