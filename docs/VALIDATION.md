# Validation record

Date: 2026-09-27

This file separates demonstrated behavior from work that still requires the
user's physical machine.

## Demonstrated in DOSBox-X and media analysis

- The production source assembles without NASM warnings.
- The packed 98,791-byte English executable starts directly under `CF2GUS`
  with its original `CANNON.EXE` filename; no external `LOADFIX` command or
  rename is used. A `CAN2.EXE` fallback is retained.
- The supported executable is byte-identical in the supplied installed set,
  original English floppy set, and original English CD set. Its SHA-256 is
  `bff98b997e893b3bcbe78b8bbdc5dd31e7d378dac0004ffb7de66d42c82fae1b`.
- All seven song IDs requested by the game load from the complete installation:
  `MENU`, `WINZONE`, `WINLEVEL`, `HELIANIM`, `LOADER`, `GAMEOVER`, and `TITLE`.
  Each direct test received GF1 timer interrupts and exited cleanly.
- The complete installation's seven AMFs and fourteen SMPs are byte-identical
  to the corresponding files on both original English media sets.
- A music-only `TITLE.AMF` capture is non-silent 44.1 kHz stereo: peak
  -8.58 dBFS, RMS -25.96 dBFS, maximum absolute DC offset 0.0015.
- A music-only `LOADER.AMF` capture is non-silent 44.1 kHz stereo: peak
  -7.86 dBFS, RMS -24.81 dBFS, maximum absolute DC offset 0.0015.
- A v0.5 integration capture covering the restored loader fade-in is non-silent
  44.1 kHz stereo: peak -7.94 dBFS and aggregate RMS -26.45 dBFS. After the
  initial transition silence, audio remains above the -45 dB threshold until
  the test process exits and its three-second capture tail begins.
- Neither title nor loader capture clips. Both tests suppress the self-test SFX,
  so their audio cannot be attributed to `BIRD.SMP`.
- With GUS emulation moved to base 250h, DMA 3, IRQ 11, the launcher displayed
  `base 0250h, DMA 3/3, IRQ 11/11`, found GF1 RAM, played the self-test, and
  received timer interrupts. This verifies that resources follow `ULTRASND`.
- After the packer materializes the child image, every guarded location matches
  its numeric CRC and the complete in-memory patch is installed.
- A test-only integration build forces a short fade before the first real game
  song request, then forces another fade and changes to `LOADER.AMF`. It checks
  that the game timer retires both fades, that GF1 tracker ticks advance during
  the second wait, and that loader becomes the current song only afterward.
  The test then verifies the restored loader fade-in from level 0 through 64
  and requires the launcher's game-master shadow to reach 64.
  It then issues an unmapped selector and verifies that loader remains current,
  active, and counted only once. The parent reports both
  `Fade-transition synchronization test: PASS` and
  `Unknown-selector preservation test: PASS`, plus `songs=0002 sfx=0001`,
  after vector restoration.
- Static interoperability analysis confirms why the selector regression is
  needed: the game has a seven-entry song table but also emits values 50–54.
  Its original routine returns without changing playback for an absent value.
  Versions 0.2/0.3 instead stopped the active GF1 module before table lookup.
- A forced-starvation integration build acknowledges every GF1 timer interrupt
  without advancing the tracker. The patched approximately 50 Hz game callback
  alone completes both fade/song transitions and five seconds of playback. It
  reports `Clock-starvation recovery test: PASS` and 0x0176 recovered ticks.
- The normal integration run reports 0000 recovered ticks, confirming that the
  GF1 timer remains the active precision clock when its IRQ is serviced.
- The compile-time `TRACE_BUILD` path records song, fade, clock-fallback,
  tracker, game-timer, and PIC-mask state using memory/port reads only inside
  handlers;
  its DOS report runs after the child and vectors are restored. The traced
  integration run parses successfully with no buffer overflow. Compiling
  without `TRACE_BUILD` remains byte-identical to the normal v0.5 COM.
- Unsigned AMF/SMP bytes are converted to signed GF1 PCM during upload. This
  removes the wrap discontinuity without changing any game asset.
- The AMF pitch table uses note 60 as the instrument's nominal sample-rate note.
- INT 67h remains untouched so EMS services are not intercepted. The launcher
  uses saved/restored user vectors 64h, 65h, and 66h.
- Timer and shim handlers preserve complete 32-bit general-register state, not
  only the 16-bit halves, which is required around the game's 386 operations.
- The combined `/T /P-100 /M0 /S100 /LOFF` boundary-option test parses the
  expected values and completes successfully.

## Reported from the target hardware

The user's AMD 386DX-40, 16 MiB system and 1 MiB GUS MAX ran v0.1 with
`ULTRASND=240,7,7,7,7` and 4 MiB EMS under EMM386. `/T` produced sound, the
game started after manually renaming `CANNON.EXE` to `CAN2.EXE`, and gameplay
SFX appeared to work. Intro and level-loading music were absent, followed by
the generic invalid-song warning.

Version 0.2 was then tested on the same machine. Intro/title music and
Home:Away music played, as did gameplay SFX. The scrolling level-loader music
did not play. After level one, music was also absent from Lost in Service,
Heroes in Victory, and the next Home:Away screen, although level-two SFX still
worked. Audible music appeared to skip forward across screen fades, especially
in the intro. No missing/invalid-song warning appeared on exit.

Static analysis showed that the original song selector waits for the game's
64-step fade-down state to retire before replacing a module. Version 0.3
restores that ordering while leaving the outgoing tracker active, and its
forced two-song transition test passes in DOSBox-X. The target-machine retest,
however, reproduced all v0.2 symptoms: skipped beats during fades, silent
loader/post-level music, working SFX, and no invalid-song warning. The earlier
claim that stale fade state was the root cause is disproved; it remains only a
verified behavioral difference that v0.3 corrected.

Version 0.4 was tested next. The 386/GUS MAX run reported three successful song
loads and 0x001B recovered tracker ticks. Fade starvation was less pronounced,
but the third song still produced no audible music. A 486/133 with GUS PnP
played fades correctly while reproducing the same silent songs. This confirms
that tracker fallback activated on the 386, but disproves the claim that either
clock recovery or unknown-selector preservation was the missing-song fix.

Static analysis then identified the omitted post-load operation. The original
selector waits for fade-down, replaces the module, and arms fade-up at level
zero after every successful mapped song change. CF2GUS v0.1–v0.4 performed the
first two steps but skipped the last, leaving a valid running AMF under the
zero master inherited from fade-down. Version 0.5 restores the guarded fade-up
state only when the requested song is current, active, and timer-driven. Its
integration trace shows loader rising from master 00 through 40h and completing
with the fade-up flag retired.

Version 0.5 was then tested on the target 386/GUS MAX. The scrolling-loader
music and music after returning from level one now play as intended; intro,
Home:Away music, and gameplay SFX also remain working. This physically confirms
the post-load fade repair. The user still hears a mild tempo sag while the game
loads or fades the screen. Changing the MAX from `ULTRASND=240,7,7,7,7` to
`ULTRASND=240,3,3,3,3` did not change it. The 486/133 does not exhibit the
slowdown, so v0.5 retains the conservative two-game-tick recovery threshold.

## Audio/performance design checks

- 14 active GF1 voices select the full 44.1 kHz hardware output rate.
- Only four music channels are updated on tracker ticks; sample mixing remains
  in GF1 hardware.
- A song-transition wait sleeps between hardware interrupts rather than
  spinning. The outgoing tracker remains active until the fade completes.
- Repeated requests for an already-applied game master level do not rewrite all
  four GF1 voice-volume registers.
- Eight independent SFX voices avoid cutting music and permit overlapping
  effects.
- Sample transfers use one-time programmed I/O. The game loop has no PCM
  mixing callback after patch installation.
- Music sample payloads begin at GF1 address 10000h; the 50,722-byte SFX bank is
  below that boundary.
- The game PIT is not reprogrammed. GF1 timer 1 remains the primary precision
  clock and follows AMF BPM changes.
- The existing approximately 50 Hz game callback maintains only a fractional
  expected-tick counter while GF1 IRQ service is healthy. After two missed game
  ticks it supplies the deficit, capped at four tracker ticks per IRQ0, and
  drops one stale coalesced GF1 request when primary service resumes.

## Not yet demonstrated

- A complete v0.5 regression test on the user's 486/133 with GUS PnP. Its v0.4
  run had smooth fade timing but still contained the missing-song bug fixed in
  v0.5.
- Subjective noise, stereo balance, click behavior, and long-session IRQ
  stability on the physical card.
- Systematic triggering of all fourteen SFX during real gameplay.
- Compatibility with non-English CD executables. Their hashes differ and their
  runtime patch locations are not claimed as supported.

## Hardware regression sequence

1. Keep the supported executable under its original `CANNON.EXE` name and
   confirm `ULTRASND=240,7,7,7,7`.
2. Run `CF2GUS /T`. Confirm music plus the bird effect are audible, the displayed
   resources are `0240h, 7/7, 7/7`, and the timer test passes.
3. Run `CF2GUS`. Confirm title/intro and Home:Away music, then start a mission
   and confirm the scrolling level-loading music plays from its beginning.
4. Finish or abandon level one. Confirm music on Lost in Service or Heroes in
   Victory and again on Home:Away, then start level two and confirm its SFX.
5. During intro and screen fades, listen for a track resuming mid-beat, a long
   silent gap, stuck voices, or clicks.
6. Exit normally. Record `Recovered tracker ticks`; a nonzero value identifies
   actual fallback use. The invalid-song warning should not appear, and another
   DOS audio program should still be able to use IRQ 7.
7. If the bad MAX codec or analog input contributes noise, repeat with
   `CF2GUS /LOFF`; generated audio still uses only GF1 voices.
