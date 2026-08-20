# Networked Sea Battle (Intellivision) over FujiNet

Two-player head-to-head **Sea Battle** (Mattel, 1980) across the internet:
two real Intellivisions, each with a FujiNet, playing the original
cartridge in delay-based lockstep through a TCP relay.

**This port is in progress, not finished.** The core interception and
determinism engineering is real, built, and verified against this
machine's actual toolchain — see *Status* below for exactly what has and
has not been proven. `spikes/NOTES.md` is the full evidence trail,
including a real bug this session caught and fixed before it could reach
any later gate.

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
make run-hook       # play it; must feel identical to stock (not yet done)
make lagcheck       # input interception proof (not yet attempted -- needs
                     #   real input codes past the map-idle state)
make det            # determinism: two runs, one stalled, checksums must match
make echo-test       # transport through jzintv --fujinet -> fujinet-pc (not yet attempted)
make rig             # two consoles, auto-matched, CRC-compared (not yet attempted)
make m4              # desync injected, detected, repaired (not yet attempted)
make peerleft        # opponent walks out, both branches (not yet attempted)
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
| `hook` boots | **pass** — every live memory dump matches the recon-predicted boot state exactly (ISR page, phase cell, handler table, all four timer countdowns) |
| `virt` | **pass** — assembles clean |
| `det` | **pass — 256/256 ticks identical under a 9-frame-per-64 stall**, including after a real timer-corruption bug was found and fixed mid-session. Its destination-phase check correctly and honestly **fails**: the in-ROM demo script is currently a placeholder that never drives past the map's idle state, so this does not yet prove real gameplay is deterministic, only that the netcode engine's own stall/checksum machinery is. |
| `server-diff` | **pass** — 6/6 scenarios, `--strict` clean, run for real this session |
| `lagcheck` / `echo-test` / `rig` / `m4` / `peerleft` / hardware | **not attempted** |

### What is NOT proven, and why

1. **No real gameplay has been driven yet.** Getting a ship to sea (and
   therefore into battle) requires a keypad ship-assignment sequence, not
   disc input — the movement/action shadow-redirect mechanism itself is
   proven working end to end (a forced disc press lands correctly in the
   shadow cell the patched cart operand reads), but the *sequence* needed
   to reach live tactical battle has not been scripted yet.
2. **The action-button codes are unconfirmed for the same reason.** An
   exhaustive 256-value raw-byte sweep found nothing, which turned out to
   be expected: those buttons only produce an event when the currently-
   installed handler table has a non-null slot for them, and the map
   phase's table doesn't. Needs testing once battle phase is reached.
3. **No transport, matchmaking, or hardware testing has been attempted.**
   The prerequisites (a FujiNet-patched jzIntv build, a `fujinet-pc-rs232`
   dist) are present on this machine but the gates themselves have not
   been run.

See `spikes/NOTES.md` for the full, ordered punch list for continuing this
port.
